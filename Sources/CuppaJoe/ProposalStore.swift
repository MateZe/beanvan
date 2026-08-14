import CoffeeProtocol
import Foundation
import os

struct ActiveCoffeeProposal: Identifiable, Equatable, Sendable {
    let proposal: Proposal
    let proposerName: String
    let participantIDs: Set<UUID>

    var id: UUID { proposal.id }
    var participantCount: Int { participantIDs.count }
}

enum ProposalStoreError: LocalizedError, Equatable {
    case activeProposalExists
    case cooldownActive
    case timestampExhausted

    var errorDescription: String? {
        switch self {
        case .activeProposalExists:
            "Your current coffee proposal is still active"
        case .cooldownActive:
            "You can propose coffee again after the 20-minute cooldown"
        case .timestampExhausted:
            "The system clock cannot represent the proposal expiry time"
        }
    }
}

@MainActor
final class ProposalStore: ObservableObject {
    static let proposalLifetime: EpochMilliseconds = 5 * 60 * 1_000
    static let proposalCooldown: EpochMilliseconds = 20 * 60 * 1_000

    @Published private(set) var activeProposals: [ActiveCoffeeProposal] = []
    @Published private(set) var quorumThreshold: Int

    var canPropose: Bool {
        localActiveProposal == nil && cooldownElapsed(
            lastProposalAt: lastProposalAt,
            now: now(),
            cooldown: Self.proposalCooldown
        )
    }

    var hasIncomingProposalSignal: Bool {
        activeProposals.contains { $0.proposal.proposer != instance.id }
    }

    var localInstanceID: UUID { instance.id }

    var nextProposalDate: Date? {
        guard let lastProposalAt else { return nil }
        let (end, overflow) = lastProposalAt.addingReportingOverflow(Self.proposalCooldown)
        guard !overflow, end > now() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(end) / 1_000)
    }

    private var instance: AppInstance
    private let transport: any PeerMessageTransport
    private let persistenceURL: URL
    private let fileManager: FileManager
    private let now: () -> EpochMilliseconds
    private let logger = Logger(subsystem: "com.josipmusa.cuppajoe", category: "proposals")

    private var records: [UUID: ProposalRecord] = [:]
    private var activeIDByProposer: [UUID: UUID] = [:]
    private var pendingAccepts: [UUID: Set<UUID>] = [:]
    private var seenProposalIDs = Set<UUID>()
    private var acceptedProposalIDs = Set<UUID>()
    private var firedProposalIDs = Set<UUID>()
    private var canceledProposalIDs = Set<UUID>()
    private var pendingFireIDs: [UUID] = []
    private var lastProposalAt: EpochMilliseconds?
    private var stateTimer: Timer?
    private var onFire: (() -> Void)?

    init(
        instance: AppInstance,
        transport: any PeerMessageTransport,
        quorumThreshold: Int? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> EpochMilliseconds = {
            EpochMilliseconds(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        self.instance = instance
        self.transport = transport
        self.fileManager = fileManager
        self.now = now
        persistenceURL = instance.stateDirectory.appendingPathComponent("proposal-state.json")

        let persisted: PersistedProposalState?
        if fileManager.fileExists(atPath: persistenceURL.path) {
            persisted = try JSONDecoder().decode(
                PersistedProposalState.self,
                from: Data(contentsOf: persistenceURL)
            )
        } else {
            persisted = nil
        }
        lastProposalAt = persisted?.lastProposalAt
        self.quorumThreshold = max(1, quorumThreshold ?? persisted?.quorumThreshold ?? 3)

        transport.addEnvelopeHandler { [weak self] envelope in
            self?.receive(envelope)
        }
        transport.addConnectionReadyHandler { [weak self] in
            self?.gossipLocalParticipation()
        }
    }

    func start(onFire: @escaping () -> Void) {
        self.onFire = onFire
        let count = pendingFireIDs.count
        pendingFireIDs.removeAll()
        for _ in 0..<count {
            onFire()
        }
    }

    func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        onFire = nil
    }

    @discardableResult
    func proposeCoffeeNow() throws -> Proposal {
        removeExpiredProposals()
        guard localActiveProposal == nil else {
            throw ProposalStoreError.activeProposalExists
        }
        let timestamp = now()
        guard cooldownElapsed(
            lastProposalAt: lastProposalAt,
            now: timestamp,
            cooldown: Self.proposalCooldown
        ) else {
            throw ProposalStoreError.cooldownActive
        }

        let (expiresAt, expiryOverflow) = timestamp.addingReportingOverflow(Self.proposalLifetime)
        guard !expiryOverflow else { throw ProposalStoreError.timestampExhausted }
        let proposal = Proposal(
            id: UUID(),
            proposer: instance.id,
            createdAt: timestamp,
            expiresAt: expiresAt
        )
        let previousLastProposalAt = lastProposalAt
        lastProposalAt = timestamp
        do {
            try persistState()
        } catch {
            lastProposalAt = previousLastProposalAt
            throw error
        }
        add(proposal: proposal, proposerName: instance.displayName)
        send(.proposal(proposal))
        return proposal
    }

    func accept(_ proposalID: UUID) {
        removeExpiredProposals()
        guard let record = records[proposalID],
              record.proposal.proposer != instance.id,
              !record.participantIDs.contains(instance.id) else { return }

        records[proposalID]?.participantIDs.insert(instance.id)
        acceptedProposalIDs.insert(proposalID)
        publishActiveProposals()
        send(.accept(Accept(proposalID: proposalID, accepter: instance.id)))
        evaluateQuorum(for: proposalID)
    }

    func cancel(_ proposalID: UUID) {
        removeExpiredProposals()
        guard let record = records[proposalID],
              record.proposal.proposer == instance.id else { return }

        canceledProposalIDs.insert(proposalID)
        removeProposal(proposalID)
        send(.proposalCancellation(ProposalCancellation(
            proposalID: proposalID,
            proposer: instance.id
        )))
    }

    func setQuorumThreshold(_ threshold: Int) {
        let threshold = max(1, threshold)
        guard threshold != quorumThreshold else { return }
        quorumThreshold = threshold
        do {
            try persistState()
        } catch {
            logger.error("Failed to persist the quorum setting: \(error.localizedDescription, privacy: .public)")
        }
        records.keys.forEach { evaluateQuorum(for: $0) }
    }

    func updateInstance(_ instance: AppInstance) {
        if instance.teamPhrase != self.instance.teamPhrase {
            records.removeAll()
            activeIDByProposer.removeAll()
            pendingAccepts.removeAll()
            seenProposalIDs.removeAll()
            acceptedProposalIDs.removeAll()
            firedProposalIDs.removeAll()
            canceledProposalIDs.removeAll()
            pendingFireIDs.removeAll()
            publishActiveProposals()
        }
        self.instance = instance
    }

    func removeExpiredProposals() {
        let timestamp = now()
        let expiredIDs = records.values
            .filter { isExpired($0.proposal, at: timestamp) }
            .map(\.proposal.id)
        guard !expiredIDs.isEmpty else {
            armStateTimer()
            return
        }
        for id in expiredIDs {
            if let record = records.removeValue(forKey: id) {
                activeIDByProposer.removeValue(forKey: record.proposal.proposer)
            }
            pendingAccepts.removeValue(forKey: id)
            acceptedProposalIDs.remove(id)
        }
        publishActiveProposals()
    }

    private var localActiveProposal: ProposalRecord? {
        activeIDByProposer[instance.id].flatMap { records[$0] }
    }

    private func receive(_ envelope: Envelope) {
        switch envelope.payload {
        case .proposal(let proposal):
            receive(proposal: proposal, envelope: envelope)
        case .accept(let accept):
            receive(accept: accept, envelope: envelope)
        case .proposalCancellation(let cancellation):
            receive(cancellation: cancellation, envelope: envelope)
        case .schedule:
            break
        }
    }

    private func receive(proposal: Proposal, envelope: Envelope) {
        removeExpiredProposals()
        guard proposal.proposer == envelope.senderID,
              !seenProposalIDs.contains(proposal.id),
              !canceledProposalIDs.contains(proposal.id),
              proposal.createdAt <= envelope.timestamp,
              Self.hasValidLifetime(proposal) else { return }
        seenProposalIDs.insert(proposal.id)
        guard !isExpired(proposal, at: now()),
              activeIDByProposer[proposal.proposer] == nil else { return }

        add(proposal: proposal, proposerName: envelope.senderName)
    }

    private func receive(accept: Accept, envelope: Envelope) {
        guard accept.accepter == envelope.senderID else { return }
        if records[accept.proposalID] == nil {
            pendingAccepts[accept.proposalID, default: []].insert(accept.accepter)
            return
        }
        guard records[accept.proposalID]?.participantIDs.insert(accept.accepter).inserted == true else {
            return
        }
        publishActiveProposals()
        evaluateQuorum(for: accept.proposalID)
    }

    private func receive(cancellation: ProposalCancellation, envelope: Envelope) {
        guard cancellation.proposer == envelope.senderID else { return }
        canceledProposalIDs.insert(cancellation.proposalID)
        guard records[cancellation.proposalID]?.proposal.proposer == cancellation.proposer else {
            return
        }
        removeProposal(cancellation.proposalID)
    }

    private func add(proposal: Proposal, proposerName: String) {
        seenProposalIDs.insert(proposal.id)
        var participants = pendingAccepts.removeValue(forKey: proposal.id) ?? []
        participants.insert(proposal.proposer)
        records[proposal.id] = ProposalRecord(
            proposal: proposal,
            proposerName: proposerName,
            participantIDs: participants
        )
        activeIDByProposer[proposal.proposer] = proposal.id
        publishActiveProposals()
        evaluateQuorum(for: proposal.id)
    }

    private func evaluateQuorum(for proposalID: UUID) {
        guard let record = records[proposalID],
              !isExpired(record.proposal, at: now()),
              quorumMet(
                proposal: record.proposal,
                accepts: record.participantIDs.map {
                    Accept(proposalID: proposalID, accepter: $0)
                },
                threshold: quorumThreshold
              ) else { return }

        if record.participantIDs.contains(instance.id),
           firedProposalIDs.insert(proposalID).inserted {
            if let onFire {
                onFire()
            } else {
                pendingFireIDs.append(proposalID)
            }
        }
        removeProposal(proposalID)
    }

    private func removeProposal(_ proposalID: UUID) {
        if let record = records.removeValue(forKey: proposalID) {
            activeIDByProposer.removeValue(forKey: record.proposal.proposer)
        }
        pendingAccepts.removeValue(forKey: proposalID)
        acceptedProposalIDs.remove(proposalID)
        publishActiveProposals()
    }

    private func gossipLocalParticipation() {
        removeExpiredProposals()
        if let localActiveProposal {
            send(.proposal(localActiveProposal.proposal))
        }
        for proposalID in acceptedProposalIDs where records[proposalID] != nil {
            send(.accept(Accept(proposalID: proposalID, accepter: instance.id)))
        }
    }

    private func send(_ payload: Payload) {
        do {
            transport.send(try Envelope.signed(
                senderID: instance.id,
                senderName: instance.displayName,
                timestamp: now(),
                payload: payload,
                teamPhrase: instance.teamPhrase
            ))
        } catch {
            logger.error("Failed to sign a proposal message: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publishActiveProposals() {
        activeProposals = records.values
            .map {
                ActiveCoffeeProposal(
                    proposal: $0.proposal,
                    proposerName: $0.proposerName,
                    participantIDs: $0.participantIDs
                )
            }
            .sorted {
                if $0.proposal.createdAt == $1.proposal.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.proposal.createdAt < $1.proposal.createdAt
            }
        armStateTimer()
    }

    private func armStateTimer() {
        stateTimer?.invalidate()
        let timestamp = now()
        let nextExpiry = records.values.map(\.proposal.expiresAt).min()
        let cooldownEnd = lastProposalAt.flatMap { timestamp -> EpochMilliseconds? in
            let (result, overflow) = timestamp.addingReportingOverflow(Self.proposalCooldown)
            return overflow ? nil : result
        }
        let nextChange = [nextExpiry, cooldownEnd]
            .compactMap { $0 }
            .filter { $0 > timestamp }
            .min()
        guard let nextChange else {
            stateTimer = nil
            return
        }
        let interval = TimeInterval(nextChange - timestamp) / 1_000
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeExpiredProposals()
                self.objectWillChange.send()
            }
        }
        stateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func persistState() throws {
        try fileManager.createDirectory(
            at: instance.stateDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedProposalState(
            lastProposalAt: lastProposalAt,
            quorumThreshold: quorumThreshold
        ))
        try data.write(to: persistenceURL, options: .atomic)
    }

    private static func hasValidLifetime(_ proposal: Proposal) -> Bool {
        let (lifetime, overflow) = proposal.expiresAt.subtractingReportingOverflow(proposal.createdAt)
        return !overflow && lifetime > 0 && lifetime <= proposalLifetime
    }
}

private struct ProposalRecord {
    let proposal: Proposal
    let proposerName: String
    var participantIDs: Set<UUID>
}

private struct PersistedProposalState: Codable {
    let lastProposalAt: EpochMilliseconds?
    let quorumThreshold: Int?
}

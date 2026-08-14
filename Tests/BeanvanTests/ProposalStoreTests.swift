import CoffeeProtocol
import Foundation
import Testing
@testable import Beanvan

@MainActor
struct ProposalStoreTests {
    private let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let proposerID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    private let accepterID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!

    @Test func localProposalBroadcastsAndCooldownSurvivesRelaunch() throws {
        try withFixture { instance, transport, root in
            var timestamp: EpochMilliseconds = 10_000
            let store = try ProposalStore(
                instance: instance,
                transport: transport,
                now: { timestamp }
            )

            let proposal = try store.proposeCoffeeNow()

            #expect(proposal.proposer == localID)
            #expect(proposal.expiresAt - proposal.createdAt == ProposalStore.proposalLifetime)
            #expect(store.activeProposals.first?.participantCount == 1)
            #expect(transport.sent.count == 1)
            #expect(throws: ProposalStoreError.activeProposalExists) {
                try store.proposeCoffeeNow()
            }

            timestamp += ProposalStore.proposalLifetime
            store.removeExpiredProposals()
            #expect(store.activeProposals.isEmpty)

            let reloadedInstance = AppInstance(
                displayName: instance.displayName,
                requestedPort: 0,
                teamPhrase: instance.teamPhrase,
                stateDirectory: root,
                id: instance.id
            )
            let reloaded = try ProposalStore(
                instance: reloadedInstance,
                transport: ProposalTestTransport(),
                now: { timestamp }
            )
            #expect(!reloaded.canPropose)
            #expect(throws: ProposalStoreError.cooldownActive) {
                try reloaded.proposeCoffeeNow()
            }

            timestamp = 10_000 + ProposalStore.proposalCooldown
            #expect(reloaded.canPropose)
        }
    }

    @Test func receivingProposalIsQuietAndDuplicateIsIgnored() throws {
        try withFixture { instance, transport, _ in
            let store = try ProposalStore(instance: instance, transport: transport, now: { 1_000 })
            var fireCount = 0
            store.start { fireCount += 1 }
            let proposal = Proposal(
                id: UUID(),
                proposer: proposerID,
                createdAt: 900,
                expiresAt: 300_900
            )
            let envelope = try signed(.proposal(proposal), senderID: proposerID, name: "Marko")

            transport.receive(envelope)
            transport.receive(envelope)

            #expect(fireCount == 0)
            #expect(store.activeProposals.count == 1)
            #expect(store.activeProposals.first?.proposerName == "Marko")
            #expect(store.activeProposals.first?.participantCount == 1)
            #expect(store.hasIncomingProposalSignal)
        }
    }

    @Test func proposerFiresOnceAtQuorumAndDuplicateAcceptsDoNotCount() throws {
        try withFixture { instance, transport, _ in
            let store = try ProposalStore(
                instance: instance,
                transport: transport,
                quorumThreshold: 3,
                now: { 1_000 }
            )
            var fireCount = 0
            store.start { fireCount += 1 }
            let proposal = try store.proposeCoffeeNow()
            let firstAccept = try signed(
                .accept(Accept(proposalID: proposal.id, accepter: proposerID)),
                senderID: proposerID,
                name: "Marko"
            )
            let secondAccept = try signed(
                .accept(Accept(proposalID: proposal.id, accepter: accepterID)),
                senderID: accepterID,
                name: "Ana"
            )

            transport.receive(firstAccept)
            transport.receive(firstAccept)
            #expect(store.activeProposals.first?.participantCount == 2)
            #expect(fireCount == 0)

            transport.receive(secondAccept)
            transport.receive(secondAccept)
            #expect(store.activeProposals.isEmpty)
            #expect(fireCount == 1)
        }
    }

    @Test func observerDoesNotFireButLateLocalAccepterFiresImmediatelyOnce() throws {
        try withFixture { instance, transport, _ in
            let store = try ProposalStore(
                instance: instance,
                transport: transport,
                quorumThreshold: 3,
                now: { 1_000 }
            )
            var fireCount = 0
            store.start { fireCount += 1 }
            let proposal = Proposal(
                id: UUID(),
                proposer: proposerID,
                createdAt: 900,
                expiresAt: 300_900
            )
            transport.receive(try signed(.proposal(proposal), senderID: proposerID, name: "Marko"))
            transport.receive(try signed(
                .accept(Accept(proposalID: proposal.id, accepter: accepterID)),
                senderID: accepterID,
                name: "Ana"
            ))

            #expect(store.activeProposals.first?.participantCount == 2)
            #expect(fireCount == 0)

            store.accept(proposal.id)
            store.accept(proposal.id)

            #expect(store.activeProposals.isEmpty)
            #expect(fireCount == 1)
            #expect(transport.sent.count == 1)
        }
    }

    @Test func proposerCancellationBroadcastsAndClearsRemoteProposal() throws {
        try withFixture { instance, transport, _ in
            let store = try ProposalStore(instance: instance, transport: transport, now: { 1_000 })
            let proposal = try store.proposeCoffeeNow()

            store.cancel(proposal.id)

            #expect(store.activeProposals.isEmpty)
            let envelope = try #require(transport.sent.last)
            guard case .proposalCancellation(let cancellation) = envelope.payload else {
                Issue.record("Expected a proposal cancellation payload")
                return
            }
            #expect(cancellation.proposalID == proposal.id)
            #expect(cancellation.proposer == localID)
        }

        try withFixture { instance, transport, _ in
            let store = try ProposalStore(instance: instance, transport: transport, now: { 1_000 })
            let proposal = Proposal(
                id: UUID(),
                proposer: proposerID,
                createdAt: 900,
                expiresAt: 300_900
            )
            transport.receive(try signed(.proposal(proposal), senderID: proposerID, name: "Marko"))
            transport.receive(try signed(
                .proposalCancellation(ProposalCancellation(
                    proposalID: proposal.id,
                    proposer: proposerID
                )),
                senderID: proposerID,
                name: "Marko"
            ))

            #expect(store.activeProposals.isEmpty)
        }
    }

    @Test func expiredProposalClearsSilentlyAndCannotBeReplayed() throws {
        try withFixture { instance, transport, _ in
            var timestamp: EpochMilliseconds = 1_000
            let store = try ProposalStore(instance: instance, transport: transport, now: { timestamp })
            let proposal = Proposal(
                id: UUID(),
                proposer: proposerID,
                createdAt: timestamp,
                expiresAt: 2_000
            )
            let envelope = try signed(.proposal(proposal), senderID: proposerID, name: "Marko")
            transport.receive(envelope)
            #expect(store.activeProposals.count == 1)

            timestamp = 2_000
            store.removeExpiredProposals()
            #expect(store.activeProposals.isEmpty)

            timestamp = 1_500
            transport.receive(envelope)
            #expect(store.activeProposals.isEmpty)
        }
    }

    @Test func secondActiveProposalFromSameSenderIsIgnored() throws {
        try withFixture { instance, transport, _ in
            let store = try ProposalStore(instance: instance, transport: transport, now: { 1_000 })
            let first = Proposal(id: UUID(), proposer: proposerID, createdAt: 800, expiresAt: 10_000)
            let second = Proposal(id: UUID(), proposer: proposerID, createdAt: 900, expiresAt: 10_000)

            transport.receive(try signed(.proposal(first), senderID: proposerID, name: "Marko"))
            transport.receive(try signed(.proposal(second), senderID: proposerID, name: "Marko"))

            #expect(store.activeProposals.map(\.id) == [first.id])
        }
    }

    @Test func pendingAcceptsAreBoundedAndEvictTheOldestUnknownProposal() throws {
        try withFixture { instance, transport, _ in
            var timestamp: EpochMilliseconds = 1_000
            let store = try ProposalStore(
                instance: instance,
                transport: transport,
                now: { timestamp }
            )
            let proposalIDs = (0...ProposalStore.maximumPendingProposalCount).map { _ in UUID() }

            for proposalID in proposalIDs {
                transport.receive(try signed(
                    .accept(Accept(proposalID: proposalID, accepter: accepterID)),
                    senderID: accepterID,
                    name: "Ana",
                    timestamp: timestamp
                ))
                timestamp += 1
            }

            let oldestProposal = Proposal(
                id: proposalIDs[0],
                proposer: proposerID,
                createdAt: timestamp,
                expiresAt: timestamp + ProposalStore.proposalLifetime
            )
            transport.receive(try signed(
                .proposal(oldestProposal),
                senderID: proposerID,
                name: "Marko",
                timestamp: timestamp
            ))

            #expect(store.activeProposals.first?.participantIDs == Set([proposerID]))
        }
    }

    private func signed(
        _ payload: Payload,
        senderID: UUID,
        name: String,
        timestamp: EpochMilliseconds = 1_000
    ) throws -> Envelope {
        try Envelope.signed(
            senderID: senderID,
            senderName: name,
            timestamp: timestamp,
            payload: payload,
            teamPhrase: "beans"
        )
    }

    private func withFixture(
        _ body: (AppInstance, ProposalTestTransport, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beanvan-ProposalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = AppInstance(
            displayName: "Local",
            requestedPort: 0,
            teamPhrase: "beans",
            stateDirectory: root,
            id: localID
        )
        try body(instance, ProposalTestTransport(), root)
    }
}

@MainActor
private final class ProposalTestTransport: PeerMessageTransport {
    var sent: [Envelope] = []
    private var envelopeHandlers: [(Envelope) -> Void] = []
    private var connectionHandlers: [() -> Void] = []

    func send(_ envelope: Envelope) {
        sent.append(envelope)
    }

    func addEnvelopeHandler(_ handler: @escaping (Envelope) -> Void) {
        envelopeHandlers.append(handler)
    }

    func addConnectionReadyHandler(_ handler: @escaping () -> Void) {
        connectionHandlers.append(handler)
    }

    func receive(_ envelope: Envelope) {
        envelopeHandlers.forEach { $0(envelope) }
    }

    func connect() {
        connectionHandlers.forEach { $0() }
    }
}

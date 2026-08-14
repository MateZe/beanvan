import Foundation
import Testing
@testable import CoffeeProtocol

struct CoffeeProtocolTests {
    private let senderA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let senderB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func signatureVerifiesAndRejectsTamperingWrongKeysAndOldMessages() throws {
        let now: EpochMilliseconds = 2_000_000_000_000
        let proposal = Proposal(
            id: UUID(),
            proposer: senderA,
            createdAt: now,
            expiresAt: now + 60_000
        )
        let envelope = try Envelope.signed(
            senderID: senderA,
            senderName: "Alice",
            timestamp: now,
            payload: .proposal(proposal),
            teamPhrase: "beans"
        )

        #expect(envelope.verify(teamPhrase: "beans", now: now))
        #expect(!envelope.verify(teamPhrase: "wrong", now: now))

        let tampered = Envelope(
            senderID: envelope.senderID,
            senderName: "Mallory",
            timestamp: envelope.timestamp,
            payload: envelope.payload,
            signature: envelope.signature
        )
        #expect(!tampered.verify(teamPhrase: "beans", now: now))
        #expect(!envelope.verify(teamPhrase: "beans", now: now + Envelope.maximumAge + 1))
    }

    @Test func emptyPhraseUsesAnInteroperableDefaultKeyAndCanonicalJSONIsStable() throws {
        let envelope = try Envelope.signed(
            senderID: senderA,
            senderName: "Alice",
            timestamp: 123,
            payload: .accept(Accept(proposalID: senderB, accepter: senderA))
        )

        let decoded = try JSONDecoder().decode(Envelope.self, from: envelope.canonicalJSONData())
        #expect(decoded == envelope)
        #expect(decoded.verify(now: 123))
        #expect(try decoded.canonicalJSONData() == envelope.canonicalJSONData())
        #expect(TeamPhrase.shortHash(for: "") == "5cd3457e5892")
        #expect(TeamPhrase.shortHash(for: "beans").count == 12)
        #expect(TeamPhrase.shortHash(for: "beans") != TeamPhrase.shortHash(for: "tea"))
    }

    @Test func scheduleRejectsMoreThanThreeEntries() {
        let entries = (0..<4).map { index in
            ScheduleEntry(
                id: UUID(),
                time: ScheduleTime(hour: index, minute: 0),
                weekdays: [.monday],
                lastEditedBy: senderA,
                lastEditedAt: 1
            )
        }
        #expect(throws: CoffeeProtocolError.tooManyScheduleEntries) {
            try Schedule(entries: entries, lastModified: 1)
        }
    }

    @Test func lwwMergeUsesTimestampThenSenderID() throws {
        let older = VersionedSchedule(
            schedule: try Schedule(entries: [], lastModified: 100),
            senderID: senderA
        )
        let newer = VersionedSchedule(
            schedule: try Schedule(entries: [], lastModified: 200),
            senderID: senderB
        )

        #expect(merge(local: older, incoming: newer) == newer)
        #expect(merge(local: newer, incoming: older) == newer)

        let tiedA = VersionedSchedule(
            schedule: try Schedule(entries: [], lastModified: 300),
            senderID: senderA
        )
        let tiedB = VersionedSchedule(
            schedule: try Schedule(entries: [], lastModified: 300),
            senderID: senderB
        )
        #expect(merge(local: tiedA, incoming: tiedB) == tiedA)
        #expect(merge(local: tiedB, incoming: tiedA) == tiedA)
    }

    @Test func quorumCountsProposerOnceAndIgnoresDuplicateOrUnrelatedAccepts() {
        let proposal = Proposal(id: UUID(), proposer: senderA, createdAt: 1, expiresAt: 10)
        let otherProposalID = UUID()
        let accepts = [
            Accept(proposalID: proposal.id, accepter: senderA),
            Accept(proposalID: proposal.id, accepter: senderB),
            Accept(proposalID: proposal.id, accepter: senderB),
            Accept(proposalID: otherProposalID, accepter: UUID()),
        ]

        #expect(quorumMet(proposal: proposal, accepts: [], threshold: 1))
        #expect(quorumMet(proposal: proposal, accepts: accepts, threshold: 2))
        #expect(!quorumMet(proposal: proposal, accepts: accepts, threshold: 3))
    }

    @Test func expiryIncludesTheExpiryInstant() {
        let proposal = Proposal(id: UUID(), proposer: senderA, createdAt: 100, expiresAt: 200)
        #expect(!isExpired(proposal, at: 199))
        #expect(isExpired(proposal, at: 200))
    }

    @Test func proposalCancellationRoundTripsAndAuthenticates() throws {
        let cancellation = ProposalCancellation(proposalID: UUID(), proposer: senderA)
        let envelope = try Envelope.signed(
            senderID: senderA,
            senderName: "Alice",
            timestamp: 123,
            payload: .proposalCancellation(cancellation),
            teamPhrase: "beans"
        )

        let decoded = try JSONDecoder().decode(Envelope.self, from: envelope.canonicalJSONData())
        #expect(decoded == envelope)
        #expect(decoded.verify(teamPhrase: "beans", now: 123))
    }

    @Test func cooldownRequiresTheFullIntervalAndRejectsClockRollback() {
        #expect(cooldownElapsed(lastProposalAt: nil, now: 100, cooldown: 50))
        #expect(!cooldownElapsed(lastProposalAt: 100, now: 149, cooldown: 50))
        #expect(cooldownElapsed(lastProposalAt: 100, now: 150, cooldown: 50))
        #expect(!cooldownElapsed(lastProposalAt: 200, now: 150, cooldown: 50))
    }
}

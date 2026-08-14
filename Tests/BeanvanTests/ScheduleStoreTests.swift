import CoffeeProtocol
import Foundation
import Testing
@testable import Beanvan

@MainActor
struct ScheduleStoreTests {
    private let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

    @Test func connectionSendsCurrentPersistedSchedule() throws {
        try withFixture { instance, transport in
            let store = try ScheduleStore(instance: instance, transport: transport, now: { 1_000 })

            #expect(transport.sent.isEmpty)
            transport.simulateConnectionReady()

            let envelope = try #require(transport.sent.first)
            guard case .schedule(let sentSchedule) = envelope.payload else {
                Issue.record("Expected a schedule payload")
                return
            }
            #expect(sentSchedule == store.schedule)
            #expect(envelope.senderID == localID)
            #expect(envelope.verify(teamPhrase: "beans", now: 1_000))
        }
    }

    @Test func localEditBumpsAttributesPersistsAndBroadcasts() throws {
        try withFixture { instance, transport in
            let entryID = UUID()
            let store = try ScheduleStore(instance: instance, transport: transport, now: { 2_000 })
            let draft = ScheduleEntry(
                id: entryID,
                time: ScheduleTime(hour: 10, minute: 30),
                weekdays: [.monday, .friday],
                lastEditedBy: remoteID,
                lastEditedAt: 1
            )

            try store.replaceEntries([draft])

            #expect(store.schedule.lastModified == 2_000)
            #expect(store.schedule.entries.first?.lastEditedBy == localID)
            #expect(store.schedule.entries.first?.lastEditedAt == 2_000)
            #expect(transport.sent.count == 1)

            let reloaded = try ScheduleStore(
                instance: instance,
                transport: FakeScheduleTransport(),
                now: { 2_001 }
            )
            #expect(reloaded.schedule == store.schedule)
        }
    }

    @Test func incomingMergePersistsNotifiesAndRebroadcasts() throws {
        try withFixture { instance, transport in
            let entry = ScheduleEntry(
                id: UUID(),
                time: ScheduleTime(hour: 10, minute: 30),
                weekdays: [.tuesday],
                lastEditedBy: remoteID,
                lastEditedAt: 3_000
            )
            let remoteSchedule = try Schedule(entries: [entry], lastModified: 3_000)
            let envelope = try Envelope.signed(
                senderID: remoteID,
                senderName: "Ana",
                timestamp: 3_000,
                payload: .schedule(remoteSchedule),
                teamPhrase: "beans"
            )
            let store = try ScheduleStore(instance: instance, transport: transport, now: { 3_001 })

            transport.simulateReceive(envelope)

            #expect(store.schedule == remoteSchedule)
            #expect(store.latestChangeEvent?.message == "Ana added coffee at 10:30")
            #expect(store.latestChangeEvent?.changedAt == Date(timeIntervalSince1970: 3))
            #expect(transport.sent.count == 1)

            let reloaded = try ScheduleStore(
                instance: instance,
                transport: FakeScheduleTransport(),
                now: { 3_002 }
            )
            #expect(reloaded.schedule == remoteSchedule)
        }
    }

    @Test func movedTimeProducesSpecificAttribution() throws {
        try withFixture { instance, transport in
            let entryID = UUID()
            let store = try ScheduleStore(instance: instance, transport: transport, now: { 1_000 })
            let original = ScheduleEntry(
                id: entryID,
                time: ScheduleTime(hour: 9, minute: 0),
                weekdays: [.monday],
                lastEditedBy: localID,
                lastEditedAt: 1_000
            )
            try store.replaceEntries([original])
            transport.sent.removeAll()
            let moved = ScheduleEntry(
                id: entryID,
                time: ScheduleTime(hour: 10, minute: 30),
                weekdays: [.monday],
                lastEditedBy: remoteID,
                lastEditedAt: 2_000
            )
            let remoteSchedule = try Schedule(entries: [moved], lastModified: 2_000)
            let envelope = try Envelope.signed(
                senderID: remoteID,
                senderName: "Ana",
                timestamp: 2_000,
                payload: .schedule(remoteSchedule),
                teamPhrase: "beans"
            )

            transport.simulateReceive(envelope)

            #expect(store.latestChangeEvent?.message == "Ana moved coffee to 10:30")
        }
    }

    @Test func olderIncomingScheduleIsIgnored() throws {
        try withFixture { instance, transport in
            let store = try ScheduleStore(instance: instance, transport: transport, now: { 5_000 })
            try store.replaceEntries([])
            transport.sent.removeAll()
            let older = try Schedule(entries: [], lastModified: 4_000)
            let envelope = try Envelope.signed(
                senderID: remoteID,
                senderName: "Ana",
                timestamp: 5_000,
                payload: .schedule(older),
                teamPhrase: "beans"
            )

            transport.simulateReceive(envelope)

            #expect(store.schedule.lastModified == 5_000)
            #expect(store.latestChangeEvent == nil)
            #expect(transport.sent.isEmpty)
        }
    }

    private func withFixture(
        _ body: (AppInstance, FakeScheduleTransport) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beanvan-ScheduleStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = AppInstance(
            displayName: "Local",
            requestedPort: 0,
            teamPhrase: "beans",
            stateDirectory: root,
            id: localID
        )
        try body(instance, FakeScheduleTransport())
    }
}

@MainActor
private final class FakeScheduleTransport: PeerMessageTransport {
    var sent: [Envelope] = []
    private var envelopeHandlers: [(Envelope) -> Void] = []
    private var connectionReadyHandlers: [() -> Void] = []

    func send(_ envelope: Envelope) {
        sent.append(envelope)
    }

    func addEnvelopeHandler(_ handler: @escaping (Envelope) -> Void) {
        envelopeHandlers.append(handler)
    }

    func addConnectionReadyHandler(_ handler: @escaping () -> Void) {
        connectionReadyHandlers.append(handler)
    }

    func simulateReceive(_ envelope: Envelope) {
        envelopeHandlers.forEach { $0(envelope) }
    }

    func simulateConnectionReady() {
        connectionReadyHandlers.forEach { $0() }
    }
}

import CoffeeProtocol
import Combine
import Foundation
import os

struct ScheduleChangeEvent: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let changedAt: Date
}

enum ScheduleStoreError: Error {
    case timestampExhausted
}

@MainActor
protocol PeerMessageTransport: AnyObject {
    func send(_ envelope: Envelope)
    func addEnvelopeHandler(_ handler: @escaping (Envelope) -> Void)
    func addConnectionReadyHandler(_ handler: @escaping () -> Void)
}

extension PeerManager: PeerMessageTransport {}

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var schedule: Schedule
    @Published private(set) var latestChangeEvent: ScheduleChangeEvent?

    private var instance: AppInstance
    private let transport: any PeerMessageTransport
    private let persistenceURL: URL
    private let fileManager: FileManager
    private let now: () -> EpochMilliseconds
    private let logger = Logger(subsystem: "com.josipmusa.cuppajoe", category: "schedule")
    private var versionSenderID: UUID

    init(
        instance: AppInstance,
        transport: any PeerMessageTransport,
        fileManager: FileManager = .default,
        now: @escaping () -> EpochMilliseconds = {
            EpochMilliseconds(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        self.instance = instance
        self.transport = transport
        self.fileManager = fileManager
        self.now = now
        persistenceURL = instance.stateDirectory.appendingPathComponent("schedule.json")

        if fileManager.fileExists(atPath: persistenceURL.path) {
            let persisted = try JSONDecoder().decode(
                PersistedSchedule.self,
                from: Data(contentsOf: persistenceURL)
            )
            schedule = persisted.schedule
            versionSenderID = persisted.senderID
        } else {
            schedule = try Schedule(entries: [], lastModified: 0)
            versionSenderID = instance.id
        }

        transport.addConnectionReadyHandler { [weak self] in
            self?.broadcastCurrentSchedule()
        }
        transport.addEnvelopeHandler { [weak self] envelope in
            self?.receive(envelope)
        }
    }

    func replaceEntries(_ entries: [ScheduleEntry]) throws {
        let previous = schedule
        let timestamp = try nextTimestamp()
        let oldEntries = Dictionary(uniqueKeysWithValues: schedule.entries.map { ($0.id, $0) })
        let attributedEntries = entries.map { entry in
            guard let old = oldEntries[entry.id],
                  old.time == entry.time,
                  old.weekdays == entry.weekdays else {
                return ScheduleEntry(
                    id: entry.id,
                    time: entry.time,
                    weekdays: entry.weekdays,
                    lastEditedBy: instance.id,
                    lastEditedAt: timestamp
                )
            }
            return old
        }
        let updated = try Schedule(entries: attributedEntries, lastModified: timestamp)
        try persist(schedule: updated, senderID: instance.id)
        schedule = updated
        versionSenderID = instance.id
        if Self.hasContentChange(from: previous, to: updated) {
            latestChangeEvent = ScheduleChangeEvent(
                message: Self.attributionMessage(
                    from: previous,
                    to: updated,
                    editorName: instance.displayName
                ),
                changedAt: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            )
        }
        broadcastCurrentSchedule()
    }

    func updateInstance(_ instance: AppInstance) {
        self.instance = instance
    }

    private func receive(_ envelope: Envelope) {
        guard case .schedule(let incomingSchedule) = envelope.payload else { return }

        let local = VersionedSchedule(schedule: schedule, senderID: versionSenderID)
        let incoming = VersionedSchedule(schedule: incomingSchedule, senderID: envelope.senderID)
        let merged = merge(local: local, incoming: incoming)
        guard merged != local else { return }
        let scheduleChanged = merged.schedule != schedule

        do {
            try persist(schedule: merged.schedule, senderID: merged.senderID)
        } catch {
            logger.error("Failed to persist a merged schedule: \(error.localizedDescription, privacy: .public)")
            return
        }

        let previous = schedule
        schedule = merged.schedule
        versionSenderID = merged.senderID
        if scheduleChanged {
            latestChangeEvent = ScheduleChangeEvent(
                message: Self.attributionMessage(
                    from: previous,
                    to: merged.schedule,
                    editorName: envelope.senderName
                ),
                changedAt: Date(
                    timeIntervalSince1970: TimeInterval(merged.schedule.lastModified) / 1_000
                )
            )
        }
        broadcastCurrentSchedule()
    }

    private func broadcastCurrentSchedule() {
        do {
            let envelope = try Envelope.signed(
                senderID: instance.id,
                senderName: instance.displayName,
                timestamp: now(),
                payload: .schedule(schedule),
                teamPhrase: instance.teamPhrase
            )
            transport.send(envelope)
        } catch {
            logger.error("Failed to sign the current schedule: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(schedule: Schedule, senderID: UUID) throws {
        try fileManager.createDirectory(
            at: instance.stateDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedSchedule(schedule: schedule, senderID: senderID))
        try data.write(to: persistenceURL, options: .atomic)
    }

    private func nextTimestamp() throws -> EpochMilliseconds {
        let current = now()
        guard schedule.lastModified < EpochMilliseconds.max else {
            throw ScheduleStoreError.timestampExhausted
        }
        return max(current, schedule.lastModified + 1)
    }

    private static func attributionMessage(
        from oldSchedule: Schedule,
        to newSchedule: Schedule,
        editorName: String
    ) -> String {
        let oldByID = Dictionary(uniqueKeysWithValues: oldSchedule.entries.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newSchedule.entries.map { ($0.id, $0) })

        for entry in newSchedule.entries {
            if let old = oldByID[entry.id], old.time != entry.time {
                return "\(editorName) moved coffee to \(format(entry.time))"
            }
        }
        if let added = newSchedule.entries.first(where: { oldByID[$0.id] == nil }) {
            return "\(editorName) added coffee at \(format(added.time))"
        }
        if oldSchedule.entries.contains(where: { newByID[$0.id] == nil }) {
            return "\(editorName) removed a coffee time"
        }
        return "\(editorName) updated the coffee schedule"
    }

    private static func hasContentChange(from oldSchedule: Schedule, to newSchedule: Schedule) -> Bool {
        let oldEntries = oldSchedule.entries.map {
            ScheduleEntryContent(id: $0.id, time: $0.time, weekdays: $0.weekdays)
        }
        let newEntries = newSchedule.entries.map {
            ScheduleEntryContent(id: $0.id, time: $0.time, weekdays: $0.weekdays)
        }
        return oldEntries != newEntries
    }

    private static func format(_ time: ScheduleTime) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }
}

private struct ScheduleEntryContent: Equatable {
    let id: UUID
    let time: ScheduleTime
    let weekdays: Set<Weekday>
}

private struct PersistedSchedule: Codable {
    let schedule: Schedule
    let senderID: UUID
}

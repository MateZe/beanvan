import CoffeeProtocol
import Foundation
import Testing
@testable import Beanvan

@MainActor
struct ScheduleFiringSchedulerTests {
    private let editorID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    @Test func nextFireUsesLocalWeekdayAndTime() throws {
        let calendar = testCalendar()
        let fridayMorning = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 9
        )))
        let schedule = try makeSchedule([
            entry(hour: 9, minute: 0, weekdays: [.monday]),
            entry(hour: 10, minute: 30, weekdays: [.friday]),
        ])

        let next = ScheduleTiming.nextFireDate(
            after: fridayMorning,
            schedule: schedule,
            calendar: calendar
        )

        #expect(next == calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10,
            minute: 30
        )))
    }

    @Test func passedTimeRollsForwardWithoutCatchUp() throws {
        let calendar = testCalendar()
        let fridayAfternoon = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 11
        )))
        let schedule = try makeSchedule([
            entry(hour: 10, minute: 30, weekdays: [.friday]),
            entry(hour: 9, minute: 0, weekdays: [.monday]),
        ])

        let next = ScheduleTiming.nextFireDate(
            after: fridayAfternoon,
            schedule: schedule,
            calendar: calendar
        )

        #expect(next == calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 17,
            hour: 9
        )))
    }

    @Test func fireGateRequiresPeerAndSkipTodayOff() {
        let fireDate = Date(timeIntervalSince1970: 1_000)
        let onTime = fireDate.addingTimeInterval(0.5)

        #expect(ScheduleTiming.shouldFire(
            scheduledAt: fireDate,
            now: onTime,
            peerCount: 1,
            isSkippingToday: false
        ))
        #expect(!ScheduleTiming.shouldFire(
            scheduledAt: fireDate,
            now: onTime,
            peerCount: 0,
            isSkippingToday: false
        ))
        #expect(!ScheduleTiming.shouldFire(
            scheduledAt: fireDate,
            now: onTime,
            peerCount: 1,
            isSkippingToday: true
        ))
    }

    @Test func delayedTimerNeverCreatesCatchUpFire() {
        let fireDate = Date(timeIntervalSince1970: 1_000)

        #expect(!ScheduleTiming.shouldFire(
            scheduledAt: fireDate,
            now: fireDate.addingTimeInterval(60),
            peerCount: 1,
            isSkippingToday: false
        ))
    }

    @Test func scheduleEditRearmsTimerWithPublishedSchedule() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beanvan-SchedulerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = testCalendar()
        let currentDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        )))
        let instance = AppInstance(
            displayName: "Local",
            requestedPort: 0,
            teamPhrase: "beans",
            stateDirectory: root,
            id: editorID
        )
        let store = try ScheduleStore(
            instance: instance,
            transport: SchedulerTestTransport(),
            now: { EpochMilliseconds(currentDate.timeIntervalSince1970 * 1_000) }
        )
        let scheduler = ScheduleFiringScheduler(
            instance: instance,
            scheduleStore: store,
            peerManager: SchedulerTestPeerState(),
            now: { currentDate },
            calendar: { calendar },
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )
        scheduler.start {}
        defer { scheduler.stop() }

        try store.replaceEntries([entry(hour: 12, minute: 15, weekdays: [.friday])])

        #expect(scheduler.nextFireDate == calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 12,
            minute: 15
        )))
    }

    @Test func skipTodayPausesAdvertisingAndResetsOnTheNextLocalDay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beanvan-SchedulerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let calendar = testCalendar()
        var currentDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        )))
        let instance = AppInstance(
            displayName: "Local",
            requestedPort: 0,
            teamPhrase: "beans",
            stateDirectory: root,
            id: editorID
        )
        let transport = SchedulerTestTransport()
        let store = try ScheduleStore(instance: instance, transport: transport)
        let peers = SchedulerTestPeerState()
        let notifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let scheduler = ScheduleFiringScheduler(
            instance: instance,
            scheduleStore: store,
            peerManager: peers,
            now: { currentDate },
            calendar: { calendar },
            notificationCenter: notifications,
            workspaceNotificationCenter: workspaceNotifications
        )
        scheduler.start {}

        scheduler.setSkippingToday(true)

        #expect(scheduler.isSkippingToday)
        #expect(peers.advertisingStates.last == false)

        currentDate = try #require(calendar.date(byAdding: .day, value: 1, to: currentDate))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                notifications.post(name: .NSCalendarDayChanged, object: nil)
                continuation.resume()
            }
        }

        #expect(!scheduler.isSkippingToday)
        #expect(peers.advertisingStates.last == true)
        scheduler.stop()
    }

    private func testCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sarajevo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func entry(hour: Int, minute: Int, weekdays: Set<Weekday>) -> ScheduleEntry {
        ScheduleEntry(
            id: UUID(),
            time: ScheduleTime(hour: hour, minute: minute),
            weekdays: weekdays,
            lastEditedBy: editorID,
            lastEditedAt: 1
        )
    }

    private func makeSchedule(_ entries: [ScheduleEntry]) throws -> Schedule {
        try Schedule(entries: entries, lastModified: 1)
    }
}

@MainActor
private final class SchedulerTestTransport: PeerMessageTransport {

    func send(_ envelope: Envelope) {}
    func addEnvelopeHandler(_ handler: @escaping (Envelope) -> Void) {}
    func addConnectionReadyHandler(_ handler: @escaping () -> Void) {}
}

@MainActor
private final class SchedulerTestPeerState: SchedulePeerState {
    var presentPeers: [PresentPeer] = []
    var advertisingStates: [Bool] = []

    func setAdvertisingEnabled(_ enabled: Bool) {
        advertisingStates.append(enabled)
    }
}

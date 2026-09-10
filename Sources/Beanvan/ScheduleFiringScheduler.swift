import AppKit
import CoffeeProtocol
import Combine
import Foundation
import os

@MainActor
protocol SchedulePeerState: AnyObject {
    var presentPeers: [PresentPeer] { get }

    func setAdvertisingEnabled(_ enabled: Bool)
}

extension PeerManager: SchedulePeerState {}

enum ScheduleTiming {
    static func nextFireDate(
        after date: Date,
        schedule: Schedule,
        calendar: Calendar
    ) -> Date? {
        schedule.entries.compactMap { entry in
            guard (0...23).contains(entry.time.hour),
                  (0...59).contains(entry.time.minute) else { return nil }

            return entry.weekdays.compactMap { weekday in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(
                        hour: entry.time.hour,
                        minute: entry.time.minute,
                        second: 0,
                        weekday: calendarWeekday(for: weekday)
                    ),
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            }.min()
        }.min()
    }

    static func shouldFire(
        scheduledAt: Date,
        now: Date,
        peerCount: Int,
        isSkippingToday: Bool
    ) -> Bool {
        guard peerCount > 0, !isSkippingToday, now >= scheduledAt else { return false }

        // Normal timer jitter is tolerated, but a delayed timer is never a
        // catch-up fire. Sleep also invalidates the timer before the machine
        // suspends, providing the primary guarantee for that case.
        return now.timeIntervalSince(scheduledAt) < 5
    }

    private static func calendarWeekday(for weekday: Weekday) -> Int {
        weekday == .sunday ? 1 : weekday.rawValue + 1
    }
}

@MainActor
final class ScheduleFiringScheduler: NSObject, ObservableObject {
    @Published private(set) var isSkippingToday: Bool
    @Published private(set) var nextFireDate: Date?

    private let scheduleStore: ScheduleStore
    private let peerState: any SchedulePeerState
    private let skipStateURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "com.josipmusa.beanvan", category: "scheduler")

    private var scheduleCancellable: AnyCancellable?
    private var notificationObservers: [NSObjectProtocol] = []
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var fireTimer: Timer?
    private var midnightTimer: Timer?
    private var skippedDay: LocalDay?
    private var onFire: (() -> Void)?
    private var isStarted = false

    init(
        instance: AppInstance,
        scheduleStore: ScheduleStore,
        peerManager: any SchedulePeerState,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.scheduleStore = scheduleStore
        peerState = peerManager
        self.fileManager = fileManager
        self.now = now
        self.calendar = calendar
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        skipStateURL = instance.stateDirectory.appendingPathComponent("skip-today.json")

        let savedDay = Self.loadSkippedDay(from: skipStateURL)
        let today = LocalDay(date: now(), calendar: calendar())
        skippedDay = savedDay == today ? savedDay : nil
        isSkippingToday = skippedDay != nil
        nextFireDate = nil
        super.init()

        peerState.setAdvertisingEnabled(!isSkippingToday)
        if savedDay != nil, skippedDay == nil {
            try? fileManager.removeItem(at: skipStateURL)
        }
    }

    func start(onFire: @escaping () -> Void) {
        self.onFire = onFire
        guard !isStarted else { return }
        isStarted = true

        scheduleCancellable = scheduleStore.$schedule
            .dropFirst()
            .sink { [weak self] updatedSchedule in
                self?.rearmForCurrentState(using: updatedSchedule)
            }
        notificationObservers = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemTimeChanged()
                }
            }
        }
        workspaceNotificationObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceWillSleep()
                }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceDidWake()
                }
            },
        ]
        rearmForCurrentState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        fireTimer?.invalidate()
        fireTimer = nil
        midnightTimer?.invalidate()
        midnightTimer = nil
        scheduleCancellable = nil
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
        workspaceNotificationObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceNotificationObservers.removeAll()
        onFire = nil
    }

    func setSkippingToday(_ skipping: Bool) {
        let today = LocalDay(date: now(), calendar: calendar())
        guard skipping != isSkippingToday || (skipping && skippedDay != today) else { return }

        skippedDay = skipping ? today : nil
        isSkippingToday = skipping
        persistSkippedDay()
        peerState.setAdvertisingEnabled(!skipping)
        armMidnightReset()
    }

    private func workspaceWillSleep() {
        fireTimer?.invalidate()
        fireTimer = nil
        nextFireDate = nil
    }

    private func workspaceDidWake() {
        rearmForCurrentState()
    }

    private func systemTimeChanged() {
        rearmForCurrentState()
    }

    private func rearmForCurrentState(using schedule: Schedule? = nil) {
        reconcileSkippedDay()
        armFireTimer(using: schedule ?? scheduleStore.schedule)
        armMidnightReset()
    }

    private func armFireTimer(using schedule: Schedule) {
        fireTimer?.invalidate()
        let currentDate = now()
        guard let fireDate = ScheduleTiming.nextFireDate(
            after: currentDate,
            schedule: schedule,
            calendar: calendar()
        ) else {
            fireTimer = nil
            nextFireDate = nil
            return
        }

        nextFireDate = fireDate
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fireTimerDidRun(scheduledAt: fireDate)
            }
        }
        fireTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fireTimerDidRun(scheduledAt fireDate: Date) {
        let currentDate = now()
        if ScheduleTiming.shouldFire(
            scheduledAt: fireDate,
            now: currentDate,
            peerCount: peerState.presentPeers.count,
            isSkippingToday: isSkippingToday
        ) {
            onFire?()
        }
        armFireTimer(using: scheduleStore.schedule)
    }

    private func armMidnightReset() {
        midnightTimer?.invalidate()
        guard isSkippingToday else {
            midnightTimer = nil
            return
        }

        let currentDate = now()
        guard let nextMidnight = calendar().date(
            byAdding: .day,
            value: 1,
            to: calendar().startOfDay(for: currentDate)
        ) else { return }
        let timer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileSkippedDay()
                self?.armMidnightReset()
            }
        }
        midnightTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reconcileSkippedDay() {
        guard let skippedDay else { return }
        let today = LocalDay(date: now(), calendar: calendar())
        guard skippedDay != today else { return }

        self.skippedDay = nil
        isSkippingToday = false
        persistSkippedDay()
        peerState.setAdvertisingEnabled(true)
    }

    private func persistSkippedDay() {
        do {
            if let skippedDay {
                try fileManager.createDirectory(
                    at: skipStateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(skippedDay).write(to: skipStateURL, options: .atomic)
            } else if fileManager.fileExists(atPath: skipStateURL.path) {
                try fileManager.removeItem(at: skipStateURL)
            }
        } catch {
            logger.error("Failed to persist skip-today state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadSkippedDay(from url: URL) -> LocalDay? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalDay.self, from: data)
    }
}

private struct LocalDay: Codable, Equatable {
    let year: Int
    let month: Int
    let day: Int

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
    }
}

import AppKit
import CoreGraphics
import Foundation
import os

enum FiringSuppressionReason: String, Equatable {
    case screenLocked
    case displayAsleep
    case fullScreenApp
    case meeting
}

@MainActor
struct FiringGateEnvironment {
    struct FrontmostApplication {
        let bundleIdentifier: String?
        let processIdentifier: pid_t
    }

    var isScreenLocked: () -> Bool
    var frontmostApplication: () -> FrontmostApplication?
    var runningBundleIdentifiers: () -> Set<String>
    var presentationOptions: () -> NSApplication.PresentationOptions
    var frontmostWindowCoversScreen: (pid_t) -> Bool

    static let live = FiringGateEnvironment(
        isScreenLocked: {
            guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
                return false
            }
            return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        },
        frontmostApplication: {
            guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontmostApplication(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier
            )
        },
        runningBundleIdentifiers: {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        presentationOptions: {
            NSApp.currentSystemPresentationOptions
        },
        frontmostWindowCoversScreen: { processIdentifier in
            Self.windowCoversScreen(processIdentifier: processIdentifier)
        }
    )

    private static func windowCoversScreen(processIdentifier: pid_t) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screens = NSScreen.screens.map(\.frame)
        guard let primaryScreen = screens.first(where: { $0.origin == .zero }) else {
            return false
        }

        return windowInfo.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzBounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return false
            }
            let appKitBounds = appKitWindowBounds(
                from: quartzBounds,
                primaryScreenTop: primaryScreen.maxY
            )
            return frontmostWindow(appKitBounds, coversAnyOf: screens)
        }
    }

    static func appKitWindowBounds(
        from quartzBounds: CGRect,
        primaryScreenTop: CGFloat
    ) -> CGRect {
        CGRect(
            x: quartzBounds.minX,
            y: primaryScreenTop - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height
        )
    }

    static func frontmostWindow(
        _ window: CGRect,
        coversAnyOf screens: [CGRect]
    ) -> Bool {
        screens.contains { screen in
            let tolerance: CGFloat = 2
            return abs(window.minX - screen.minX) <= tolerance
                && abs(window.minY - screen.minY) <= tolerance
                && abs(window.maxX - screen.maxX) <= tolerance
                && abs(window.maxY - screen.maxY) <= tolerance
        }
    }
}

@MainActor
final class FiringGate: NSObject {
    static let knownMeetingBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webex",
        "cisco-systems.spark",
        "co.around.desktop",
        "com.around.around",
    ]

    private let environment: FiringGateEnvironment
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "com.josipmusa.beanvan", category: "firing-gate")
    private(set) var isDisplayAsleep: Bool

    init(
        environment: FiringGateEnvironment = .live,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isDisplayAsleep: Bool = false
    ) {
        self.environment = environment
        notificationCenter = workspaceNotificationCenter
        self.isDisplayAsleep = isDisplayAsleep
        super.init()

        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    @objc private func screensDidSleep() {
        isDisplayAsleep = true
    }

    @objc private func screensDidWake() {
        isDisplayAsleep = false
    }

    func allowsFire(avoidsFullScreenApps: Bool, avoidsCalls: Bool) -> Bool {
        guard let reason = suppressionReason(
            avoidsFullScreenApps: avoidsFullScreenApps,
            avoidsCalls: avoidsCalls
        ) else { return true }
        logger.debug("Overlay suppressed: \(reason.rawValue, privacy: .public)")
        return false
    }

    func suppressionReason(
        avoidsFullScreenApps: Bool,
        avoidsCalls: Bool
    ) -> FiringSuppressionReason? {
        if environment.isScreenLocked() { return .screenLocked }
        if isDisplayAsleep { return .displayAsleep }

        guard let frontmostApplication = environment.frontmostApplication() else { return nil }

        if avoidsFullScreenApps {
            let options = environment.presentationOptions()
            if options.contains(.fullScreen)
                || options.contains(.hideMenuBar)
                || environment.frontmostWindowCoversScreen(frontmostApplication.processIdentifier) {
                return .fullScreenApp
            }
        }

        if avoidsCalls,
           let bundleIdentifier = frontmostApplication.bundleIdentifier,
           Self.knownMeetingBundleIdentifiers.contains(bundleIdentifier.lowercased()),
           environment.runningBundleIdentifiers().contains(bundleIdentifier) {
            return .meeting
        }
        return nil
    }
}

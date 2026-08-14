import AppKit
import Foundation
import Testing
@testable import CuppaJoe

@MainActor
struct FiringGateTests {
    @Test func lockedScreenSuppressesFire() {
        let gate = makeGate(isScreenLocked: true)

        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: false
        ) == .screenLocked)
    }

    @Test func displaySleepAndWakeNotificationsUpdateSuppression() {
        let notifications = NotificationCenter()
        let gate = makeGate(notificationCenter: notifications)

        notifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: false
        ) == .displayAsleep)

        notifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: false
        ) == nil)
    }

    @Test func fullScreenPresentationOptionSuppressesWhenEnabled() {
        let gate = makeGate(presentationOptions: [.fullScreen])

        #expect(gate.suppressionReason(
            avoidsFullScreenApps: true,
            avoidsCalls: false
        ) == .fullScreenApp)
        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: false
        ) == nil)
    }

    @Test func screenCoveringFrontmostWindowSuppressesWhenEnabled() {
        let gate = makeGate(windowCoversScreen: true)

        #expect(gate.suppressionReason(
            avoidsFullScreenApps: true,
            avoidsCalls: false
        ) == .fullScreenApp)
    }

    @Test func quartzBoundsConvertCorrectlyForScreenAbovePrimaryDisplay() {
        let primaryScreen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let upperScreen = CGRect(x: 740, y: 1107, width: 1920, height: 1080)
        let quartzFullScreenWindow = CGRect(x: 740, y: -1080, width: 1920, height: 1080)

        let appKitWindow = FiringGateEnvironment.appKitWindowBounds(
            from: quartzFullScreenWindow,
            primaryScreenTop: primaryScreen.maxY
        )

        #expect(appKitWindow == upperScreen)
        #expect(FiringGateEnvironment.frontmostWindow(
            appKitWindow,
            coversAnyOf: [primaryScreen, upperScreen]
        ))
    }

    @Test func frontmostRunningMeetingAppSuppressesWhenEnabled() {
        let bundleIdentifier = "us.zoom.xos"
        let gate = makeGate(
            frontmostBundleIdentifier: bundleIdentifier,
            runningBundleIdentifiers: [bundleIdentifier]
        )

        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: true
        ) == .meeting)
        #expect(gate.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: false
        ) == nil)
    }

    @Test func meetingAppMustBeBothKnownRunningAndFrontmost() {
        let frontmostOnly = makeGate(
            frontmostBundleIdentifier: "us.zoom.xos",
            runningBundleIdentifiers: []
        )
        let runningOnly = makeGate(
            frontmostBundleIdentifier: "com.example.editor",
            runningBundleIdentifiers: ["us.zoom.xos"]
        )

        #expect(frontmostOnly.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: true
        ) == nil)
        #expect(runningOnly.suppressionReason(
            avoidsFullScreenApps: false,
            avoidsCalls: true
        ) == nil)
    }

    private func makeGate(
        isScreenLocked: Bool = false,
        frontmostBundleIdentifier: String? = "com.example.editor",
        runningBundleIdentifiers: Set<String> = [],
        presentationOptions: NSApplication.PresentationOptions = [],
        windowCoversScreen: Bool = false,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> FiringGate {
        FiringGate(
            environment: FiringGateEnvironment(
                isScreenLocked: { isScreenLocked },
                frontmostApplication: {
                    FiringGateEnvironment.FrontmostApplication(
                        bundleIdentifier: frontmostBundleIdentifier,
                        processIdentifier: 42
                    )
                },
                runningBundleIdentifiers: { runningBundleIdentifiers },
                presentationOptions: { presentationOptions },
                frontmostWindowCoversScreen: { _ in windowCoversScreen }
            ),
            workspaceNotificationCenter: notificationCenter
        )
    }
}

import AppKit
import CoffeeProtocol
import SwiftUI

@main
struct CuppaJoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            if let peerManager = appModel.peerManager,
               let scheduleStore = appModel.scheduleStore,
               let scheduler = appModel.scheduler,
               let proposalStore = appModel.proposalStore {
                CoffeePopover(
                    appModel: appModel,
                    peerManager: peerManager,
                    scheduleStore: scheduleStore,
                    scheduler: scheduler,
                    proposalStore: proposalStore,
                    previewAnimation: appDelegate.previewAnimation
                )
            } else {
                ContentUnavailableView(
                    "CuppaJoe could not start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(appModel.startupError ?? "Unknown startup error")
                )
                .frame(width: 312, height: 220)
            }
        } label: {
            if let peerManager = appModel.peerManager,
               let scheduler = appModel.scheduler,
               let proposalStore = appModel.proposalStore {
                MenuBarTruckIcon(
                    peerManager: peerManager,
                    scheduler: scheduler,
                    proposalStore: proposalStore
                )
            } else {
                Image(nsImage: TruckTemplateImage.image(steam: false))
                    .accessibilityLabel("CuppaJoe")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let proposalStore = appModel.proposalStore {
                CuppaJoeSettingsView(appModel: appModel, proposalStore: proposalStore)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let peerManager: PeerManager?
    let scheduleStore: ScheduleStore?
    let scheduler: ScheduleFiringScheduler?
    let proposalStore: ProposalStore?
    let startupError: String?

    @Published private(set) var displayName = ""
    @Published private(set) var teamPhrase = ""
    @Published private(set) var avoidsFullScreenApps = true
    @Published private(set) var avoidsCalls = true
    @Published private(set) var settingsError: String?

    private var instance: AppInstance?

    private init() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let baseInstance = try AppInstance.load(arguments: arguments)
            let settings = try AppSettings.load(for: baseInstance, arguments: arguments).validated()
            let instance = AppInstance(
                displayName: settings.displayName,
                requestedPort: baseInstance.requestedPort,
                teamPhrase: settings.teamPhrase,
                stateDirectory: baseInstance.stateDirectory,
                id: baseInstance.id
            )
            let manager = PeerManager(instance: instance, teamPhrase: instance.teamPhrase)
            let scheduleStore = try ScheduleStore(instance: instance, transport: manager)
            let proposalStore = try ProposalStore(instance: instance, transport: manager)
            let scheduler = ScheduleFiringScheduler(
                instance: instance,
                scheduleStore: scheduleStore,
                peerManager: manager
            )
            try manager.start()

            self.instance = instance
            displayName = instance.displayName
            teamPhrase = instance.teamPhrase
            avoidsFullScreenApps = settings.avoidsFullScreenApps
            avoidsCalls = settings.avoidsCalls
            peerManager = manager
            self.scheduleStore = scheduleStore
            self.scheduler = scheduler
            self.proposalStore = proposalStore
            startupError = nil
        } catch {
            peerManager = nil
            scheduleStore = nil
            scheduler = nil
            proposalStore = nil
            startupError = error.localizedDescription
            fputs("CuppaJoe peer discovery failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func applySettings(displayName: String, teamPhrase: String) {
        guard let oldInstance = instance,
              let peerManager,
              let scheduleStore,
              let proposalStore else { return }

        do {
            let settings = try AppSettings(
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                teamPhrase: teamPhrase,
                avoidsFullScreenApps: avoidsFullScreenApps,
                avoidsCalls: avoidsCalls
            ).validated()
            guard settings.displayName != oldInstance.displayName
                    || settings.teamPhrase != oldInstance.teamPhrase else {
                settingsError = nil
                return
            }

            let updated = AppInstance(
                displayName: settings.displayName,
                requestedPort: oldInstance.requestedPort,
                teamPhrase: settings.teamPhrase,
                stateDirectory: oldInstance.stateDirectory,
                id: oldInstance.id
            )
            try settings.persist(for: updated)
            do {
                try peerManager.reconfigure(instance: updated)
            } catch {
                try? AppSettings(
                    displayName: oldInstance.displayName,
                    teamPhrase: oldInstance.teamPhrase,
                    avoidsFullScreenApps: avoidsFullScreenApps,
                    avoidsCalls: avoidsCalls
                ).persist(for: oldInstance)
                throw error
            }
            scheduleStore.updateInstance(updated)
            proposalStore.updateInstance(updated)
            instance = updated
            self.displayName = updated.displayName
            self.teamPhrase = updated.teamPhrase
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setInterruptionPreferences(avoidsFullScreenApps: Bool, avoidsCalls: Bool) {
        guard let instance else { return }
        let oldFullScreenValue = self.avoidsFullScreenApps
        let oldCallsValue = self.avoidsCalls
        self.avoidsFullScreenApps = avoidsFullScreenApps
        self.avoidsCalls = avoidsCalls
        do {
            try AppSettings(
                displayName: displayName,
                teamPhrase: teamPhrase,
                avoidsFullScreenApps: avoidsFullScreenApps,
                avoidsCalls: avoidsCalls
            ).persist(for: instance)
            settingsError = nil
        } catch {
            self.avoidsFullScreenApps = oldFullScreenValue
            self.avoidsCalls = oldCallsValue
            settingsError = error.localizedDescription
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?
    private var firingGate: FiringGate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlayController = OverlayController(resources: AppResources.shared)
        firingGate = FiringGate()
        AppModel.shared.scheduler?.start { [weak self] in
            self?.showAutomaticOverlayIfAllowed()
        }
        AppModel.shared.proposalStore?.start { [weak self] in
            self?.showAutomaticOverlayIfAllowed()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.scheduler?.stop()
        AppModel.shared.proposalStore?.stop()
        AppModel.shared.peerManager?.stop()
    }

    func previewAnimation() {
        overlayController?.show()
    }

    private func showAutomaticOverlayIfAllowed() {
        let appModel = AppModel.shared
        guard firingGate?.allowsFire(
            avoidsFullScreenApps: appModel.avoidsFullScreenApps,
            avoidsCalls: appModel.avoidsCalls
        ) == true else { return }
        overlayController?.show()
    }
}

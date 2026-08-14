import AppKit
import SwiftUI

@main
struct CuppaJoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("CuppaJoe", systemImage: "cup.and.saucer.fill") {
            Button("Preview Animation") {
                appDelegate.previewAnimation()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?
    private var peerDiscovery: PeerDiscovery?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            let instance = try AppInstance.load()
            peerDiscovery = PeerDiscovery(instance: instance)
            try peerDiscovery?.start()
            overlayController = OverlayController(resources: AppResources.shared)
        } catch {
            fputs("CuppaJoe failed to start: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        peerDiscovery?.stop()
    }

    func previewAnimation() {
        overlayController?.show()
    }
}

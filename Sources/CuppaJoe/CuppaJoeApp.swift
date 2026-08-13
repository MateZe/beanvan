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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let resources = AppResources.shared
        overlayController = OverlayController(resources: resources)
    }

    func previewAnimation() {
        overlayController?.show()
    }
}

import AppKit
import SwiftUI

@main
struct CuppaJoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("CuppaJoe", systemImage: "cup.and.saucer.fill") {
            MenuContent()
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let resources = AppResources.shared
        let overlayController = OverlayController(image: resources.images[0])
        self.overlayController = overlayController
        overlayController.show()
    }
}

private struct MenuContent: View {
    private let resources = AppResources.shared

    var body: some View {
        Text("CuppaJoe")
            .font(.headline)

        Text("\(resources.images.count) images and config.json loaded")
            .foregroundStyle(.secondary)

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

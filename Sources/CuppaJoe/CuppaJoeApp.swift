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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = AppResources.shared
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

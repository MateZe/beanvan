import AppKit
import Foundation

@MainActor
struct AppResources {
    static let shared = AppResources()

    let images: [NSImage]
    let configuration: Data

    private init() {
        images = [
            Self.loadImage(named: "coffee-1-removebg-preview"),
            Self.loadImage(named: "coffee-2-removebg-preview"),
            Self.loadImage(named: "coffee-3-removebg-preview"),
        ]
        configuration = Self.loadData(named: "config", extension: "json")
    }

    private static func loadImage(named name: String) -> NSImage {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            fatalError("Missing or unreadable bundled image: \(name).png")
        }

        return image
    }

    private static func loadData(named name: String, extension fileExtension: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            fatalError("Missing bundled resource: \(name).\(fileExtension)")
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            fatalError("Could not read bundled resource \(name).\(fileExtension): \(error)")
        }
    }
}

import AppKit
import Foundation

struct AnimationConfig: Decodable {
    struct Truck: Decodable {
        let size: CGFloat
        let cruiseSpeed: CGFloat
        let laneHeight: CGFloat
        let bobAmplitude: CGFloat
        let bobFrequency: Double
    }

    struct Banner: Decodable {
        let width: CGFloat
        let height: CGFloat
        let tetherLength: CGFloat
        let cornerRadius: CGFloat
        let swayAmplitude: CGFloat
        let swayFrequency: Double
        let color: String
    }

    struct Timing: Decodable {
        let enterDuration: TimeInterval
        let bannerUnfurlDuration: TimeInterval
        let tipDelay: TimeInterval
    }

    struct Bump: Decodable {
        let position: CGFloat
        let joltHeight: CGFloat
        let joltDuration: TimeInterval
        let rotationAngle: CGFloat
        let hangTime: TimeInterval
        let riseFraction: CGFloat
        let contactFraction: CGFloat
        let landingOvershootFraction: CGFloat
        let hangHeightLossFraction: CGFloat
        let hangRotationLossFraction: CGFloat
        let landingRotationOvershootFraction: CGFloat
    }

    struct Cup: Decodable {
        let size: CGFloat
        let flightDuration: TimeInterval
        let morphDuration: TimeInterval
        let slideDuration: TimeInterval
        let launchVelocityX: CGFloat
        let launchVelocityY: CGFloat
        let gravity: CGFloat
        let spinRate: CGFloat
    }

    struct Splash: Decodable {
        let duration: TimeInterval
        let radius: CGFloat
        let dropletCount: Int
    }

    struct Liquid: Decodable {
        let streamWidth: CGFloat
        let flowSpeed: CGFloat
        let pourDuration: TimeInterval
        let dropletCount: Int
        let opacity: CGFloat
        let color: String
    }

    struct Wobble: Decodable {
        let amplitude: CGFloat
        let frequency: Double
        let decay: Double
        let exitAcceleration: CGFloat
    }

    struct Global: Decodable {
        let durationScale: Double
    }

    let truck: Truck
    let banner: Banner
    let timing: Timing
    let bump: Bump
    let cup: Cup
    let splash: Splash
    let liquid: Liquid
    let wobble: Wobble
    let global: Global
}

enum CoffeeImage: String, CaseIterable {
    case truckUpright = "coffee-1-removebg-preview"
    case truckTipped = "coffee-2-removebg-preview"
    case cup = "coffee-3-removebg-preview"
}

struct ImageCache {
    private let images: [CoffeeImage: NSImage]

    init(bundle: Bundle) {
        images = Dictionary(uniqueKeysWithValues: CoffeeImage.allCases.map { asset in
            guard
                let url = bundle.url(forResource: asset.rawValue, withExtension: "png"),
                let image = NSImage(contentsOf: url)
            else {
                fatalError("Missing or unreadable bundled image: \(asset.rawValue).png")
            }

            return (asset, image)
        })
    }

    subscript(_ asset: CoffeeImage) -> NSImage {
        guard let image = images[asset] else {
            fatalError("Image was not loaded into the cache: \(asset.rawValue).png")
        }

        return image
    }
}

@MainActor
struct AppResources {
    static let shared = AppResources(bundle: .module)

    let animationConfig: AnimationConfig
    let images: ImageCache

    private init(bundle: Bundle) {
        animationConfig = Self.loadConfiguration(from: bundle)
        images = ImageCache(bundle: bundle)
    }

    private static func loadConfiguration(from bundle: Bundle) -> AnimationConfig {
        guard let url = bundle.url(forResource: "config", withExtension: "json") else {
            fatalError("Missing bundled resource: config.json")
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AnimationConfig.self, from: data)
        } catch {
            fatalError("Could not load bundled animation config: \(error)")
        }
    }
}

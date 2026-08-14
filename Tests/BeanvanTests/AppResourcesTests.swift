import Testing
@testable import Beanvan

@MainActor
struct AppResourcesTests {
    @Test func bundledResourcesLoad() {
        let resources = AppResources.shared

        #expect(resources.animationConfig.truck.size > 0)
        #expect(resources.images[.truckUpright].isValid)
        #expect(resources.images[.truckTipped].isValid)
        #expect(resources.images[.cup].isValid)
        #expect(resources.sounds[.softHonk].isFileURL)
        #expect(resources.sounds[.smallSplash].isFileURL)
    }
}

import AppKit
import Testing
@testable import Beanvan

@MainActor
struct SystemIntegrationTests {
    @Test func menuBarPresenterClicksNestedStatusBarButton() {
        let recorder = ButtonActionRecorder()
        let button = NSStatusBarButton()
        button.target = recorder
        button.action = #selector(ButtonActionRecorder.click)
        let container = NSView()
        container.addSubview(button)
        let window = NSWindow()
        window.contentView = container

        #expect(MenuBarExtraPresenter.show(in: [window]))
        #expect(recorder.clickCount == 1)
    }

    @Test func menuBarPresenterReturnsFalseWithoutStatusBarButton() {
        let window = NSWindow()
        window.contentView = NSView()

        #expect(!MenuBarExtraPresenter.show(in: [window]))
    }
}

private final class ButtonActionRecorder: NSObject {
    private(set) var clickCount = 0

    @objc func click() {
        clickCount += 1
    }
}

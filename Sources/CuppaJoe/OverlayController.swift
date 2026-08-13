import AppKit
import QuartzCore

@MainActor
final class OverlayController {
    private let image: NSImage
    private var window: NSWindow?

    init(image: NSImage) {
        self.image = image
    }

    func show() {
        guard let screen = NSScreen.main else { return }

        dismiss()

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = overlayView
        window.orderFrontRegardless()

        self.window = window
        overlayView.animate(image: image)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
private final class OverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func animate(image: NSImage) {
        guard
            let rootLayer = layer,
            let imageRepresentation = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let imageWidth: CGFloat = 250
        let aspectRatio = CGFloat(imageRepresentation.height) / CGFloat(imageRepresentation.width)
        let imageSize = CGSize(width: imageWidth, height: imageWidth * aspectRatio)
        let imageLayer = CALayer()
        imageLayer.bounds = CGRect(origin: .zero, size: imageSize)
        imageLayer.contents = imageRepresentation
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        let startX = -imageSize.width / 2
        let endX = bounds.width + imageSize.width / 2
        let y = bounds.midY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = CGPoint(x: endX, y: y)
        rootLayer.addSublayer(imageLayer)
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = startX
        animation.toValue = endX
        animation.duration = 3
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        imageLayer.add(animation, forKey: "slideAcrossScreen")
    }
}

import AppKit
import CoreText
import QuartzCore

@MainActor
final class OverlayController {
    private let resources: AppResources
    private var window: NSWindow?

    init(resources: AppResources) {
        self.resources = resources
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
        overlayView.animate(
            image: resources.images[.truckUpright],
            config: resources.animationConfig
        )
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
private final class OverlayView: NSView {
    private enum TruckArtwork {
        // Pixel crop used by the browser prototype for the upright truck artwork.
        static let crop = CGRect(x: 68, y: 105, width: 365, height: 280)
    }

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

    func animate(image: NSImage, config: AnimationConfig) {
        guard
            let rootLayer = layer,
            let imageRepresentation = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let croppedImage = imageRepresentation.cropping(to: TruckArtwork.crop)
        else { return }

        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let truckSize = CGSize(
            width: config.truck.size,
            height: config.truck.size * TruckArtwork.crop.height / TruckArtwork.crop.width
        )
        let laneCenter = bounds.height * (1 - config.truck.laneHeight / 100)
        let travelLayer = CALayer()
        let bobLayer = CALayer()
        let truckLayer = makeTruckLayer(
            image: croppedImage,
            size: truckSize,
            contentsScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        travelLayer.position = CGPoint(x: -truckSize.width, y: laneCenter)
        bobLayer.position = .zero
        truckLayer.position = CGPoint(x: truckSize.width / 2, y: 0)
        rootLayer.addSublayer(travelLayer)
        travelLayer.addSublayer(bobLayer)
        addBanner(to: bobLayer, config: config)
        bobLayer.addSublayer(truckLayer)
        CATransaction.commit()

        animateHorizontalTravel(
            layer: travelLayer,
            viewportWidth: bounds.width,
            truckWidth: truckSize.width,
            config: config
        )
        animateBob(layer: bobLayer, config: config)
    }

    private func makeTruckLayer(
        image: CGImage,
        size: CGSize,
        contentsScale: CGFloat
    ) -> CALayer {
        let truckLayer = CALayer()
        truckLayer.bounds = CGRect(origin: .zero, size: size)
        truckLayer.contents = image
        truckLayer.contentsGravity = .resizeAspect
        truckLayer.contentsScale = contentsScale
        return truckLayer
    }

    private func addBanner(to truckAssembly: CALayer, config: AnimationConfig) {
        let banner = config.banner
        let tetherLayer = CALayer()
        let bannerPivotLayer = CALayer()
        let connectorLayer = CAShapeLayer()
        connectorLayer.path = makeConnectorPath(
            tetherLength: banner.tetherLength,
            verticalOffset: 0
        )
        connectorLayer.strokeColor = NSColor.labelColor.withAlphaComponent(0.78).cgColor
        connectorLayer.fillColor = nil
        connectorLayer.lineWidth = 3
        connectorLayer.lineCap = .round

        let bannerLayer = CALayer()
        bannerLayer.bounds = CGRect(x: 0, y: 0, width: banner.width, height: banner.height)
        bannerLayer.position = .zero
        bannerLayer.anchorPoint = CGPoint(x: 1, y: 0.5)
        bannerLayer.backgroundColor = NSColor(hex: banner.color).cgColor
        bannerLayer.cornerRadius = min(banner.cornerRadius, banner.width / 2, banner.height / 2)
        bannerLayer.shadowColor = NSColor.black.cgColor
        bannerLayer.shadowOpacity = 0.22
        bannerLayer.shadowRadius = 5
        bannerLayer.shadowOffset = CGSize(width: 0, height: -2)

        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let textLayer = makeCenteredTextLayer(
            text: "☕ 10:30",
            size: bannerLayer.bounds.size,
            contentsScale: contentsScale,
            font: NSFont.systemFont(ofSize: banner.height / 3, weight: .bold)
        )

        tetherLayer.addSublayer(connectorLayer)
        bannerPivotLayer.position = CGPoint(x: -banner.tetherLength, y: 0)
        tetherLayer.addSublayer(bannerPivotLayer)
        bannerPivotLayer.addSublayer(bannerLayer)
        bannerLayer.addSublayer(textLayer)
        truckAssembly.addSublayer(tetherLayer)

        animateBannerUnfurl(layer: bannerLayer, config: config)
        animateBannerSway(
            pivotLayer: bannerPivotLayer,
            bannerLayer: bannerLayer,
            connectorLayer: connectorLayer,
            config: config
        )
    }

    private func makeCenteredTextLayer(
        text: String,
        size: CGSize,
        contentsScale: CGFloat,
        font: NSFont
    ) -> CALayer {
        let pixelWidth = Int(ceil(size.width * contentsScale))
        let pixelHeight = Int(ceil(size.height * contentsScale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create the banner text drawing context")
        }

        context.scaleBy(x: contentsScale, y: contentsScale)
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: (size.width - textWidth) / 2,
            y: (size.height - ascent - descent) / 2 + descent
        )
        CTLineDraw(line, context)

        let textLayer = CALayer()
        textLayer.frame = CGRect(origin: .zero, size: size)
        textLayer.contents = context.makeImage()
        textLayer.contentsScale = contentsScale
        return textLayer
    }

    private func makeConnectorPath(tetherLength: CGFloat, verticalOffset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: -tetherLength, y: verticalOffset))
        return path
    }

    private func animateHorizontalTravel(
        layer: CALayer,
        viewportWidth: CGFloat,
        truckWidth: CGFloat,
        config: AnimationConfig
    ) {
        let startX = -truckWidth
        let entryDuration = config.timing.enterDuration
        let entryEndX = startX + config.truck.cruiseSpeed * entryDuration
        let endX = viewportWidth + truckWidth
        let cruiseDuration = max(0, (endX - entryEndX) / config.truck.cruiseSpeed)
        let totalDuration = entryDuration + cruiseDuration
        let entryFraction = entryDuration / totalDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position.x = endX
        CATransaction.commit()

        let travel = CAKeyframeAnimation(keyPath: "position.x")
        travel.values = [startX, entryEndX, endX]
        travel.keyTimes = [0, NSNumber(value: entryFraction), 1]
        travel.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 2 / 3),
            CAMediaTimingFunction(name: .linear),
        ]
        travel.duration = totalDuration * config.global.durationScale
        layer.add(travel, forKey: "horizontalTravel")
    }

    private func animateBob(layer: CALayer, config: AnimationConfig) {
        guard config.truck.bobAmplitude != 0, config.truck.bobFrequency > 0 else { return }

        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0, -config.truck.bobAmplitude, 0, config.truck.bobAmplitude, 0]
        bob.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bob.timingFunctions = sineQuarterTimingFunctions
        bob.duration = config.global.durationScale / config.truck.bobFrequency
        bob.repeatCount = .infinity
        layer.add(bob, forKey: "verticalBob")
    }

    private func animateBannerUnfurl(layer: CALayer, config: AnimationConfig) {
        let unfurl = CABasicAnimation(keyPath: "transform.scale.x")
        unfurl.fromValue = 0
        unfurl.toValue = 1
        unfurl.duration = config.timing.bannerUnfurlDuration * config.global.durationScale
        unfurl.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(unfurl, forKey: "bannerUnfurl")
    }

    private func animateBannerSway(
        pivotLayer: CALayer,
        bannerLayer: CALayer,
        connectorLayer: CAShapeLayer,
        config: AnimationConfig
    ) {
        guard config.banner.swayAmplitude != 0, config.banner.swayFrequency > 0 else { return }

        let amplitude = config.banner.swayAmplitude
        let duration = config.global.durationScale / config.banner.swayFrequency
        let keyTimes: [NSNumber] = [0, 0.25, 0.5, 0.75, 1]

        let verticalSway = CAKeyframeAnimation(keyPath: "transform.translation.y")
        verticalSway.values = [0, -amplitude, 0, amplitude, 0]
        verticalSway.keyTimes = keyTimes
        verticalSway.timingFunctions = sineQuarterTimingFunctions
        verticalSway.duration = duration
        verticalSway.repeatCount = .infinity
        pivotLayer.add(verticalSway, forKey: "bannerVerticalSway")

        let connectorSway = CAKeyframeAnimation(keyPath: "path")
        connectorSway.values = [
            makeConnectorPath(tetherLength: config.banner.tetherLength, verticalOffset: 0),
            makeConnectorPath(tetherLength: config.banner.tetherLength, verticalOffset: -amplitude),
            makeConnectorPath(tetherLength: config.banner.tetherLength, verticalOffset: 0),
            makeConnectorPath(tetherLength: config.banner.tetherLength, verticalOffset: amplitude),
            makeConnectorPath(tetherLength: config.banner.tetherLength, verticalOffset: 0),
        ]
        connectorSway.keyTimes = keyTimes
        connectorSway.timingFunctions = sineQuarterTimingFunctions
        connectorSway.duration = duration
        connectorSway.repeatCount = .infinity
        connectorLayer.add(connectorSway, forKey: "connectorSway")

        let rotationAmplitude = amplitude / config.banner.width
        let rotationSway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotationSway.values = [0, rotationAmplitude, 0, -rotationAmplitude, 0]
        rotationSway.keyTimes = keyTimes
        rotationSway.timingFunctions = sineQuarterTimingFunctions
        rotationSway.duration = duration
        rotationSway.repeatCount = .infinity
        bannerLayer.add(rotationSway, forKey: "bannerRotationSway")
    }

    private var sineQuarterTimingFunctions: [CAMediaTimingFunction] {
        let rise = CAMediaTimingFunction(
            controlPoints: 1 / 3,
            Float.pi / 6,
            2 / 3,
            1
        )
        let fall = CAMediaTimingFunction(
            controlPoints: 1 / 3,
            0,
            2 / 3,
            1 - Float.pi / 6
        )

        return [
            rise,
            fall,
            rise,
            fall,
        ]
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            fatalError("Invalid RGB color in animation config: \(hex)")
        }

        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

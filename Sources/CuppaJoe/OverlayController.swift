import AppKit
import CoreText
import QuartzCore

@MainActor
final class OverlayController {
    private let resources: AppResources
    private var window: NSWindow?
    private var escapeKeyMonitor: Any?

    init(resources: AppResources) {
        self.resources = resources
    }

    func show() {
        guard let screen = NSScreen.main else { return }

        dismiss()

        let window = OverlayWindow(
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

        let overlayView = OverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            dismissHandler: { [weak self] in
                self?.dismiss()
            }
        )
        window.contentView = overlayView
        self.window = window
        installEscapeKeyMonitor()
        window.orderFrontRegardless()
        overlayView.animate(
            images: resources.images,
            config: resources.animationConfig
        )
    }

    func dismiss() {
        removeEscapeKeyMonitor()
        (window?.contentView as? OverlayView)?.stopAnimation()
        window?.orderOut(nil)
        window = nil
    }

    private func installEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }
}

@MainActor
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverlayView: NSView {
    private let dismissHandler: () -> Void
    private var spillAnimator: SpillAnimator?
    private weak var truckHitLayer: CALayer?
    private weak var bannerHitLayer: CALayer?
    private weak var cupHitLayer: CALayer?
    private var interactionDisplayLink: CADisplayLink?
    private var completionTimer: Timer?

    private enum TruckArtwork {
        static let uprightCrop = CGRect(x: 68, y: 105, width: 365, height: 280)
        static let tippedCrop = CGRect(x: 63, y: 105, width: 372, height: 290)

        // These two regions retain the truck bed and cab while removing the
        // tipped cup, which becomes its own animated layer at this beat.
        static let tippedVisibleRegions: [[CGPoint]] = [
            [CGPoint(x: 63, y: 249), CGPoint(x: 255, y: 274), CGPoint(x: 435, y: 265), CGPoint(x: 435, y: 395), CGPoint(x: 63, y: 395)],
            [CGPoint(x: 280, y: 135), CGPoint(x: 435, y: 140), CGPoint(x: 435, y: 395), CGPoint(x: 245, y: 395), CGPoint(x: 258, y: 270)],
        ]
    }

    private enum CupArtwork {
        static let crop = CGRect(x: 108, y: 91, width: 315, height: 333)
        static let embeddedCrop = CGRect(x: 105, y: 122, width: 139, height: 180)
    }

    init(frame frameRect: NSRect, dismissHandler: @escaping () -> Void) {
        self.dismissHandler = dismissHandler
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        containsVisibleContent(at: point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dismissHandler()
    }

    override func rightMouseDown(with event: NSEvent) {
        dismissHandler()
    }

    override func otherMouseDown(with event: NSEvent) {
        dismissHandler()
    }

    func animate(images: ImageCache, config: AnimationConfig) {
        guard
            let rootLayer = layer,
            let uprightImage = images[.truckUpright].cgImage(forProposedRect: nil, context: nil, hints: nil),
            let tippedImage = images[.truckTipped].cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cupImage = images[.cup].cgImage(forProposedRect: nil, context: nil, hints: nil),
            let croppedUprightImage = uprightImage.cropping(to: TruckArtwork.uprightCrop),
            let croppedTippedImage = tippedImage.cropping(to: TruckArtwork.tippedCrop),
            let croppedCupImage = cupImage.cropping(to: CupArtwork.crop),
            let croppedEmbeddedCupImage = uprightImage.cropping(to: CupArtwork.embeddedCrop)
        else { return }

        stopAnimation()
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let truckSize = CGSize(
            width: config.truck.size,
            height: config.truck.size * TruckArtwork.uprightCrop.height / TruckArtwork.uprightCrop.width
        )
        let laneCenter = bounds.height * (1 - config.truck.laneHeight / 100)
        let travelLayer = CALayer()
        let bobLayer = CALayer()
        let bumpLayer = CALayer()
        let tippedSize = CGSize(
            width: config.truck.size,
            height: config.truck.size * TruckArtwork.tippedCrop.height / TruckArtwork.tippedCrop.width
        )
        let truckLayers = makeTruckLayers(
            uprightImage: croppedUprightImage,
            tippedImage: croppedTippedImage,
            uprightSize: truckSize,
            tippedSize: tippedSize,
            contentsScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
        let truckLayer = truckLayers.container
        let bumpTime = bumpTimeForViewport(
            viewportWidth: bounds.width,
            truckWidth: truckSize.width,
            config: config
        )
        let exitTime = truckExitTimeForViewport(
            viewportWidth: bounds.width,
            truckWidth: truckSize.width,
            bumpTime: bumpTime,
            config: config
        )
        let timelineStartTime = rootLayer.convertTime(CACurrentMediaTime(), from: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        travelLayer.position = CGPoint(x: -truckSize.width, y: laneCenter)
        bobLayer.position = .zero
        bumpLayer.position = .zero
        truckLayer.position = CGPoint(x: truckSize.width / 2, y: 0)
        rootLayer.addSublayer(travelLayer)
        travelLayer.addSublayer(bobLayer)
        bobLayer.addSublayer(bumpLayer)
        addBanner(
            to: bumpLayer,
            timelineStartTime: timelineStartTime,
            bumpTime: bumpTime,
            exitTime: exitTime,
            config: config
        )
        bumpLayer.addSublayer(truckLayer)
        CATransaction.commit()

        truckHitLayer = truckLayer

        animateHorizontalTravel(
            layer: travelLayer,
            viewportWidth: bounds.width,
            truckWidth: truckSize.width,
            bumpTime: bumpTime,
            exitTime: exitTime,
            timelineStartTime: timelineStartTime,
            config: config
        )
        animateBob(layer: bobLayer, config: config)
        animateBump(
            assemblyLayer: bumpLayer,
            truckLayer: truckLayer,
            beginTime: bumpTime,
            timelineStartTime: timelineStartTime,
            config: config
        )
        animateRecoveryWobble(
            layer: truckLayer,
            bumpTime: bumpTime,
            exitTime: exitTime,
            timelineStartTime: timelineStartTime,
            config: config
        )
        animateTipAndCup(
            rootLayer: rootLayer,
            uprightTruckLayer: truckLayers.upright,
            tippedTruckLayer: truckLayers.tipped,
            cupImage: croppedCupImage,
            embeddedCupImage: croppedEmbeddedCupImage,
            truckSize: truckSize,
            laneCenter: laneCenter,
            bumpTime: bumpTime,
            exitTime: exitTime,
            timelineStartTime: timelineStartTime,
            config: config
        )
        startInteractionTracking()
        scheduleCompletion(after: exitTime * config.global.durationScale)
    }

    func stopAnimation() {
        completionTimer?.invalidate()
        completionTimer = nil
        interactionDisplayLink?.invalidate()
        interactionDisplayLink = nil
        window?.ignoresMouseEvents = true
        spillAnimator?.stop()
        spillAnimator = nil
        truckHitLayer = nil
        bannerHitLayer = nil
        cupHitLayer = nil
    }

    private func makeTruckLayers(
        uprightImage: CGImage,
        tippedImage: CGImage,
        uprightSize: CGSize,
        tippedSize: CGSize,
        contentsScale: CGFloat
    ) -> (container: CALayer, upright: CALayer, tipped: CALayer) {
        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: uprightSize)

        let upright = makeArtworkLayer(
            image: uprightImage,
            size: uprightSize,
            contentsScale: contentsScale
        )
        upright.position = CGPoint(x: uprightSize.width / 2, y: uprightSize.height / 2)

        let tipped = makeArtworkLayer(
            image: tippedImage,
            size: tippedSize,
            contentsScale: contentsScale
        )
        tipped.position = CGPoint(x: uprightSize.width / 2, y: uprightSize.height / 2)
        tipped.mask = makeTippedTruckMask(size: tippedSize)
        tipped.opacity = 0

        container.addSublayer(upright)
        container.addSublayer(tipped)
        return (container, upright, tipped)
    }

    private func makeArtworkLayer(
        image: CGImage,
        size: CGSize,
        contentsScale: CGFloat
    ) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = contentsScale
        return layer
    }

    private func addBanner(
        to truckAssembly: CALayer,
        timelineStartTime: CFTimeInterval,
        bumpTime: TimeInterval,
        exitTime: TimeInterval,
        config: AnimationConfig
    ) {
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
        bannerHitLayer = bannerLayer

        animateBannerUnfurl(layer: bannerLayer, config: config)
        animateBannerSway(
            pivotLayer: bannerPivotLayer,
            bannerLayer: bannerLayer,
            connectorLayer: connectorLayer,
            timelineStartTime: timelineStartTime,
            bumpTime: bumpTime,
            exitTime: exitTime,
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

    private func bumpTimeForViewport(
        viewportWidth: CGFloat,
        truckWidth: CGFloat,
        config: AnimationConfig
    ) -> TimeInterval {
        let targetLeft = viewportWidth * config.bump.position / 100 - truckWidth / 2
        let entryEndLeft = -truckWidth + config.truck.cruiseSpeed * config.timing.enterDuration

        if targetLeft >= entryEndLeft {
            return (targetLeft + truckWidth) / config.truck.cruiseSpeed
        }

        var lowerTime: TimeInterval = 0
        var upperTime = config.timing.enterDuration
        for _ in 0..<16 {
            let middleTime = (lowerTime + upperTime) / 2
            if baseTruckPosition(at: middleTime, truckWidth: truckWidth, config: config) < targetLeft {
                lowerTime = middleTime
            } else {
                upperTime = middleTime
            }
        }
        return (lowerTime + upperTime) / 2
    }

    private func baseTruckPosition(
        at elapsed: TimeInterval,
        truckWidth: CGFloat,
        config: AnimationConfig
    ) -> CGFloat {
        let enterDuration = config.timing.enterDuration
        guard elapsed < enterDuration else {
            return -truckWidth + config.truck.cruiseSpeed * elapsed
        }

        let progress = max(0, min(1, elapsed / enterDuration))
        let easedProgress = -(progress * progress * progress) + 2 * progress * progress
        return -truckWidth + config.truck.cruiseSpeed * enterDuration * easedProgress
    }

    private func truckPosition(
        at elapsed: TimeInterval,
        truckWidth: CGFloat,
        bumpTime: TimeInterval,
        config: AnimationConfig
    ) -> CGFloat {
        let recoveryAge = max(0, elapsed - bumpTime - config.wobble.recoveryDelay)
        return baseTruckPosition(at: elapsed, truckWidth: truckWidth, config: config)
            + 0.5 * config.wobble.exitAcceleration * recoveryAge * recoveryAge
    }

    private func truckExitTimeForViewport(
        viewportWidth: CGFloat,
        truckWidth: CGFloat,
        bumpTime: TimeInterval,
        config: AnimationConfig
    ) -> TimeInterval {
        let targetLeft = viewportWidth + truckWidth
        let recoveryTime = bumpTime + config.wobble.recoveryDelay
        let unacceleratedExitTime = (targetLeft + truckWidth) / config.truck.cruiseSpeed
        guard unacceleratedExitTime > recoveryTime,
              config.wobble.exitAcceleration > 0 else {
            return unacceleratedExitTime
        }

        let recoveryPosition = baseTruckPosition(
            at: recoveryTime,
            truckWidth: truckWidth,
            config: config
        )
        let remainingDistance = max(0, targetLeft - recoveryPosition)
        let speed = config.truck.cruiseSpeed
        let acceleration = config.wobble.exitAcceleration
        let acceleratedDuration = (
            -speed + sqrt(speed * speed + 2 * acceleration * remainingDistance)
        ) / acceleration
        return recoveryTime + acceleratedDuration
    }

    private func animateBump(
        assemblyLayer: CALayer,
        truckLayer: CALayer,
        beginTime: TimeInterval,
        timelineStartTime: CFTimeInterval,
        config: AnimationConfig
    ) {
        let bump = config.bump
        let riseDuration = bump.joltDuration * bump.riseFraction
        let fallDuration = bump.joltDuration * (1 - bump.riseFraction)
        let contactTime = riseDuration + bump.hangTime + fallDuration * bump.contactFraction
        let totalDuration = bump.joltDuration + bump.hangTime
        guard totalDuration > 0 else { return }

        var keyTimes: [NSNumber] = [0, NSNumber(value: riseDuration / totalDuration)]
        var verticalValues: [CGFloat] = [0, bump.joltHeight]
        var rotationValues: [CGFloat] = [0, -bump.rotationAngle * .pi / 180]
        if bump.hangTime > 0 {
            keyTimes.append(NSNumber(value: (riseDuration + bump.hangTime) / totalDuration))
            verticalValues.append(bump.joltHeight * (1 - bump.hangHeightLossFraction))
            rotationValues.append(-bump.rotationAngle * .pi / 180 * (1 - bump.hangRotationLossFraction))
        }
        keyTimes.append(contentsOf: [NSNumber(value: contactTime / totalDuration), 1])
        verticalValues.append(contentsOf: [-bump.joltHeight * bump.landingOvershootFraction, 0])

        let angle = bump.rotationAngle * .pi / 180
        rotationValues.append(contentsOf: [angle * bump.landingRotationOvershootFraction, 0])
        let animationBeginTime = timelineStartTime
            + beginTime * config.global.durationScale
        let scaledDuration = totalDuration * config.global.durationScale

        let verticalJolt = CAKeyframeAnimation(keyPath: "transform.translation.y")
        verticalJolt.values = verticalValues
        verticalJolt.keyTimes = keyTimes
        verticalJolt.timingFunctions = bumpTimingFunctions(hasHangTime: bump.hangTime > 0)
        verticalJolt.beginTime = animationBeginTime
        verticalJolt.duration = scaledDuration
        assemblyLayer.add(verticalJolt, forKey: "bumpJolt")

        let noseDown = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        noseDown.values = rotationValues
        noseDown.keyTimes = keyTimes
        noseDown.timingFunctions = bumpTimingFunctions(hasHangTime: bump.hangTime > 0)
        noseDown.beginTime = animationBeginTime
        noseDown.duration = scaledDuration
        truckLayer.add(noseDown, forKey: "bumpRotation")
    }

    private func bumpTimingFunctions(hasHangTime: Bool) -> [CAMediaTimingFunction] {
        var timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1),
        ]
        if hasHangTime {
            timingFunctions.append(CAMediaTimingFunction(name: .linear))
        }
        timingFunctions.append(contentsOf: [
            CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 0),
            CAMediaTimingFunction(name: .easeOut),
        ])
        return timingFunctions
    }

    private func animateTipAndCup(
        rootLayer: CALayer,
        uprightTruckLayer: CALayer,
        tippedTruckLayer: CALayer,
        cupImage: CGImage,
        embeddedCupImage: CGImage,
        truckSize: CGSize,
        laneCenter: CGFloat,
        bumpTime: TimeInterval,
        exitTime: TimeInterval,
        timelineStartTime: CFTimeInterval,
        config: AnimationConfig
    ) {
        let launchTime = bumpTime + config.timing.tipDelay
        let eventAge = config.timing.tipDelay
        let bumpPose = bumpPose(at: eventAge, config: config)
        let bobOffset = -sin(launchTime * config.truck.bobFrequency * 2 * .pi)
            * config.truck.bobAmplitude
        let truckCenter = CGPoint(
            x: truckPosition(
                at: launchTime,
                truckWidth: truckSize.width,
                bumpTime: bumpTime,
                config: config
            )
                + truckSize.width / 2,
            y: laneCenter + bobOffset + bumpPose.verticalOffset
        )
        let embeddedCupCenter = embeddedCupCenter(
            truckCenter: truckCenter,
            truckSize: truckSize,
            truckRotation: bumpPose.rotation
        )
        let contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let launchDelay = launchTime * config.global.durationScale
        let animationBeginTime = timelineStartTime + launchDelay

        animateTruckTip(
            uprightLayer: uprightTruckLayer,
            tippedLayer: tippedTruckLayer,
            timelineStartTime: timelineStartTime,
            launchDelay: launchDelay
        )

        addBallisticCup(
            to: rootLayer,
            image: cupImage,
            embeddedImage: embeddedCupImage,
            startPosition: embeddedCupCenter,
            startRotation: bumpPose.rotation,
            embeddedWidth: CupArtwork.embeddedCrop.width * truckSize.width / TruckArtwork.uprightCrop.width,
            animationBeginTime: animationBeginTime,
            launchTime: launchTime,
            animationDuration: exitTime,
            contentsScale: contentsScale,
            config: config
        )
    }

    private func animateTruckTip(
        uprightLayer: CALayer,
        tippedLayer: CALayer,
        timelineStartTime: CFTimeInterval,
        launchDelay: CFTimeInterval
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        uprightLayer.opacity = 0
        tippedLayer.opacity = 1
        CATransaction.commit()

        // Hold both presentation values from launch until the exact tip frame.
        // This avoids relying on backwards fill for a delayed animation, which can
        // expose the final model values before the animation begins.
        let hideUpright = CAKeyframeAnimation(keyPath: "opacity")
        hideUpright.values = [1, 0]
        hideUpright.keyTimes = [0, 1]
        hideUpright.calculationMode = .discrete
        hideUpright.beginTime = timelineStartTime
        hideUpright.duration = launchDelay
        uprightLayer.add(hideUpright, forKey: "hideEmbeddedCup")

        let showTipped = CAKeyframeAnimation(keyPath: "opacity")
        showTipped.values = [0, 1]
        showTipped.keyTimes = [0, 1]
        showTipped.calculationMode = .discrete
        showTipped.beginTime = timelineStartTime
        showTipped.duration = launchDelay
        tippedLayer.add(showTipped, forKey: "showTippedTruck")
    }

    private func bumpPose(
        at eventAge: TimeInterval,
        config: AnimationConfig
    ) -> (verticalOffset: CGFloat, rotation: CGFloat) {
        let bump = config.bump
        let riseDuration = bump.joltDuration * bump.riseFraction
        let fallDuration = bump.joltDuration * (1 - bump.riseFraction)
        let angle = bump.rotationAngle * .pi / 180

        if eventAge < riseDuration {
            let progress = max(0, eventAge / riseDuration)
            let snap = 1 - pow(1 - progress, 4)
            return (bump.joltHeight * snap, -angle * snap)
        }

        if eventAge < riseDuration + bump.hangTime {
            let progress = bump.hangTime == 0 ? 1 : (eventAge - riseDuration) / bump.hangTime
            return (
                bump.joltHeight * (1 - bump.hangHeightLossFraction * progress),
                -angle * (1 - bump.hangRotationLossFraction * progress)
            )
        }

        let fallAge = eventAge - riseDuration - bump.hangTime
        guard fallAge < fallDuration else { return (0, 0) }
        let progress = fallAge / fallDuration
        let contactPoint = bump.contactFraction
        if progress < contactPoint {
            let fallProgress = pow(progress / contactPoint, 3)
            let heightAtFall = bump.joltHeight * (1 - bump.hangHeightLossFraction)
            let rotationAtFall = angle * (1 - bump.hangRotationLossFraction)
            return (
                heightAtFall - (heightAtFall + bump.joltHeight * bump.landingOvershootFraction) * fallProgress,
                -rotationAtFall
                    + (rotationAtFall + angle * bump.landingRotationOvershootFraction) * fallProgress
            )
        }

        let settleProgress = (progress - contactPoint) / (1 - contactPoint)
        return (
            -bump.joltHeight * bump.landingOvershootFraction * (1 - settleProgress),
            angle * bump.landingRotationOvershootFraction * (1 - settleProgress)
        )
    }

    private func embeddedCupCenter(
        truckCenter: CGPoint,
        truckSize: CGSize,
        truckRotation: CGFloat
    ) -> CGPoint {
        let scale = truckSize.width / TruckArtwork.uprightCrop.width
        let localX = -truckSize.width / 2
            + (CupArtwork.embeddedCrop.midX - TruckArtwork.uprightCrop.minX) * scale
        let localYFromTop = -truckSize.height / 2
            + (CupArtwork.embeddedCrop.midY - TruckArtwork.uprightCrop.minY) * scale
        let localY = -localYFromTop

        return CGPoint(
            x: truckCenter.x + localX * cos(truckRotation) - localY * sin(truckRotation),
            y: truckCenter.y + localX * sin(truckRotation) + localY * cos(truckRotation)
        )
    }

    private func addBallisticCup(
        to rootLayer: CALayer,
        image: CGImage,
        embeddedImage: CGImage,
        startPosition: CGPoint,
        startRotation: CGFloat,
        embeddedWidth: CGFloat,
        animationBeginTime: CFTimeInterval,
        launchTime: TimeInterval,
        animationDuration: TimeInterval,
        contentsScale: CGFloat,
        config: AnimationConfig
    ) {
        let cupSize = CGSize(
            width: config.cup.size,
            height: config.cup.size * CupArtwork.crop.height / CupArtwork.crop.width
        )
        let motion = CupMotion(
            startPosition: startPosition,
            startRotation: startRotation,
            initialScale: embeddedWidth / config.cup.size,
            cupSize: cupSize,
            config: config
        )
        let totalDuration = motion.totalDuration
        let refreshRate = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        let sampleCount = max(2, Int(ceil(totalDuration * Double(refreshRate))))
        let poses = (0...sampleCount).map { sample -> CupMotion.Pose in
            let time = totalDuration * Double(sample) / Double(sampleCount)
            return motion.pose(at: time)
        }
        guard let finalPose = poses.last else { return }

        let cupLayer = CALayer()
        cupLayer.bounds = CGRect(origin: .zero, size: cupSize)
        cupLayer.position = finalPose.position
        cupLayer.opacity = 0

        let embeddedArtwork = makeArtworkLayer(
            image: embeddedImage,
            size: cupSize,
            contentsScale: contentsScale
        )
        embeddedArtwork.position = CGPoint(x: cupSize.width / 2, y: cupSize.height / 2)
        let splashArtwork = makeArtworkLayer(
            image: image,
            size: cupSize,
            contentsScale: contentsScale
        )
        splashArtwork.position = CGPoint(x: cupSize.width / 2, y: cupSize.height / 2)
        splashArtwork.opacity = 0
        cupLayer.addSublayer(embeddedArtwork)
        cupLayer.addSublayer(splashArtwork)
        rootLayer.addSublayer(cupLayer)
        cupHitLayer = cupLayer

        let scaledTotalDuration = totalDuration * config.global.durationScale

        let trajectory = CAKeyframeAnimation(keyPath: "position")
        trajectory.values = poses.map(\.position)
        trajectory.duration = scaledTotalDuration
        trajectory.beginTime = animationBeginTime
        trajectory.calculationMode = .linear
        cupLayer.add(trajectory, forKey: "ballisticTrajectory")

        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = poses.map(\.rotation)
        spin.duration = scaledTotalDuration
        spin.beginTime = animationBeginTime
        spin.calculationMode = .linear
        cupLayer.add(spin, forKey: "cupSpin")

        let horizontalScale = CAKeyframeAnimation(keyPath: "transform.scale.x")
        horizontalScale.values = poses.map(\.widthScale)
        horizontalScale.duration = scaledTotalDuration
        horizontalScale.beginTime = animationBeginTime
        horizontalScale.calculationMode = .linear
        cupLayer.add(horizontalScale, forKey: "cupHorizontalScale")

        let verticalScale = CAKeyframeAnimation(keyPath: "transform.scale.y")
        verticalScale.values = poses.map(\.heightScale)
        verticalScale.duration = scaledTotalDuration
        verticalScale.beginTime = animationBeginTime
        verticalScale.calculationMode = .linear
        cupLayer.add(verticalScale, forKey: "cupVerticalScale")

        let scaledMorphDuration = config.cup.morphDuration * config.global.durationScale
        animateArtworkCrossfade(
            from: embeddedArtwork,
            to: splashArtwork,
            beginTime: animationBeginTime,
            duration: scaledMorphDuration
        )

        let visibility = CABasicAnimation(keyPath: "opacity")
        visibility.fromValue = 1
        visibility.toValue = 1
        visibility.duration = scaledTotalDuration
        visibility.beginTime = animationBeginTime
        cupLayer.add(visibility, forKey: "cupVisibilityThroughSlide")

        spillAnimator = SpillAnimator(
            view: self,
            rootLayer: rootLayer,
            below: cupLayer,
            motion: motion,
            launchBeginTime: animationBeginTime,
            launchTime: launchTime,
            animationDuration: animationDuration,
            contentsScale: contentsScale,
            config: config
        )
        spillAnimator?.start()
    }

    private func animateArtworkCrossfade(
        from sourceLayer: CALayer,
        to destinationLayer: CALayer,
        beginTime: CFTimeInterval,
        duration: CFTimeInterval
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceLayer.opacity = 0
        destinationLayer.opacity = 1
        CATransaction.commit()

        let timingFunction = CAMediaTimingFunction(controlPoints: 0.165, 0.84, 0.44, 1)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.beginTime = beginTime
        fadeOut.duration = duration
        fadeOut.fillMode = .backwards
        fadeOut.timingFunction = timingFunction
        sourceLayer.add(fadeOut, forKey: "fadeEmbeddedArtwork")

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.beginTime = beginTime
        fadeIn.duration = duration
        fadeIn.fillMode = .backwards
        fadeIn.timingFunction = timingFunction
        destinationLayer.add(fadeIn, forKey: "fadeSplashArtwork")
    }

    private func makeTippedTruckMask(size: CGSize) -> CAShapeLayer {
        let scale = size.width / TruckArtwork.tippedCrop.width
        let path = CGMutablePath()

        for region in TruckArtwork.tippedVisibleRegions {
            guard let firstPoint = region.first else { continue }
            let convertedFirstPoint = CGPoint(
                x: (firstPoint.x - TruckArtwork.tippedCrop.minX) * scale,
                y: size.height - (firstPoint.y - TruckArtwork.tippedCrop.minY) * scale
            )
            path.move(to: convertedFirstPoint)
            for point in region.dropFirst() {
                path.addLine(to: CGPoint(
                    x: (point.x - TruckArtwork.tippedCrop.minX) * scale,
                    y: size.height - (point.y - TruckArtwork.tippedCrop.minY) * scale
                ))
            }
            path.closeSubpath()
        }

        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.path = path
        mask.fillColor = NSColor.white.cgColor
        return mask
    }

    private func animateHorizontalTravel(
        layer: CALayer,
        viewportWidth: CGFloat,
        truckWidth: CGFloat,
        bumpTime: TimeInterval,
        exitTime: TimeInterval,
        timelineStartTime: CFTimeInterval,
        config: AnimationConfig
    ) {
        let refreshRate = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        let sampleCount = max(2, Int(ceil(exitTime * Double(refreshRate))))
        let positions = (0...sampleCount).map { sample -> CGFloat in
            let elapsed = exitTime * Double(sample) / Double(sampleCount)
            return truckPosition(
                at: elapsed,
                truckWidth: truckWidth,
                bumpTime: bumpTime,
                config: config
            )
        }
        guard let endX = positions.last else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position.x = endX
        CATransaction.commit()

        let travel = CAKeyframeAnimation(keyPath: "position.x")
        travel.values = positions
        travel.calculationMode = .linear
        travel.beginTime = timelineStartTime
        travel.duration = exitTime * config.global.durationScale
        layer.add(travel, forKey: "horizontalTravel")
    }

    private func animateRecoveryWobble(
        layer: CALayer,
        bumpTime: TimeInterval,
        exitTime: TimeInterval,
        timelineStartTime: CFTimeInterval,
        config: AnimationConfig
    ) {
        guard config.wobble.amplitude != 0,
              config.wobble.frequency > 0 else { return }

        let recoveryTime = bumpTime + config.wobble.recoveryDelay
        let duration = max(0, exitTime - recoveryTime)
        guard duration > 0 else { return }

        let refreshRate = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        let sampleCount = max(2, Int(ceil(duration * Double(refreshRate))))
        let rotations = (0...sampleCount).map { sample -> CGFloat in
            let elapsed = duration * Double(sample) / Double(sampleCount)
            let envelope = config.wobble.amplitude
                * CGFloat(exp(-config.wobble.decay * elapsed))
            let phase = elapsed * config.wobble.frequency * 2 * Double.pi
            return -CGFloat(cos(phase)) * envelope * .pi / 180
        }

        let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wobble.values = rotations
        wobble.calculationMode = .linear
        wobble.isAdditive = true
        wobble.beginTime = timelineStartTime
            + recoveryTime * config.global.durationScale
        wobble.duration = duration * config.global.durationScale
        layer.add(wobble, forKey: "recoveryWobble")
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
        timelineStartTime: CFTimeInterval,
        bumpTime: TimeInterval,
        exitTime: TimeInterval,
        config: AnimationConfig
    ) {
        guard config.banner.swayAmplitude != 0, config.banner.swayFrequency > 0 else { return }

        let refreshRate = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        let sampleCount = max(2, Int(ceil(exitTime * Double(refreshRate))))
        let samples = (0...sampleCount).map { sample -> (offset: CGFloat, rotation: CGFloat) in
            let elapsed = exitTime * Double(sample) / Double(sampleCount)
            let wobbleAge = elapsed - bumpTime - config.wobble.recoveryDelay
            let wobbleEnvelope = wobbleAge < 0
                ? 0
                : config.wobble.amplitude * CGFloat(exp(-config.wobble.decay * wobbleAge))
            let phase = elapsed * config.banner.swayFrequency * 2 * Double.pi
            let offset = CGFloat(sin(phase))
                * (config.banner.swayAmplitude + wobbleEnvelope)
            let rotation = CGFloat(sin(phase + 0.45))
                * config.banner.swayAmplitude / config.banner.width
            return (offset, rotation)
        }

        let verticalSway = CAKeyframeAnimation(keyPath: "transform.translation.y")
        verticalSway.values = samples.map(\.offset)
        verticalSway.calculationMode = .linear
        verticalSway.beginTime = timelineStartTime
        verticalSway.duration = exitTime * config.global.durationScale
        pivotLayer.add(verticalSway, forKey: "bannerVerticalSway")

        let connectorSway = CAKeyframeAnimation(keyPath: "path")
        connectorSway.values = samples.map {
            makeConnectorPath(
                tetherLength: config.banner.tetherLength,
                verticalOffset: $0.offset
            )
        }
        connectorSway.calculationMode = .linear
        connectorSway.beginTime = timelineStartTime
        connectorSway.duration = exitTime * config.global.durationScale
        connectorLayer.add(connectorSway, forKey: "connectorSway")

        let rotationSway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotationSway.values = samples.map(\.rotation)
        rotationSway.calculationMode = .linear
        rotationSway.beginTime = timelineStartTime
        rotationSway.duration = exitTime * config.global.durationScale
        bannerLayer.add(rotationSway, forKey: "bannerRotationSway")
    }

    private func startInteractionTracking() {
        interactionDisplayLink?.invalidate()
        let displayLink = displayLink(
            target: self,
            selector: #selector(updateMousePassthrough(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        interactionDisplayLink = displayLink
    }

    private func scheduleCompletion(after duration: TimeInterval) {
        completionTimer?.invalidate()
        let timer = Timer(
            timeInterval: duration,
            target: self,
            selector: #selector(animationDidComplete(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    @objc private func updateMousePassthrough(_ displayLink: CADisplayLink) {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            window.ignoresMouseEvents = true
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        window.ignoresMouseEvents = !containsVisibleContent(at: localPoint)
    }

    @objc private func animationDidComplete(_ timer: Timer) {
        completionTimer = nil
        dismissHandler()
    }

    private func containsVisibleContent(at point: CGPoint) -> Bool {
        if let truckHitLayer,
           presentationLayer(truckHitLayer, contains: point) {
            return true
        }
        if let cupHitLayer,
           presentationLayer(cupHitLayer, contains: point) {
            return true
        }
        if let bannerHitLayer,
           presentationLayer(bannerHitLayer, contains: point) {
            return true
        }
        return spillAnimator?.containsVisibleLiquid(at: point) == true
    }

    private func presentationLayer(_ targetLayer: CALayer, contains point: CGPoint) -> Bool {
        guard let rootLayer = layer,
              let presentedRoot = rootLayer.presentation(),
              let presentedTarget = targetLayer.presentation(),
              !presentedTarget.isHidden,
              presentedTarget.opacity > 0.01 else {
            return false
        }

        let pointInTarget = presentedTarget.convert(point, from: presentedRoot)
        return presentedTarget.bounds.contains(pointInTarget)
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

extension NSColor {
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

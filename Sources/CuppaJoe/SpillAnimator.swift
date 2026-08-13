import AppKit
import QuartzCore

struct CupMotion {
    struct Pose {
        let position: CGPoint
        let rotation: CGFloat
        let widthScale: CGFloat
        let heightScale: CGFloat
    }

    let startPosition: CGPoint
    let startRotation: CGFloat
    let initialScale: CGFloat
    let cupSize: CGSize
    let config: AnimationConfig

    var totalDuration: TimeInterval {
        config.cup.flightDuration + config.cup.slideDuration
    }

    func pose(at elapsed: TimeInterval) -> Pose {
        let elapsedValue = CGFloat(elapsed)
        let flightDuration = CGFloat(config.cup.flightDuration)
        let slideDuration = CGFloat(config.cup.slideDuration)
        let flightTime = min(max(elapsedValue, 0), flightDuration)
        var position = CGPoint(
            x: startPosition.x + config.cup.launchVelocityX * flightTime,
            y: startPosition.y - config.cup.launchVelocityY * flightTime
                - 0.5 * config.cup.gravity * flightTime * flightTime
        )
        var rotation = startRotation
            - config.cup.spinRate * flightTime * .pi / 180

        if elapsedValue >= flightDuration {
            let slideAge = min(
                elapsedValue - flightDuration,
                slideDuration
            )
            let impactVelocityY = config.cup.launchVelocityY
                + config.cup.gravity * flightDuration
            let slideAccelerationY: CGFloat = 2 * (
                position.y + cupSize.height * config.cup.slideTargetHeightFraction
                    - impactVelocityY * slideDuration
            ) / (slideDuration * slideDuration)

            position.x += config.cup.launchVelocityX * slideAge
                + 0.5 * config.cup.slideAccelerationX * slideAge * slideAge
            position.y -= impactVelocityY * slideAge
                + 0.5 * slideAccelerationY * slideAge * slideAge
            rotation -= config.cup.spinRate * slideAge * .pi / 180
                + 0.5 * config.cup.slideSpinAcceleration * slideAge * slideAge * .pi / 180
        }

        let morphProgress = easeOutQuart(
            min(max(elapsedValue / CGFloat(config.cup.morphDuration), 0), 1)
        )
        var widthScale = initialScale + (1 - initialScale) * morphProgress
        var heightScale = widthScale
        if elapsedValue >= flightDuration {
            let compressionProgress = min(
                max(
                    (elapsedValue - flightDuration) / CGFloat(config.cup.compressionDuration),
                    0
                ),
                1
            )
            let compression = sin(compressionProgress * .pi)
            widthScale *= 1 + compression * config.cup.compressionWidthFraction
            heightScale *= 1 - compression * config.cup.compressionHeightFraction
        }

        return Pose(
            position: position,
            rotation: rotation,
            widthScale: widthScale,
            heightScale: heightScale
        )
    }

    func rimPosition(at elapsed: TimeInterval) -> CGPoint {
        let pose = pose(at: elapsed)
        let localX = cupSize.width * pose.widthScale * config.cup.rimOffsetXFraction
        let localY = cupSize.height * pose.heightScale * config.cup.rimOffsetYFraction
        return CGPoint(
            x: pose.position.x + localX * cos(pose.rotation) - localY * sin(pose.rotation),
            y: pose.position.y + localX * sin(pose.rotation) + localY * cos(pose.rotation)
        )
    }

    private func easeOutQuart(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 4)
    }
}

@MainActor
final class SpillAnimator: NSObject {
    private struct StreamPoint {
        let center: CGPoint
        let halfWidth: CGFloat
    }

    private let view: NSView
    private let container = CALayer()
    private let streamLayer = CAShapeLayer()
    private let leftTrickleLayer = CAShapeLayer()
    private let rightTrickleLayer = CAShapeLayer()
    private let dropletLayer = CAShapeLayer()
    private let splashLayer = CAShapeLayer()
    private let motion: CupMotion
    private let launchBeginTime: CFTimeInterval
    private let launchTime: TimeInterval
    private let animationDuration: TimeInterval
    private let config: AnimationConfig
    private var displayLink: CADisplayLink?

    init(
        view: NSView,
        rootLayer: CALayer,
        below cupLayer: CALayer,
        motion: CupMotion,
        launchBeginTime: CFTimeInterval,
        launchTime: TimeInterval,
        animationDuration: TimeInterval,
        contentsScale: CGFloat,
        config: AnimationConfig
    ) {
        self.view = view
        self.motion = motion
        self.launchBeginTime = launchBeginTime
        self.launchTime = launchTime
        self.animationDuration = animationDuration
        self.config = config
        super.init()

        container.frame = rootLayer.bounds
        container.contentsScale = contentsScale
        let liquidColor = NSColor(hex: config.liquid.color).cgColor
        configureFillLayer(streamLayer, color: liquidColor, contentsScale: contentsScale)
        configureTrickleLayer(leftTrickleLayer, color: liquidColor, contentsScale: contentsScale)
        configureTrickleLayer(rightTrickleLayer, color: liquidColor, contentsScale: contentsScale)
        configureFillLayer(dropletLayer, color: liquidColor, contentsScale: contentsScale)
        configureFillLayer(splashLayer, color: liquidColor, contentsScale: contentsScale)

        streamLayer.opacity = Float(config.liquid.opacity)
        leftTrickleLayer.opacity = Float(config.liquid.opacity * 0.62)
        rightTrickleLayer.opacity = Float(config.liquid.opacity * 0.45)
        dropletLayer.opacity = Float(config.liquid.opacity)

        container.addSublayer(streamLayer)
        container.addSublayer(leftTrickleLayer)
        container.addSublayer(rightTrickleLayer)
        container.addSublayer(dropletLayer)
        container.addSublayer(splashLayer)
        rootLayer.insertSublayer(container, below: cupLayer)
    }

    func start() {
        displayLink?.invalidate()
        let displayLink = view.displayLink(
            target: self,
            selector: #selector(displayFrame(_:))
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        container.removeFromSuperlayer()
    }

    func containsVisibleLiquid(at point: CGPoint) -> Bool {
        guard container.superlayer != nil,
              (container.presentation()?.opacity ?? container.opacity) > 0.01 else {
            return false
        }

        let localPoint = container.convert(point, from: container.superlayer)
        if fillLayer(streamLayer, contains: localPoint)
            || fillLayer(dropletLayer, contains: localPoint)
            || fillLayer(splashLayer, contains: localPoint) {
            return true
        }
        return strokeLayer(leftTrickleLayer, contains: localPoint)
            || strokeLayer(rightTrickleLayer, contains: localPoint)
    }

    @objc private func displayFrame(_ displayLink: CADisplayLink) {
        let elapsed = (displayLink.timestamp - launchBeginTime) / config.global.durationScale
        let impactAge = elapsed - config.cup.flightDuration
        guard impactAge >= 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let splashVisible = updateSplash(impactAge: impactAge)
        let liquidVisible = updateLiquid(impactAge: impactAge)
        updateFinalFade(overallElapsed: launchTime + elapsed)
        CATransaction.commit()

        if elapsed >= motion.totalDuration,
           impactAge >= max(config.splash.duration, config.liquid.pourDuration),
           !splashVisible,
           !liquidVisible {
            displayLink.invalidate()
            self.displayLink = nil
        }
    }

    private func updateFinalFade(overallElapsed: TimeInterval) {
        let fadeDuration = config.liquid.fadeDuration
        guard fadeDuration > 0 else {
            container.opacity = 1
            return
        }

        let progress = min(
            max((overallElapsed - (animationDuration - fadeDuration)) / fadeDuration, 0),
            1
        )
        container.opacity = Float(1 - progress)
    }

    private func fillLayer(_ layer: CAShapeLayer, contains point: CGPoint) -> Bool {
        guard layer.opacity > 0.01,
              let path = layer.path else { return false }
        return path.contains(point)
    }

    private func strokeLayer(_ layer: CAShapeLayer, contains point: CGPoint) -> Bool {
        guard layer.opacity > 0.01,
              let path = layer.path else { return false }
        let hitPath = path.copy(
            strokingWithWidth: layer.lineWidth + 8,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 0
        )
        return hitPath.contains(point)
    }

    private func updateSplash(impactAge: TimeInterval) -> Bool {
        guard impactAge < config.splash.duration else {
            splashLayer.path = nil
            return false
        }

        let progress = CGFloat(impactAge / config.splash.duration)
        let burstProgress = min(progress / config.splash.burstDurationFraction, 1)
        let burst = easeOutBack(burstProgress, overshoot: config.splash.burstOvershoot)
        let fade = 1 - progress * progress * progress
        let impact = motion.rimPosition(at: config.cup.flightDuration)
        let radius = config.splash.radius
        let path = CGMutablePath()

        addEllipse(
            to: path,
            center: CGPoint(x: impact.x, y: impact.y - radius * 0.08),
            radii: CGSize(width: radius * 0.42 * burst, height: radius * 0.18 * burst),
            rotation: -0.2
        )

        for index in 0..<config.splash.dropletCount {
            let denominator = max(1, config.splash.dropletCount - 1)
            let angle = CGFloat.pi * (
                0.12 + CGFloat(index) / CGFloat(denominator) * 0.76
            )
            let reach = radius * (
                0.56 + 0.4 * (0.5 + 0.5 * sin(CGFloat(index) * 12.7))
            )
            let distance = reach * easeOutQuart(progress)
            let center = CGPoint(
                x: impact.x + cos(angle) * distance,
                y: impact.y - sin(angle) * distance
                    - radius * config.splash.dropletFallFraction * progress * progress
            )
            let size = radius * (
                0.035 + 0.025 * (0.5 + 0.5 * sin(CGFloat(index) * 5.1))
            )
            addEllipse(
                to: path,
                center: center,
                radii: CGSize(width: size * 1.7, height: size),
                rotation: -angle
            )
        }

        splashLayer.path = path
        splashLayer.opacity = Float(config.liquid.opacity * fade)
        return true
    }

    private func updateLiquid(impactAge: TimeInterval) -> Bool {
        let pourDuration = min(config.liquid.pourDuration, config.cup.slideDuration)
        let latestEmissionAge = min(impactAge, pourDuration)
        let gravity = config.cup.gravity * config.liquid.gravityScale
        var points: [StreamPoint] = []

        func addStreamPoint(emissionAge: TimeInterval) {
            let age = CGFloat(impactAge - emissionAge)
            let origin = motion.rimPosition(
                at: config.cup.flightDuration + emissionAge
            )
            let y = origin.y
                - config.liquid.flowSpeed * config.liquid.streamInitialSpeedScale * age
                - 0.5 * gravity * age * age
            guard y >= -config.liquid.streamWidth else { return }

            points.append(StreamPoint(
                center: CGPoint(
                    x: origin.x
                        + CGFloat(sin(emissionAge * config.liquid.streamJitterFrequency))
                            * config.liquid.streamWidth * config.liquid.streamJitterFraction,
                    y: y
                ),
                halfWidth: config.liquid.streamWidth
                    * (config.liquid.streamBaseHalfWidthFraction
                        + min(age, config.liquid.streamWideningDuration)
                            * config.liquid.streamWideningRate)
                    * (1 - config.liquid.streamWidthVariation
                        + config.liquid.streamWidthVariation
                            * CGFloat(sin(
                                emissionAge * config.liquid.streamWidthVariationFrequency
                            )))
            ))
        }

        addStreamPoint(emissionAge: latestEmissionAge)
        let lastFixedSample = Int(
            floor(latestEmissionAge / config.liquid.streamSampleInterval)
        )
        if lastFixedSample >= 0 {
            for index in stride(from: lastFixedSample, through: 0, by: -1) {
                let emissionAge = TimeInterval(index) * config.liquid.streamSampleInterval
                if latestEmissionAge - emissionAge > 0.002 {
                    addStreamPoint(emissionAge: emissionAge)
                }
            }
        }

        updateStream(points)
        let hasDroplets = updateDroplets(
            impactAge: impactAge,
            pourDuration: pourDuration,
            gravity: gravity
        )
        return points.count > 1 || hasDroplets
    }

    private func updateStream(_ points: [StreamPoint]) {
        guard points.count > 1 else {
            streamLayer.path = nil
            leftTrickleLayer.path = nil
            rightTrickleLayer.path = nil
            return
        }

        let leftEdge = points.map {
            CGPoint(x: $0.center.x - $0.halfWidth, y: $0.center.y)
        }
        let rightEdge = points.reversed().map {
            CGPoint(x: $0.center.x + $0.halfWidth, y: $0.center.y)
        }
        let streamPath = CGMutablePath()
        addSmoothed(points: leftEdge, to: streamPath, moveToFirst: true)
        addSmoothed(points: rightEdge, to: streamPath, moveToFirst: false)
        streamPath.closeSubpath()
        streamLayer.path = streamPath

        leftTrickleLayer.path = makeTricklePath(
            points: Array(points.dropFirst(3)),
            side: -1,
            inset: 7
        )
        rightTrickleLayer.path = makeTricklePath(
            points: Array(points.dropFirst(5)),
            side: 1,
            inset: 11
        )
        leftTrickleLayer.lineWidth = 5
        rightTrickleLayer.lineWidth = 3
    }

    private func updateDroplets(
        impactAge: TimeInterval,
        pourDuration: TimeInterval,
        gravity: CGFloat
    ) -> Bool {
        let path = CGMutablePath()
        var drewDroplet = false

        for index in 0..<config.liquid.dropletCount {
            let emissionAge = config.liquid.dropletEmissionDelay
                + TimeInterval(index) * config.liquid.dropletEmissionInterval
            guard emissionAge <= pourDuration else { break }
            let age = CGFloat(impactAge - emissionAge)
            guard age > 0 else { continue }

            let origin = motion.rimPosition(
                at: config.cup.flightDuration + emissionAge
            )
            let variation = config.liquid.dropletMinimumSpeedScale
                + config.liquid.dropletSpeedVariation
                    * (0.5 + 0.5 * sin(CGFloat(index) * 11.7))
            let center = CGPoint(
                x: origin.x
                    + sin(CGFloat(index) * 7.3) * config.liquid.streamWidth
                        * config.liquid.dropletHorizontalSpreadFraction
                    + sin(CGFloat(index) * 2.1)
                        * config.liquid.dropletHorizontalDrift * age,
                y: origin.y - config.liquid.flowSpeed * variation * age
                    - 0.5 * gravity * age * age
            )
            guard center.y >= -20 else { continue }

            let size = config.liquid.streamWidth * (
                0.045 + 0.035 * (0.5 + 0.5 * sin(CGFloat(index) * 5.9))
            )
            addEllipse(
                to: path,
                center: center,
                radii: CGSize(width: size, height: size * 1.8),
                rotation: -sin(CGFloat(index) * 3.4) * 0.3
            )
            drewDroplet = true
        }

        dropletLayer.path = drewDroplet ? path : nil
        return drewDroplet
    }

    private func makeTricklePath(
        points: [StreamPoint],
        side: CGFloat,
        inset: CGFloat
    ) -> CGPath? {
        guard points.count > 1 else { return nil }
        let centers = points.map {
            CGPoint(
                x: $0.center.x + side * ($0.halfWidth + inset),
                y: $0.center.y
            )
        }
        let path = CGMutablePath()
        addSmoothed(points: centers, to: path, moveToFirst: true)
        return path
    }

    private func addSmoothed(
        points: [CGPoint],
        to path: CGMutablePath,
        moveToFirst: Bool
    ) {
        guard let first = points.first else { return }
        if moveToFirst {
            path.move(to: first)
        } else {
            path.addLine(to: first)
        }
        guard points.count > 1 else { return }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
    }

    private func addEllipse(
        to path: CGMutablePath,
        center: CGPoint,
        radii: CGSize,
        rotation: CGFloat
    ) {
        let rect = CGRect(
            x: -radii.width,
            y: -radii.height,
            width: radii.width * 2,
            height: radii.height * 2
        )
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation)
        path.addEllipse(in: rect, transform: transform)
    }

    private func configureFillLayer(
        _ layer: CAShapeLayer,
        color: CGColor,
        contentsScale: CGFloat
    ) {
        layer.frame = container.bounds
        layer.fillColor = color
        layer.contentsScale = contentsScale
    }

    private func configureTrickleLayer(
        _ layer: CAShapeLayer,
        color: CGColor,
        contentsScale: CGFloat
    ) {
        layer.frame = container.bounds
        layer.fillColor = nil
        layer.strokeColor = color
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.contentsScale = contentsScale
    }

    private func easeOutBack(_ progress: CGFloat, overshoot: CGFloat) -> CGFloat {
        let shifted = progress - 1
        return 1 + (overshoot + 1) * pow(shifted, 3) + overshoot * pow(shifted, 2)
    }

    private func easeOutQuart(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 4)
    }
}

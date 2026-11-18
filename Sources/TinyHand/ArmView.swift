import AppKit

final class ArmView: NSView {
    private let group = CALayer()
    private let rodLayer = CALayer()
    private let handLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let dotCore = CAShapeLayer()
    private let rodFade = CAGradientLayer()
    private let burstLayer = CALayer()

    private(set) var style: PointerStyle = .lavender
    private var asset: HandAsset?

    private var handLenFrac: CGFloat = Preferences.pointerSize
    private var showShadow = Preferences.showShadow
    private var fadingStick = Preferences.fadingStick
    // How much of a fading stick shows below the wrist, and how long its fade is, in hand lengths.
    private let stickShowFrac: CGFloat = 4
    private let stickFadeFrac: CGFloat = 1.2
    private let minRodFrac: CGFloat = 0.05
    private let gripLeanFrac: CGFloat = 0.30
    private let gripDepthFrac: CGFloat = 0.12
    private let gripFollow: CGFloat = 0.08
    private let liftFrac: CGFloat = 0.06

    let ink = Ink()
    var held = false
    var inkWidth: CGFloat { max(3, bounds.height * 0.0055) }

    private var pressAmount: CGFloat = 0
    private var gripX: CGFloat?
    private var lastPose: [CGFloat] = []
    private var lastLaserPose: [CGFloat] = []
    private var gripTarget: CGFloat?
    private var displayImageHeight = 0
    private var tip: CGPoint?
    private var gripPoint: CGPoint?

    // Quick repeated taps build up: each one within `streakWindow` of the last goes up a level,
    // to `maxTapLevel`, for a deeper poke and a bigger burst.
    private static let streakWindow: TimeInterval = 0.45
    private static let maxTapLevel = 3
    private var tapLevel = 0
    private var lastPressAt = Date.distantPast
    private var burstTurn: CGFloat = 0

    var isSettling: Bool {
        if pressAmount > 0.002 {
            return true
        }
        guard let gx = gripX, let target = gripTarget else {
            return false
        }
        return abs(target - gx) > 0.5
    }

    var pointerHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            group.isHidden = pointerHidden || style == .laser
            dotLayer.isHidden = pointerHidden || style != .laser
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        root.addSublayer(ink.layer)
        root.addSublayer(group)

        root.addSublayer(dotLayer)
        root.addSublayer(burstLayer)
        rodFade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]

        group.masksToBounds = false
        group.addSublayer(rodLayer)
        group.addSublayer(handLayer)
        for sub in [rodLayer, handLayer] {
            sub.contentsGravity = .resize
            sub.contentsScale = 2
            sub.anchorPoint = CGPoint(x: 0.5, y: 0)
            sub.shadowColor = NSColor.black.cgColor
            sub.shadowOpacity = 0.38
        }

        dotLayer.fillColor = Ink.red
        dotLayer.shadowColor = Ink.red
        dotLayer.shadowOpacity = 1
        dotLayer.shadowOffset = .zero
        dotCore.fillColor = CGColor(srgbRed: 1, green: 0.86, blue: 0.82, alpha: 0.95)
        dotLayer.addSublayer(dotCore)

        setStyle(PointerStyle.saved)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.handLenFrac = Preferences.pointerSize
            self?.showShadow = Preferences.showShadow
            self?.fadingStick = Preferences.fadingStick
        }
    }

    func updateInkColor() {
        ink.color = Preferences.inkChoice.resolved(for: style)
    }

    func setStyle(_ newStyle: PointerStyle) {
        style = newStyle
        asset = newStyle.assetName.flatMap(HandAsset.load)
        if newStyle != .laser && asset == nil {
            style = .laser
        }
        updateInkColor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let a = asset, style != .laser {
            group.anchorPoint = CGPoint(x: a.rodX, y: 0)
            displayImageHeight = 0
            updateDisplayImage(a)
            rodLayer.contentsRect = CGRect(x: 0, y: 1 - a.rodEnd, width: 1, height: a.rodEnd - a.wrist)
            handLayer.contentsRect = CGRect(x: 0, y: 1 - a.wrist, width: 1, height: a.wrist - a.handTop)
        }
        CATransaction.commit()
        let hidden = pointerHidden
        pointerHidden = hidden
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func press() {
        let now = Date()
        tapLevel = now.timeIntervalSince(lastPressAt) < ArmView.streakWindow ? min(tapLevel + 1, ArmView.maxTapLevel) : 0
        lastPressAt = now
        pressAmount = 1 + 0.3 * CGFloat(tapLevel)
    }

    func aim(cursor: CGPoint) {
        let screenH = bounds.height
        let targetX = min(max(cursor.x + gripLeanFrac * bounds.width, bounds.width * 0.15), bounds.width * 1.05)
        let gx = gripX.map { $0 + (targetX - $0) * gripFollow } ?? targetX
        gripX = gx
        gripTarget = targetX
        let grip = CGPoint(x: gx, y: -gripDepthFrac * screenH)
        tip = cursor
        gripPoint = grip

        if !held {
            pressAmount += (0 - pressAmount) * 0.18
        }

        if style == .laser {
            aimLaser(cursor: cursor)
            return
        }
        guard let a = asset else {
            return
        }
        updateDisplayImage(a)

        let dx = cursor.x - grip.x
        let dy = cursor.y - grip.y
        let reach = hypot(dx, dy)
        let aimAngle = atan2(dy, dx)

        let handPts = handLenFrac * screenH * (1 - 0.06 * pressAmount)
        let s = handPts / (a.wrist - a.handTop)
        let widthPts = s * a.aspect
        let handTipPts = (a.wrist - a.tip) * s
        let tipOffX = (a.tipX - a.rodX) * widthPts

        let along = sqrt(max(0, reach * reach - tipOffX * tipOffX))
        var rodLen = along - handTipPts
        rodLen = max(minRodFrac * screenH, rodLen)
        let tipAngle = atan2(rodLen + handTipPts, tipOffX)
        let rotation = aimAngle - tipAngle

        let lift = currentLift(screenH)
        let sx = lift * 0.6
        let sy = -lift
        let shadowOffset = CGSize(
            width: sx * cos(-rotation) - sy * sin(-rotation),
            height: sx * sin(-rotation) + sy * cos(-rotation)
        )

        let pose = [rotation, rodLen, handPts, widthPts, grip.x, lift, pressAmount, showShadow ? 1 : 0, fadingStick ? 1 : 0, a.aspect]
            .map { ($0 * 100).rounded() }
        guard pose != lastPose else {
            return
        }
        lastPose = pose

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for sub in [rodLayer, handLayer] {
            sub.shadowOffset = shadowOffset
            sub.shadowRadius = max(1, lift * 0.35) + 5 * pressAmount
            sub.shadowOpacity = showShadow ? Float(0.26 + 0.02 * pressAmount) : 0
        }

        rodLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen)
        rodLayer.position = CGPoint(x: widthPts / 2, y: 0)
        if fadingStick {
            // The mask reaches past the rod so its shadow fades with it. Opaque from `solid` up to the wrist.
            let pad = widthPts
            let maskH = rodLen + 2 * pad
            let solid = rodLen + pad - stickShowFrac * handPts
            rodFade.frame = CGRect(x: -pad, y: -pad, width: widthPts + 2 * pad, height: maskH)
            rodFade.startPoint = CGPoint(x: 0.5, y: (solid - stickFadeFrac * handPts) / maskH)
            rodFade.endPoint = CGPoint(x: 0.5, y: solid / maskH)
            rodLayer.mask = rodFade
        } else {
            rodLayer.mask = nil
        }
        handLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: handPts)
        handLayer.position = CGPoint(x: widthPts / 2, y: rodLen)

        group.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen + handPts)
        group.position = grip
        group.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)

        CATransaction.commit()
    }

    /// Short lines burst out from the fingertip, away from the hand, and fade. Each burst sits at a
    /// new angle and spins a little; quick repeated taps make it bigger, busier and longer.
    func burst() {
        guard let tip = tip else {
            return
        }
        let level = CGFloat(tapLevel)
        let handPts = handLenFrac * bounds.height
        let radius = handPts * (style == .laser ? 0.22 : 0.34) * (1 + 0.25 * level)
        let width = max(2, handPts * 0.026) * (1 + 0.18 * level)
        // Leave a gap where the finger is, pointing back toward the grip.
        let gap: CGFloat = style == .laser ? 0 : 1.9
        let back = gripPoint.map { atan2($0.y - tip.y, $0.x - tip.x) } ?? -.pi / 2
        let count = (style == .laser ? 10 : 8) + 2 * tapLevel
        let span = 2 * .pi - gap
        burstTurn = tapLevel == 0 ? CGFloat.random(in: 0..<1) : (burstTurn + 0.38).truncatingRemainder(dividingBy: 1)
        let path = CGMutablePath()
        func ray(_ angle: CGFloat, _ inner: CGFloat, _ outer: CGFloat) {
            path.move(to: CGPoint(x: inner * cos(angle), y: inner * sin(angle)))
            path.addLine(to: CGPoint(x: outer * cos(angle), y: outer * sin(angle)))
        }
        for i in 0..<count {
            let step = (CGFloat(i) + (gap == 0 ? burstTurn : 0.25 + 0.5 * burstTurn)) / CGFloat(count)
            let angle = back + gap / 2 + span * step + CGFloat.random(in: -0.08...0.08)
            ray(angle, radius * CGFloat.random(in: 0.5...0.62), radius * CGFloat.random(in: 0.88...1.06))
            // From the third quick tap, short ticks fill in further out between the main lines.
            if tapLevel >= 2 && (gap == 0 || i < count - 1) {
                let between = angle + span / CGFloat(count) / 2
                ray(between, radius * 1.08, radius * CGFloat.random(in: 1.22...1.32))
            }
        }

        let lines = CAShapeLayer()
        lines.path = path
        lines.fillColor = nil
        lines.strokeColor = ink.color
        lines.lineWidth = width
        lines.lineCap = .round
        lines.position = tip
        lines.opacity = 0

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.35 + 0.12 * level
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (tapLevel % 2 == 0 ? 1 : -1) * (0.22 + 0.08 * level)
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = width
        thin.toValue = width * 0.45
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.45, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, spin, thin, fade]
        group.duration = 0.28 + 0.05 * Double(tapLevel)
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { lines.removeFromSuperlayer() }
        burstLayer.addSublayer(lines)
        lines.add(group, forKey: "burst")
        CATransaction.commit()
    }

    private func currentLift(_ screenH: CGFloat) -> CGFloat {
        liftFrac * screenH * max(0, 1 - 0.8 * pressAmount)
    }

    private func aimLaser(cursor: CGPoint) {
        let press = pressAmount
        let r = max(4, bounds.height * 0.0038 * handLenFrac / 0.13) * (1 + 0.2 * press)
        let laserPose = [r, cursor.x, cursor.y].map { ($0 * 100).rounded() }
        guard laserPose != lastLaserPose else {
            return
        }
        lastLaserPose = laserPose
        let core = r * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dot = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dotLayer.path = dot
        dotLayer.shadowPath = dot
        dotCore.path = CGPath(ellipseIn: CGRect(x: -core, y: -core, width: 2 * core, height: 2 * core), transform: nil)
        dotLayer.position = cursor
        dotLayer.shadowRadius = r * (2.2 + 1.0 * press)
        CATransaction.commit()
    }

    private func updateDisplayImage(_ a: HandAsset) {
        let full = a.image
        let scale = window?.backingScaleFactor ?? 2
        let restPts = handLenFrac * bounds.height / (a.wrist - a.handTop)
        let step = 64
        let needed = (Int((restPts * scale).rounded(.up)) + step - 1) / step * step
        let height = needed >= full.height * 9 / 10 ? full.height : max(step, needed)
        guard height != displayImageHeight else {
            return
        }
        displayImageHeight = height
        let image = height == full.height ? full : HandAsset.resized(full, height: height) ?? full
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rodLayer.contents = image
        handLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        rodLayer.contentsScale = scale
        handLayer.contentsScale = scale
        ink.scale = scale
    }
}

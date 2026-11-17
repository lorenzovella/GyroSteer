// Reads the controller, turns its tilt into steering and sends it to the mod (SteerCore, on its own queue so
// drawing the window never delays the steering), and hands the window a copy of the state to draw (Engine).

import Foundation
import GameController
import Observation

struct Sample: Identifiable {
    let id: Int
    let t: TimeInterval
    /// Degrees from straight: gyro and accelerometer combined (what steers the car).
    let tilt: Double
    /// Degrees from straight from the accelerometer alone, to show what the gyro smooths out.
    let accelTilt: Double
    /// The steering wheel's angle, degrees: follows the tilt, and keeps turning past the threshold.
    let wheel: Double
    /// Steering sent to the game, -1...1; nil while gyro steering is off.
    let sent: Double?
    /// The car's steering input after the game's smoothing, as last reported by the mod.
    let applied: Double?
    /// Raw gyro, degrees per second around the controller's x (right), y (forward) and z (out of the face).
    let gyro: V3
    /// Raw accelerometer, g.
    let accel: V3
}

/// A controller action and the buttons that, pressed together, trigger it.
enum ButtonAction: String, CaseIterable, Identifiable {
    case recenter, toggleGyro
    var id: String { rawValue }
    var title: String { self == .recenter ? "Set straight" : "Gyro on/off" }
    var defaultButtons: Set<String> {
        switch self {
        case .recenter: return [GCInputButtonOptions, GCInputButtonMenu]
        case .toggleGyro: return [GCInputLeftThumbstickButton, GCInputRightThumbstickButton]
        }
    }
}

struct GameStatus {
    var lastReply: TimeInterval?
    var hasCar = false
    var steering = false
    var applied: Double?
}

/// The defaults are the setup that drives well with the G5 Pro; anything changed in the window is saved over them.
struct Tuning {
    /// Wheel angle for full lock, degrees each way.
    var range = 50.0
    var deadzone = 1.5
    var curve = 1.5
    var invert = false
    var direct = true
    /// Past `threshold` degrees of tilt the wheel keeps turning, at up to `speed` degrees a second.
    var keepTurning = true
    var threshold = 48.0
    var speed = 350.0
    /// The right stick is the throttle and the left stick the brake, by how far each is pushed from the middle.
    var pedals = true
    /// Stick travel ignored around the middle, percent.
    var pedalDeadzone = 5.0
}

/// Everything the window shows, copied out of the core.
struct CoreState {
    var version = 0
    var history: [Sample] = []
    var controllerName: String?
    var center = 0.0
    var gyroEnabled = true
    var simulate = false
    var game = GameStatus()
    var bindings: [ButtonAction: Set<String>] = [:]
    /// The controller's own names for its buttons.
    var buttonLabels: [String: String] = [:]
    var learning: ButtonAction?
    var learned: Set<String> = []
    var notice: String?
    var noticeTime: TimeInterval = 0
    /// Pedals from the sticks, 0...1, as last sent to the game.
    var throttle = 0.0
    var brake = 0.0
}

// MARK: - Core

/// The steering path. Everything here runs on `queue`.
final class SteerCore {
    static let window: TimeInterval = 10
    let queue = DispatchQueue(label: "gyrosteer.core", qos: .userInteractive)

    private var state = CoreState()
    private var tuning = Tuning()
    private let link: Link
    private let fusion = TiltFusion()
    private let wheel = VirtualWheel()
    private let notifications = OperationQueue()
    private var controller: GCController?
    private var lastMotion: TimeInterval?
    private var lastRoll = 0.0
    private var lastSend: TimeInterval = 0
    private var lastPacket: String?
    private var nextId = 0
    private var held: Set<ButtonAction> = []
    private var simulationStart = uptime()
    private var timer: DispatchSourceTimer?
    private var lastPedalSend: TimeInterval = 0
    private var lastModeSend: TimeInterval = 0

    init(port: UInt16, bindings: [ButtonAction: Set<String>], tuning: Tuning) {
        link = Link(port: port, queue: queue)
        state.bindings = bindings
        self.tuning = tuning
        notifications.underlyingQueue = queue
        notifications.maxConcurrentOperationCount = 1
    }

    // MARK: Called from the window

    func snapshot() -> CoreState { queue.sync { state } }
    func setTuning(_ t: Tuning) { queue.async { self.tuning = t; self.updatePedals(); self.sendMode(uptime()) } }
    func setGyro(_ on: Bool) { queue.async { self.applyGyro(on) } }
    func recenter() { queue.async { self.perform(.recenter) } }
    func learn(_ action: ButtonAction?) { queue.async { self.state.learning = action; self.state.learned = []; self.changed() } }
    func resetButtons(_ action: ButtonAction) { queue.async { self.setBinding(action, action.defaultButtons) } }

    func setSimulate(_ on: Bool) {
        queue.async {
            guard on != self.state.simulate else { return }
            self.state.simulate = on
            self.fusion.reset()
            self.wheel.reset()
            self.lastMotion = nil
            self.simulationStart = uptime()
            self.changed()
        }
    }

    func start() {
        queue.async {
            GCController.shouldMonitorBackgroundEvents = true
            let nc = NotificationCenter.default
            nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: self.notifications) { [weak self] note in
                if let c = note.object as? GCController { self?.attach(c) }
            }
            nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: self.notifications) { [weak self] note in
                if let c = note.object as? GCController { self?.detach(c) }
            }
            self.fusion.onGyroSignFlip = { [weak self] in
                self?.say("The gyro turned the opposite way to the accelerometer, so it was flipped")
            }
            self.link.onReceive = { [weak self] text in self?.onReply(text) }
            GCController.controllers().forEach(self.attach)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func shutdown() {
        queue.sync {
            link.send("gs1 off")
            link.send("gs1 mode pedals=0 gyro=0")
            if state.throttle > 0 || state.brake > 0 {
                state.throttle = 0
                state.brake = 0
                sendPedals(uptime())
            }
        }
    }

    // MARK: Controller

    private func attach(_ c: GCController) {
        guard controller == nil else { return }
        let name = c.vendorName ?? c.productCategory
        guard let motion = c.motion else {
            say("\(name) sends no motion data. If it's the G5 Pro, switch it to Switch mode and pair it again.")
            return
        }
        c.handlerQueue = queue
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        motion.valueChangedHandler = { [weak self] m in self?.onMotion(m) }
        c.physicalInputProfile.valueDidChangeHandler = { [weak self] profile, _ in self?.onButtons(profile) }
        controller = c
        state.controllerName = name
        state.buttonLabels = c.physicalInputProfile.buttons.compactMapValues { $0.localizedName }
        fusion.reset()
        wheel.reset()
        lastMotion = nil
        updatePedals()
        sendMode(uptime())
        say("Using \(name)")
    }

    private func detach(_ c: GCController) {
        guard c === controller else { return }
        controller = nil
        state.controllerName = nil
        if !state.simulate { link.send("gs1 off") }
        updatePedals()  // no controller: lets go of both pedals
        sendMode(uptime())
        lastPacket = nil
        say("Controller disconnected; steering handed back to the game")
        GCController.controllers().forEach(attach)
    }

    private func onMotion(_ m: GCMotion) {
        guard !state.simulate else { return }
        let gyro = m.hasRotationRate ? V3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z) : .zero
        process(accel: V3(m.acceleration.x, m.acceleration.y, m.acceleration.z), gyro: gyro)
    }

    // MARK: Buttons

    private func onButtons(_ profile: GCPhysicalInputProfile) {
        updatePedals()
        let pressed = Set(profile.buttons.filter { $0.value.isPressed }.map(\.key))
        if let action = state.learning {
            // Collect everything pressed until all buttons are let go, then save it. Stick directions don't count.
            learnedAdd(pressed.filter { !$0.contains("Thumbstick") || $0.hasSuffix("Button") })
            if pressed.isEmpty, !state.learned.isEmpty {
                setBinding(action, state.learned)
                state.learning = nil
                held = Set(ButtonAction.allCases)  // don't fire on the release
                say("\(action.title) is now on the controller's \(state.learned.count == 1 ? "button" : "buttons")")
            }
            return
        }
        for action in ButtonAction.allCases {
            guard let combo = state.bindings[action], !combo.isEmpty else { continue }
            let down = combo.isSubset(of: pressed)
            if down && !held.contains(action) { perform(action) }
            if down { held.insert(action) } else { held.remove(action) }
        }
    }

    private func learnedAdd(_ buttons: Set<String>) {
        guard !buttons.isSubset(of: state.learned) else { return }
        state.learned.formUnion(buttons)
        changed()
    }

    private func setBinding(_ action: ButtonAction, _ buttons: Set<String>) {
        state.bindings[action] = buttons
        UserDefaults.standard.set(Array(buttons), forKey: "buttons." + action.rawValue)
        changed()
    }

    private func perform(_ action: ButtonAction) {
        switch action {
        case .recenter:
            state.center = lastRoll
            wheel.reset()
            say(String(format: "Straight is now this tilt (%+.1f° from level)", state.center))
        case .toggleGyro:
            applyGyro(!state.gyroEnabled)
        }
    }

    private func applyGyro(_ on: Bool) {
        guard on != state.gyroEnabled else { return }
        state.gyroEnabled = on
        if !on {
            link.send("gs1 off")
            lastPacket = nil
        }
        sendMode(uptime())
        say(on ? "Gyro steering on" : "Gyro steering off: the stick steers as usual")
    }

    /// Tells the mod whether the sticks are pedals right now and whether the gyro steers, so it can pause the game's
    /// stick camera (and, while the gyro steers, the stick's own steering). Repeated every 0.5 s; the mod restores
    /// them if it hears nothing for 2 s.
    private func sendMode(_ t: TimeInterval) {
        let pedalsOn = tuning.pedals && controller != nil
        link.send("gs1 mode pedals=\(pedalsOn ? 1 : 0) gyro=\(state.gyroEnabled ? 1 : 0)")
        lastModeSend = t
    }

    // MARK: Pedals

    /// Reads the sticks (right = throttle, left = brake) and sends the pedals when they change. Without a controller,
    /// or with the setting off, both are 0.
    private func updatePedals() {
        var throttle = 0.0, brake = 0.0
        if tuning.pedals, let pad = controller?.extendedGamepad {
            let dz = tuning.pedalDeadzone / 100
            throttle = pedalOutput(x: Double(pad.rightThumbstick.xAxis.value),
                                   y: Double(pad.rightThumbstick.yAxis.value), deadzone: dz)
            brake = pedalOutput(x: Double(pad.leftThumbstick.xAxis.value),
                                y: Double(pad.leftThumbstick.yAxis.value), deadzone: dz)
        }
        // Steps of 0.001, so changes too small to matter don't each send a packet.
        throttle = (throttle * 1000).rounded() / 1000
        brake = (brake * 1000).rounded() / 1000
        guard throttle != state.throttle || brake != state.brake else { return }
        state.throttle = throttle
        state.brake = brake
        sendPedals(uptime())
        changed()
    }

    /// The mod passes each pedal to the car only when it changes (and again while it's held), so at rest the
    /// triggers' own bindings in the game keep working.
    private func sendPedals(_ t: TimeInterval) {
        link.send(String(format: "gs1 p t=%.3f b=%.3f f=%d", state.throttle, state.brake, tuning.direct ? 2 : 1))
        lastPedalSend = t
    }

    // MARK: Steering

    private func process(accel: V3, gyro: V3) {
        let t = uptime()
        let dt = lastMotion.map { t - $0 } ?? 0.015
        lastMotion = t
        lastRoll = fusion.update(accel: accel, gyro: gyro, dt: dt)
        let tilt = lastRoll - state.center
        let angle = wheel.update(tilt: tuning.invert ? -tilt : tilt, dt: dt, keepTurning: tuning.keepTurning,
                                 threshold: tuning.threshold, speed: tuning.speed, lock: tuning.range)
        let steer = steeringOutput(angle: angle, lock: tuning.range, deadzone: tuning.deadzone, curve: tuning.curve)
        if state.gyroEnabled { send(String(format: "gs1 s=%.4f f=%d", steer, tuning.direct ? 2 : 1), t) }

        let game = state.game
        let answering = game.lastReply.map { t - $0 < 1.5 } ?? false
        state.history.append(Sample(
            id: nextId, t: t, tilt: tilt, accelTilt: rollDeg(accel.unit) - state.center, wheel: angle,
            sent: state.gyroEnabled ? steer : nil,
            applied: answering && game.steering ? game.applied : nil,
            gyro: gyro * (180 / .pi), accel: accel))
        nextId += 1
        while let first = state.history.first, first.t < t - SteerCore.window { state.history.removeFirst() }
        changed()
    }

    private func send(_ packet: String, _ t: TimeInterval) {
        link.send(packet)
        lastPacket = packet
        lastSend = t
    }

    private func tick() {
        let t = uptime()
        if state.simulate { simulateStep(t) }
        updatePedals()
        // While a pedal is held, keep it alive: the mod lets go of the pedals if the app goes quiet for 0.5 s.
        if state.throttle > 0 || state.brake > 0, t - lastPedalSend > 0.1 { sendPedals(t) }
        if t - lastModeSend > 0.5 { sendMode(t) }
        if state.gyroEnabled, let lastPacket, let lastMotion, t - lastMotion < 1 {
            // A steady hand can go quiet; resend so the mod doesn't give up.
            if t - lastSend > 0.15 { send(lastPacket, t) }
        } else if t - lastSend > 0.5 {
            link.send("gs1 ping")
            lastSend = t
        }
    }

    /// Made-up sensor readings of a controller held tilted up 30° and turned left and right like a wheel, now and
    /// then past 60°.
    private func simulateStep(_ t: TimeInterval) {
        let s = t - simulationStart
        let angle = (50 * sin(s * 0.7) + 22 * sin(s * 1.9)) * .pi / 180
        let rate = (50 * 0.7 * cos(s * 0.7) + 22 * 1.9 * cos(s * 1.9)) * .pi / 180
        let r = syntheticReading(angle: angle, rate: rate, pitch: 30 * .pi / 180)
        func jitter() -> Double { Double.random(in: -0.015...0.015) }
        process(accel: r.accel + V3(jitter(), jitter(), jitter()),
                gyro: r.gyro + V3(jitter(), 0.05 + jitter(), jitter()))
    }

    private func onReply(_ text: String) {
        guard text.hasPrefix("gs1 ack") else { return }
        var fields: [Substring: Substring] = [:]
        for part in text.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        state.game.lastReply = uptime()
        state.game.hasCar = fields["car"] == "1"
        state.game.steering = fields["on"] == "1"
        state.game.applied = fields["applied"].flatMap { Double($0) }
        changed()
    }

    private func say(_ text: String) {
        state.notice = text
        state.noticeTime = uptime()
        changed()
    }

    private func changed() { state.version &+= 1 }
}

// MARK: - Window side

@Observable
final class Engine {
    static let shared = Engine()
    static let window = SteerCore.window
    static let port: UInt16 = 47731

    // Tuning, saved between runs.
    var range: Double { didSet { saved(range, "range") } }
    var deadzone: Double { didSet { saved(deadzone, "deadzone") } }
    var curve: Double { didSet { saved(curve, "curve") } }
    var invert: Bool { didSet { saved(invert, "invert") } }
    var direct: Bool { didSet { saved(direct, "direct") } }
    var keepTurning: Bool { didSet { saved(keepTurning, "keepTurning") } }
    var threshold: Double { didSet { saved(threshold, "threshold") } }
    var speed: Double { didSet { saved(speed, "turnSpeed") } }
    var pedals: Bool { didSet { saved(pedals, "pedals") } }
    var pedalDeadzone: Double { didSet { saved(pedalDeadzone, "pedalDeadzone") } }
    var keepOnTop: Bool { didSet { UserDefaults.standard.set(keepOnTop, forKey: "keepOnTop") } }

    var paused = false {
        didSet {
            frozen = paused ? state.history : []
            frozenNow = now
        }
    }

    private(set) var state = CoreState()
    private(set) var now = uptime()
    private(set) var frozen: [Sample] = []
    private(set) var frozenNow: TimeInterval = 0
    /// How many times a second the window actually refreshed, over the last second.
    private(set) var refreshRate = 0

    @ObservationIgnored let core: SteerCore
    @ObservationIgnored private var refreshTimes: [TimeInterval] = []

    private init() {
        let d = UserDefaults.standard
        let base = Tuning()
        let tuning = Tuning(range: d.object(forKey: "range") as? Double ?? base.range,
                            deadzone: d.object(forKey: "deadzone") as? Double ?? base.deadzone,
                            curve: d.object(forKey: "curve") as? Double ?? base.curve,
                            invert: d.object(forKey: "invert") as? Bool ?? base.invert,
                            direct: d.object(forKey: "direct") as? Bool ?? base.direct,
                            keepTurning: d.object(forKey: "keepTurning") as? Bool ?? base.keepTurning,
                            threshold: d.object(forKey: "threshold") as? Double ?? base.threshold,
                            speed: d.object(forKey: "turnSpeed") as? Double ?? base.speed,
                            pedals: d.object(forKey: "pedals") as? Bool ?? base.pedals,
                            pedalDeadzone: d.object(forKey: "pedalDeadzone") as? Double ?? base.pedalDeadzone)
        var bindings: [ButtonAction: Set<String>] = [:]
        for action in ButtonAction.allCases {
            bindings[action] = d.stringArray(forKey: "buttons." + action.rawValue).map(Set.init) ?? action.defaultButtons
        }
        core = SteerCore(port: Engine.port, bindings: bindings, tuning: tuning)
        range = tuning.range
        deadzone = tuning.deadzone
        curve = tuning.curve
        invert = tuning.invert
        direct = tuning.direct
        keepTurning = tuning.keepTurning
        threshold = tuning.threshold
        speed = tuning.speed
        pedals = tuning.pedals
        pedalDeadzone = tuning.pedalDeadzone
        keepOnTop = d.bool(forKey: "keepOnTop")
    }

    private func saved(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        core.setTuning(Tuning(range: range, deadzone: deadzone, curve: curve, invert: invert, direct: direct,
                              keepTurning: keepTurning, threshold: threshold, speed: speed,
                              pedals: pedals, pedalDeadzone: pedalDeadzone))
    }

    func start() {
        core.start()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func shutdown() { core.shutdown() }

    private func refresh() {
        let t = uptime()
        now = t
        refreshTimes.append(t)
        refreshTimes.removeAll { $0 < t - 1 }
        if refreshRate != refreshTimes.count { refreshRate = refreshTimes.count }
        let s = core.snapshot()
        if s.version != state.version { state = s }
    }

    // MARK: For the views

    var latest: Sample? { state.history.last }
    var controllerName: String? { state.controllerName }
    var gyroEnabled: Bool { state.gyroEnabled }
    var simulate: Bool { state.simulate }
    var game: GameStatus { state.game }
    var learning: ButtonAction? { state.learning }
    var learned: Set<String> { state.learned }
    var bindings: [ButtonAction: Set<String>] { state.bindings }
    var notice: String? { now - state.noticeTime < 6 ? state.notice : nil }
    var motionRate: Int { state.history.reduce(0) { $0 + ($1.t > now - 1 ? 1 : 0) } }
    var gameAnswering: Bool { state.game.lastReply.map { now - $0 < 1.5 } ?? false }
    var throttle: Double { state.throttle }
    var brake: Double { state.brake }
    var displayed: [Sample] { paused ? frozen : state.history }
    var displayedNow: TimeInterval { paused ? frozenNow : now }

    func setGyro(_ on: Bool) { core.setGyro(on) }
    func setSimulate(_ on: Bool) { core.setSimulate(on) }
    func recenter() { core.recenter() }
    func learn(_ action: ButtonAction) { core.learn(action) }
    func cancelLearning() { core.learn(nil) }
    func resetButtons(_ action: ButtonAction) { core.resetButtons(action) }

    func label(for action: ButtonAction) -> String { buttonNames(bindings[action] ?? []) }

    /// Button names as printed on the G5 Pro where known (in Switch mode it reports Back as − and Menu as +),
    /// otherwise the controller's own names.
    func buttonNames(_ names: Set<String>) -> String {
        let ordered = names.sorted { (Engine.order.firstIndex(of: $0) ?? 99, $0) < (Engine.order.firstIndex(of: $1) ?? 99, $1) }
        let labels = ordered.map { name in
            Engine.printedNames[name] ?? state.buttonLabels[name] ?? name.replacingOccurrences(of: "Button ", with: "")
        }
        return labels.isEmpty ? "none" : labels.joined(separator: " + ")
    }

    private static let order = [
        GCInputButtonOptions, GCInputButtonMenu, GCInputButtonHome, GCInputLeftThumbstickButton,
        GCInputRightThumbstickButton, GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger, GCInputRightTrigger,
    ]

    private static let printedNames = [
        GCInputButtonOptions: "Back ⧉", GCInputButtonMenu: "Menu ≡", GCInputButtonHome: "Home",
        GCInputLeftThumbstickButton: "L3", GCInputRightThumbstickButton: "R3",
        GCInputLeftShoulder: "LB", GCInputRightShoulder: "RB", GCInputLeftTrigger: "LT", GCInputRightTrigger: "RT",
    ]
}

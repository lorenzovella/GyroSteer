// The tilt maths and the UDP link to the BeamNG mod. No UI here.
//
// Packets to the mod (plain text):
//   "gs1 s=<steering -1..1, positive = right> f=<BeamNG input filter: 1 gamepad, 2 wheel>"
//   "gs1 off"    gyro steering switched off: the mod centres the steering once and stops overriding it
//   "gs1 ping"   no steering, just asking the mod to answer
// The mod answers each batch with "gs1 ack car=<0|1> on=<0|1> [applied=<the car's steering input>]".

import Foundation

// MARK: - Vectors

struct V3 {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static let zero = V3(0, 0, 0)
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, k: Double) -> V3 { V3(a.x * k, a.y * k, a.z * k) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: Double { dot(self).squareRoot() }
    var unit: V3 { let l = length; return l > 1e-9 ? self * (1 / l) : self }
}

/// 3x3 rotation matrix, used to make up sensor data for the simulation and the self-test.
struct M3 {
    var rows: (V3, V3, V3)
    static func rotX(_ t: Double) -> M3 { M3(rows: (V3(1, 0, 0), V3(0, cos(t), -sin(t)), V3(0, sin(t), cos(t)))) }
    static func rotY(_ t: Double) -> M3 { M3(rows: (V3(cos(t), 0, sin(t)), V3(0, 1, 0), V3(-sin(t), 0, cos(t)))) }
    static func * (m: M3, v: V3) -> V3 { V3(m.rows.0.dot(v), m.rows.1.dot(v), m.rows.2.dot(v)) }
    var transposed: M3 {
        let (a, b, c) = rows
        return M3(rows: (V3(a.x, b.x, c.x), V3(a.y, b.y, c.y), V3(a.z, b.z, c.z)))
    }
    static func * (m: M3, n: M3) -> M3 {
        let t = n.transposed
        func row(_ r: V3) -> V3 { V3(r.dot(t.rows.0), r.dot(t.rows.1), r.dot(t.rows.2)) }
        return M3(rows: (row(m.rows.0), row(m.rows.1), row(m.rows.2)))
    }
}

/// What the sensors of a controller held at `pitch` (0 flat, 90° upright like a wheel) and turned `angle` like a
/// wheel would read, in Apple's conventions (flat, face up: accel z = -1 g). `rate` is how fast the angle changes.
func syntheticReading(angle: Double, rate: Double, pitch: Double) -> (accel: V3, gyro: V3) {
    let worldToBody = (M3.rotY(angle) * M3.rotX(pitch)).transposed
    return (worldToBody * V3(0, 0, -1), worldToBody * V3(0, rate, 0))
}

// MARK: - Tilt

/// Tilt of the controller's left-right axis in degrees: 0 when it is level, positive when the right side is lower.
/// It is the same whether the controller is held flat or upright like a wheel.
func rollDeg(_ down: V3) -> Double {
    atan2(down.x, (down.y * down.y + down.z * down.z).squareRoot()) * 180 / .pi
}

/// Tracks which way is down in the controller's own axes. The accelerometer gives it without drift but is noisy
/// and jumps when the controller is shaken; the gyro is fast and smooth but drifts. Each update turns the last
/// estimate by the gyro reading, then pulls it a little toward the accelerometer.
final class TiltFusion {
    /// How quickly the estimate settles onto the accelerometer, in seconds.
    let accelTimeConstant = 0.3
    /// How quickly the gyro's resting offset is learned while the controller is still, in seconds.
    let biasTimeConstant = 3.0
    var onGyroSignFlip: (() -> Void)?

    private(set) var gyroSign = 1.0
    /// What the gyro reads when the controller isn't turning (a few degrees per second on the G5 Pro).
    private(set) var gyroBias = V3.zero
    private var down: V3?
    private var accelSmoothed: V3?
    private var gyroSignSettled = false
    private var agree = 0
    private var disagree = 0

    func reset() {
        down = nil
        accelSmoothed = nil
    }

    /// accel in g (any sign convention), gyro in rad/s around the controller's axes. Returns the roll in degrees.
    func update(accel: V3, gyro: V3, dt rawDt: Double) -> Double {
        let dt = min(max(rawDt, 0), 0.05)
        let measured = accel.unit
        guard let previous = down else {
            down = measured
            accelSmoothed = measured
            return rollDeg(measured)
        }

        // While the controller is still, slowly learn the gyro's resting offset, and always take it off.
        if (gyro - gyroBias).length < 0.1, abs(accel.length - 1) < 0.05 {
            let b = dt / (biasTimeConstant + dt)
            gyroBias = gyroBias * (1 - b) + gyro * b
        }
        let turning = (gyro - gyroBias) * gyroSign

        // A direction fixed in the world, seen from a controller turning at w, changes at (v x w).
        let predicted = (previous + previous.cross(turning) * dt).unit

        // Trust the accelerometer less while the reading is far from 1 g (the controller is being shaken).
        let trust = max(0, 1 - abs(accel.length - 1) * 4)
        let k = trust * dt / (accelTimeConstant + dt)
        let fused = (predicted * (1 - k) + measured * k).unit
        down = fused

        checkGyroSign(previous: previous, predicted: predicted, measured: measured)
        return rollDeg(fused)
    }

    /// If the gyro's sign convention is the opposite of the accelerometer's, the gyro moves the tilt the wrong way.
    /// While the controller turns, compare the direction each sensor says it is turning, and flip the gyro if they
    /// clearly disagree.
    private func checkGyroSign(previous: V3, predicted: V3, measured: V3) {
        guard !gyroSignSettled, let lastAccel = accelSmoothed else { return }
        let accel = (lastAccel * 0.7 + measured * 0.3).unit
        accelSmoothed = accel
        let gyroStep = rollDeg(predicted) - rollDeg(previous)
        let accelStep = rollDeg(accel) - rollDeg(lastAccel)
        guard abs(gyroStep) > 0.25, abs(accelStep) > 0.1 else { return }
        if (gyroStep > 0) == (accelStep > 0) { agree += 1 } else { disagree += 1 }
        guard agree + disagree >= 40 else { return }
        if disagree > 3 * agree {
            gyroSign = -gyroSign
            down = measured
            onGyroSignFlip?()
        } else if agree > 3 * disagree {
            gyroSignSettled = true
        }
        agree = 0
        disagree = 0
    }
}

/// The steering wheel the car gets, in degrees. Up to `threshold` degrees of tilt it follows the controller 1:1.
/// Past that it keeps turning, faster the further the controller is tilted, so full lock can be beyond the 90° a
/// hand can tilt. Back inside the threshold it unwinds smoothly with the tilt and is straight again when the
/// controller is level; starting again from level, it's 1:1 again.
final class VirtualWheel {
    private(set) var angle = 0.0
    /// The wheel angle at the threshold divided by the threshold: 1 until the wheel has kept turning.
    private var gain = 1.0
    private var side = 0.0

    func reset() {
        angle = 0
        gain = 1
        side = 0
    }

    /// `speed` is how fast the wheel keeps turning, in degrees a second, with the controller tilted all the way to
    /// 90°; it scales down to nothing at the threshold. `lock` is the wheel angle at full lock.
    func update(tilt: Double, dt: Double, keepTurning: Bool, threshold: Double, speed: Double, lock: Double) -> Double {
        let s: Double = tilt < 0 ? -1 : 1
        if s != side {
            // Crossed over to the other side: straight was passed, so back to 1:1.
            side = s
            gain = 1
        }
        let tiltSize = abs(tilt)
        guard keepTurning, threshold < lock else {
            gain = 1
            angle = s * min(tiltSize, lock)
            return angle
        }
        if tiltSize > threshold {
            let push = min(1, (tiltSize - threshold) / max(1, 90 - threshold))
            let from = max(angle * s, threshold)
            let size = min(lock, from + speed * push * min(dt, 0.1))
            angle = s * size
            gain = size / threshold
        } else {
            // 1:1 near level, reaching the wheel's kept-turning angle at the threshold.
            let x = tiltSize / threshold
            angle = s * min(lock, threshold * (x + (gain - 1) * x * x))
        }
        return angle
    }
}

/// Maps a wheel angle (degrees from straight) to BeamNG steering: -1 full left ... 1 full right.
func steeringOutput(angle: Double, lock: Double, deadzone: Double, curve: Double) -> Double {
    let dz = min(deadzone, lock - 1)
    let beyond = abs(angle) - dz
    guard beyond > 0 else { return 0 }
    let t = min(1, beyond / (lock - dz))
    return pow(t, curve) * (angle < 0 ? -1 : 1)
}

/// Maps a stick to a pedal, 0...1, by how far it is pushed from the middle in any direction. Inside `deadzone`
/// (0...1 of the stick's travel) it is 0; from there it rises evenly to 1 at the edge. Diagonals can read a little
/// past 1, so the distance is capped.
func pedalOutput(x: Double, y: Double, deadzone: Double) -> Double {
    let distance = min(1, (x * x + y * y).squareRoot())
    let dz = min(max(deadzone, 0), 0.9)
    guard distance > dz else { return 0 }
    return (distance - dz) / (1 - dz)
}

func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

// MARK: - UDP link

final class Link {
    var onReceive: ((String) -> Void)?
    private let fd: Int32
    private var destination = sockaddr_in()
    private var reader: DispatchSourceRead?

    /// Replies from the mod are handed to `onReceive` on `queue`.
    init(port: UInt16, queue: DispatchQueue) {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        destination = Link.address(port: port)
        var local = Link.address(port: 0)
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.resume()
        self.reader = reader
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }

    func send(_ text: String) {
        var to = destination
        _ = text.withCString { bytes in
            withUnsafePointer(to: &to) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, strlen(bytes), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            onReceive?(String(decoding: buffer[0..<n], as: UTF8.self))
        }
    }
}

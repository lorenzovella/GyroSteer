// `GyroSteer --selftest`: checks the tilt maths on made-up sensor data, without a controller or a window.

import Foundation

/// Simulates a controller turned like a wheel while held at different angles, with sensor noise and the G5 Pro's
/// gyro offset, and checks the fused tilt follows the true angle.
func runSelfTest() -> Bool {
    var seed: UInt64 = 42
    func noise(_ size: Double) -> Double {
        var sum = 0.0
        for _ in 0..<4 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            sum += Double(seed >> 11) / Double(1 << 53) - 0.5
        }
        return sum * size
    }
    func noisy(_ v: V3, _ size: Double) -> V3 { v + V3(noise(size), noise(size), noise(size)) }

    var ok = true
    // The G5 Pro's gyro reads about 0.06 rad/s around y while sitting still.
    let restingOffset = V3(0.01, 0.06, -0.02)
    let cases: [(String, Double, Bool, Bool)] = [
        ("held flat", 0, false, false),
        ("tilted up 40°", 40, false, false),
        ("held upright like a wheel", 80, false, false),
        ("gyro with the opposite sign", 30, true, false),
        ("held still in a 20° turn", 30, false, true),
    ]
    for (label, pitchDeg, gyroFlipped, still) in cases {
        let fusion = TiltFusion()
        var flippedAt: Double?
        var t = 0.0
        fusion.onGyroSignFlip = { flippedAt = t }
        let dt = 1.0 / 66
        var worst = 0.0
        while t < 20 {
            // Moving: a mix of slow and quick turns up to 60° each way. Still: a steady 20° turn, after a quick
            // turn in from straight.
            let angle = still ? min(t, 1) * 20 * .pi / 180
                              : (40 * sin(t * 0.9) + 20 * sin(t * 3.1)) * .pi / 180
            let rate = still ? (t < 1 ? 20 * .pi / 180 : 0)
                             : (40 * 0.9 * cos(t * 0.9) + 20 * 3.1 * cos(t * 3.1)) * .pi / 180
            let reading = syntheticReading(angle: angle, rate: rate, pitch: pitchDeg * .pi / 180)
            let accel = noisy(reading.accel, 0.04)
            var gyro = noisy(reading.gyro, 0.04) + restingOffset
            if gyroFlipped { gyro = gyro * -1 }
            let roll = fusion.update(accel: accel, gyro: gyro, dt: dt)
            let settled = gyroFlipped ? (flippedAt.map { t > $0 + 2 } ?? false) : t > (still ? 15 : 2)
            if settled { worst = max(worst, abs(roll - angle * 180 / .pi)) }
            t += dt
        }
        if still {
            let learned = fusion.gyroBias
            let pass = (learned - restingOffset).length < 0.01
            ok = ok && pass
            print("\(pass ? "PASS" : "FAIL")  \(label): learned the gyro's resting offset "
                  + String(format: "(%.3f %.3f %.3f rad/s)", learned.x, learned.y, learned.z))
        }
        let flipOk = gyroFlipped == (flippedAt != nil)
        // The made-up sensor noise is several times the G5 Pro's; both limits stay inside the default dead zone
        // (still) or a hand's wobble (moving).
        let pass = flipOk && worst < (still ? 1 : 3)
        ok = ok && pass
        var detail = String(format: "worst error %.2f°", worst)
        if gyroFlipped { detail += flippedAt.map { String(format: ", flipped after %.1f s", $0) } ?? ", never flipped" }
        else if !flipOk { detail += ", flipped the gyro when it shouldn't have" }
        print("\(pass ? "PASS" : "FAIL")  \(label): \(detail)")
    }

    func check(_ pass: Bool, _ text: String) {
        ok = ok && pass
        print("\(pass ? "PASS" : "FAIL")  \(text)")
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    // Wheel angle -> steering, with full lock at 45° and a 2° dead zone.
    let curveChecks: [(Double, Double)] = [(0, 0), (1.9, 0), (-45, -1), (90, 1), (23.5, 0.5), (20, 18.0 / 43)]
    for (angle, expected) in curveChecks {
        let got = steeringOutput(angle: angle, lock: 45, deadzone: 2, curve: 1)
        check(near(got, expected), "wheel \(angle)° -> steering \(String(format: "%.3f", got)), expected \(String(format: "%.3f", expected))")
    }
    let gentle = steeringOutput(angle: 23.5, lock: 45, deadzone: 2, curve: 2)
    check(near(gentle, 0.25), "curve 2 turns half the wheel into a quarter of the steering (got \(String(format: "%.3f", gentle)))")

    // The wheel: 1:1 up to 60° of tilt, then keeps turning at up to 300°/s, full lock 450°.
    let wheel = VirtualWheel()
    func turn(_ tilt: Double, _ seconds: Double = 0) -> Double {
        var angle = 0.0
        let steps = max(1, Int(seconds * 100))
        for _ in 0..<steps {
            angle = wheel.update(tilt: tilt, dt: seconds / Double(steps), keepTurning: true, threshold: 60, speed: 300,
                                 lock: 450)
        }
        return angle
    }
    check(near(turn(30), 30) && near(turn(60), 60), "up to the threshold the wheel follows the tilt 1:1")
    let held = turn(75, 1)
    check(abs(held - 210) < 0.5, String(format: "held at 75° for 1 s it keeps turning, half speed: 60° -> %.1f° (expected 210°)", held))
    check(near(turn(60), held), "back at the threshold the wheel is where it got to (no jump)")
    let halfway = turn(30)
    check(near(halfway, 67.5), String(format: "halfway back it unwinds smoothly (%.1f°, expected 67.5°)", halfway))
    check(near(turn(0), 0), "level again, the wheel is straight")
    check(near(turn(-30), -30), "the other way, it's 1:1 again")
    check(near(turn(-90, 5), -450), "it stops at full lock")
    _ = turn(0)
    check(near(turn(20), 20), "and starting again from level, it's 1:1 again")
    // Sticks as pedals, with a 5% dead zone: the middle is 0, the edge in any direction is 1.
    check(pedalOutput(x: 0, y: 0, deadzone: 0.05) == 0, "stick in the middle -> pedal 0")
    check(pedalOutput(x: 0.03, y: -0.03, deadzone: 0.05) == 0, "stick inside the dead zone -> pedal 0")
    check(near(pedalOutput(x: 0, y: -1, deadzone: 0.05), 1), "stick pushed to the edge -> pedal 1")
    check(near(pedalOutput(x: -1, y: 0, deadzone: 0.05), 1), "any direction counts: pushed left to the edge -> pedal 1")
    check(near(pedalOutput(x: 0.72, y: 0.72, deadzone: 0.05), 1), "diagonal reading past the edge -> capped at 1")
    let half = pedalOutput(x: 0, y: 0.525, deadzone: 0.05)
    check(near(half, 0.5), String(format: "halfway between dead zone and edge -> %.3f (expected 0.500)", half))

    let plain = VirtualWheel()
    let off = plain.update(tilt: 80, dt: 1, keepTurning: false, threshold: 60, speed: 300, lock: 450)
    check(near(off, 80), "with keep turning off, the wheel just follows the tilt")
    return ok
}

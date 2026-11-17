//! The tilt maths: sensor fusion, the virtual steering wheel, and the steering and pedal curves. No I/O here.
//!
//! Sensor readings use Apple's conventions, which the maths was first written against: accelerometer in g, pointing
//! the way gravity pulls (a controller lying flat, face up, reads z = -1); gyro in rad/s around x (right), y (away
//! from the player) and z (out of the face). `from_sdl` converts SDL's readings.

use std::ops::{Add, Mul, Sub};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl V3 {
    pub const ZERO: V3 = V3 { x: 0.0, y: 0.0, z: 0.0 };

    pub const fn new(x: f64, y: f64, z: f64) -> V3 {
        V3 { x, y, z }
    }
    pub fn dot(self, b: V3) -> f64 {
        self.x * b.x + self.y * b.y + self.z * b.z
    }
    pub fn cross(self, b: V3) -> V3 {
        V3::new(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x)
    }
    pub fn length(self) -> f64 {
        self.dot(self).sqrt()
    }
    pub fn unit(self) -> V3 {
        let l = self.length();
        if l > 1e-9 { self * (1.0 / l) } else { self }
    }
}

impl Add for V3 {
    type Output = V3;
    fn add(self, b: V3) -> V3 {
        V3::new(self.x + b.x, self.y + b.y, self.z + b.z)
    }
}

impl Sub for V3 {
    type Output = V3;
    fn sub(self, b: V3) -> V3 {
        V3::new(self.x - b.x, self.y - b.y, self.z - b.z)
    }
}

impl Mul<f64> for V3 {
    type Output = V3;
    fn mul(self, k: f64) -> V3 {
        V3::new(self.x * k, self.y * k, self.z * k)
    }
}

/// SDL's standard gravity, m/s².
const STANDARD_GRAVITY: f64 = 9.80665;

/// Converts an SDL gamepad reading to the conventions above. SDL's axes, for a controller held in front of you:
/// x right, y up (out of the face when it lies flat), z toward the player; its accelerometer is in m/s² and reads
/// +1 g upward at rest. Checked against Apple's GameController on a Switch Pro controller.
pub fn from_sdl(accel: [f32; 3], gyro: [f32; 3]) -> (V3, V3) {
    let [ax, ay, az] = accel.map(f64::from);
    let [gx, gy, gz] = gyro.map(f64::from);
    (V3::new(-ax, az, -ay) * (1.0 / STANDARD_GRAVITY), V3::new(gx, -gz, gy))
}

/// 3x3 rotation matrix, used to make up sensor data for the simulation and the tests.
#[derive(Clone, Copy)]
struct M3([V3; 3]);

impl M3 {
    fn rot_x(t: f64) -> M3 {
        M3([V3::new(1.0, 0.0, 0.0), V3::new(0.0, t.cos(), -t.sin()), V3::new(0.0, t.sin(), t.cos())])
    }
    fn rot_y(t: f64) -> M3 {
        M3([V3::new(t.cos(), 0.0, t.sin()), V3::new(0.0, 1.0, 0.0), V3::new(-t.sin(), 0.0, t.cos())])
    }
    fn apply(self, v: V3) -> V3 {
        V3::new(self.0[0].dot(v), self.0[1].dot(v), self.0[2].dot(v))
    }
    fn transposed(self) -> M3 {
        let [a, b, c] = self.0;
        M3([V3::new(a.x, b.x, c.x), V3::new(a.y, b.y, c.y), V3::new(a.z, b.z, c.z)])
    }
    fn times(self, n: M3) -> M3 {
        let t = n.transposed();
        let row = |r: V3| V3::new(r.dot(t.0[0]), r.dot(t.0[1]), r.dot(t.0[2]));
        M3([row(self.0[0]), row(self.0[1]), row(self.0[2])])
    }
}

/// What the sensors of a controller held at `pitch` (0 flat, π/2 upright like a wheel) and turned `angle` like a
/// wheel would read (radians). `rate` is how fast the angle changes, rad/s.
pub fn synthetic_reading(angle: f64, rate: f64, pitch: f64) -> (V3, V3) {
    let world_to_body = M3::rot_y(angle).times(M3::rot_x(pitch)).transposed();
    (world_to_body.apply(V3::new(0.0, 0.0, -1.0)), world_to_body.apply(V3::new(0.0, rate, 0.0)))
}

/// Tilt of the controller's left-right axis in degrees: 0 when it is level, positive when the right side is lower.
/// It is the same whether the controller is held flat or upright like a wheel.
pub fn roll_deg(down: V3) -> f64 {
    down.x.atan2((down.y * down.y + down.z * down.z).sqrt()).to_degrees()
}

/// Tracks which way is down in the controller's own axes. The accelerometer gives it without drift but is noisy
/// and jumps when the controller is shaken; the gyro is fast and smooth but drifts. Each update turns the last
/// estimate by the gyro reading, then pulls it a little toward the accelerometer.
#[derive(Default)]
pub struct TiltFusion {
    gyro_sign_flipped: bool,
    /// What the gyro reads when the controller isn't turning (a few degrees per second on some controllers).
    gyro_bias: V3,
    down: Option<V3>,
    accel_smoothed: Option<V3>,
    gyro_sign_settled: bool,
    agree: u32,
    disagree: u32,
}

impl TiltFusion {
    /// How quickly the estimate settles onto the accelerometer, in seconds.
    const ACCEL_TIME_CONSTANT: f64 = 0.3;
    /// How quickly the gyro's resting offset is learned while the controller is still, in seconds.
    const BIAS_TIME_CONSTANT: f64 = 3.0;

    pub fn reset(&mut self) {
        self.down = None;
        self.accel_smoothed = None;
    }

    #[cfg(test)]
    fn gyro_bias(&self) -> V3 {
        self.gyro_bias
    }

    fn gyro_sign(&self) -> f64 {
        if self.gyro_sign_flipped { -1.0 } else { 1.0 }
    }

    /// `accel` in g, `gyro` in rad/s around the controller's axes. Returns the roll in degrees, and whether the
    /// gyro's sign was just found to be backwards (and flipped).
    pub fn update(&mut self, accel: V3, gyro: V3, raw_dt: f64) -> (f64, bool) {
        let dt = raw_dt.clamp(0.0, 0.05);
        let measured = accel.unit();
        let Some(previous) = self.down else {
            self.down = Some(measured);
            self.accel_smoothed = Some(measured);
            return (roll_deg(measured), false);
        };

        // While the controller is still, slowly learn the gyro's resting offset, and always take it off.
        if (gyro - self.gyro_bias).length() < 0.1 && (accel.length() - 1.0).abs() < 0.05 {
            let b = dt / (Self::BIAS_TIME_CONSTANT + dt);
            self.gyro_bias = self.gyro_bias * (1.0 - b) + gyro * b;
        }
        let turning = (gyro - self.gyro_bias) * self.gyro_sign();

        // A direction fixed in the world, seen from a controller turning at w, changes at (v x w).
        let predicted = (previous + previous.cross(turning) * dt).unit();

        // Trust the accelerometer less while the reading is far from 1 g (the controller is being shaken).
        let trust = (1.0 - (accel.length() - 1.0).abs() * 4.0).max(0.0);
        let k = trust * dt / (Self::ACCEL_TIME_CONSTANT + dt);
        let fused = (predicted * (1.0 - k) + measured * k).unit();
        self.down = Some(fused);

        let flipped = self.check_gyro_sign(previous, predicted, measured);
        (roll_deg(fused), flipped)
    }

    /// If the gyro's sign convention is the opposite of the accelerometer's, the gyro moves the tilt the wrong way.
    /// While the controller turns, compare the direction each sensor says it is turning, and flip the gyro if they
    /// clearly disagree.
    fn check_gyro_sign(&mut self, previous: V3, predicted: V3, measured: V3) -> bool {
        if self.gyro_sign_settled {
            return false;
        }
        let Some(last_accel) = self.accel_smoothed else { return false };
        let accel = (last_accel * 0.7 + measured * 0.3).unit();
        self.accel_smoothed = Some(accel);
        let gyro_step = roll_deg(predicted) - roll_deg(previous);
        let accel_step = roll_deg(accel) - roll_deg(last_accel);
        if gyro_step.abs() <= 0.25 || accel_step.abs() <= 0.1 {
            return false;
        }
        if (gyro_step > 0.0) == (accel_step > 0.0) {
            self.agree += 1;
        } else {
            self.disagree += 1;
        }
        if self.agree + self.disagree < 40 {
            return false;
        }
        let mut flipped = false;
        if self.disagree > 3 * self.agree {
            self.gyro_sign_flipped = !self.gyro_sign_flipped;
            self.down = Some(measured);
            flipped = true;
        } else if self.agree > 3 * self.disagree {
            self.gyro_sign_settled = true;
        }
        self.agree = 0;
        self.disagree = 0;
        flipped
    }
}

/// The steering wheel the car gets, in degrees. Up to `threshold` degrees of tilt it follows the controller 1:1.
/// Past that it keeps turning, faster the further the controller is tilted, so full lock can be beyond the 90° a
/// hand can tilt. Back inside the threshold it unwinds smoothly with the tilt and is straight again when the
/// controller is level; starting again from level, it's 1:1 again.
pub struct VirtualWheel {
    angle: f64,
    /// The wheel angle at the threshold divided by the threshold: 1 until the wheel has kept turning.
    gain: f64,
    side: f64,
}

impl Default for VirtualWheel {
    fn default() -> Self {
        VirtualWheel { angle: 0.0, gain: 1.0, side: 0.0 }
    }
}

impl VirtualWheel {
    pub fn reset(&mut self) {
        *self = VirtualWheel::default();
    }

    /// `speed` is how fast the wheel keeps turning, in degrees a second, with the controller tilted all the way to
    /// 90°; it scales down to nothing at the threshold. `lock` is the wheel angle at full lock.
    pub fn update(&mut self, tilt: f64, dt: f64, keep_turning: bool, threshold: f64, speed: f64, lock: f64) -> f64 {
        let s = if tilt < 0.0 { -1.0 } else { 1.0 };
        if s != self.side {
            // Crossed over to the other side: straight was passed, so back to 1:1.
            self.side = s;
            self.gain = 1.0;
        }
        let tilt_size = tilt.abs();
        if !keep_turning || threshold >= lock {
            self.gain = 1.0;
            self.angle = s * tilt_size.min(lock);
            return self.angle;
        }
        if tilt_size > threshold {
            let push = ((tilt_size - threshold) / (90.0 - threshold).max(1.0)).min(1.0);
            let from = (self.angle * s).max(threshold);
            let size = lock.min(from + speed * push * dt.min(0.1));
            self.angle = s * size;
            self.gain = size / threshold;
        } else {
            // 1:1 near level, reaching the wheel's kept-turning angle at the threshold.
            let x = tilt_size / threshold;
            self.angle = s * lock.min(threshold * (x + (self.gain - 1.0) * x * x));
        }
        self.angle
    }
}

/// Maps a wheel angle (degrees from straight) to BeamNG steering: -1 full left ... 1 full right.
pub fn steering_output(angle: f64, lock: f64, deadzone: f64, curve: f64) -> f64 {
    let dz = deadzone.min(lock - 1.0);
    let beyond = angle.abs() - dz;
    if beyond <= 0.0 {
        return 0.0;
    }
    let t = (beyond / (lock - dz)).min(1.0);
    t.powf(curve) * if angle < 0.0 { -1.0 } else { 1.0 }
}

/// Maps a stick to a pedal, 0...1, by how far it is pushed from the middle in any direction. Inside `deadzone`
/// (0...1 of the stick's travel) it is 0; from there it rises evenly to 1 at the edge. Diagonals can read a little
/// past 1, so the distance is capped.
pub fn pedal_output(x: f64, y: f64, deadzone: f64) -> f64 {
    let distance = (x * x + y * y).sqrt().min(1.0);
    let dz = deadzone.clamp(0.0, 0.9);
    if distance <= dz {
        return 0.0;
    }
    (distance - dz) / (1.0 - dz)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    /// Repeatable noise, roughly normal, of about `size`.
    struct Noise(u64);
    impl Noise {
        fn next(&mut self, size: f64) -> f64 {
            let mut sum = 0.0;
            for _ in 0..4 {
                self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                sum += (self.0 >> 11) as f64 / (1u64 << 53) as f64 - 0.5;
            }
            sum * size
        }
        fn v3(&mut self, v: V3, size: f64) -> V3 {
            v + V3::new(self.next(size), self.next(size), self.next(size))
        }
    }

    struct FusionRun {
        worst: f64,
        flipped_at: Option<f64>,
        bias: V3,
    }

    /// Simulates a controller turned like a wheel while held at `pitch_deg`, with sensor noise several times a real
    /// controller's and a G5 Pro's resting gyro offset, and measures how far the fused tilt strays from the truth.
    fn fusion_run(pitch_deg: f64, gyro_flipped: bool, still: bool) -> FusionRun {
        let resting_offset = V3::new(0.01, 0.06, -0.02);
        let mut noise = Noise(42);
        let mut fusion = TiltFusion::default();
        let mut flipped_at = None;
        let mut worst: f64 = 0.0;
        let dt = 1.0 / 66.0;
        let mut t: f64 = 0.0;
        while t < 20.0 {
            // Moving: a mix of slow and quick turns up to 60° each way. Still: a steady 20° turn, after a quick
            // turn in from straight.
            let (angle, rate) = if still {
                ((t.min(1.0) * 20.0).to_radians(), if t < 1.0 { 20f64.to_radians() } else { 0.0 })
            } else {
                (
                    (40.0 * (t * 0.9).sin() + 20.0 * (t * 3.1).sin()).to_radians(),
                    (40.0 * 0.9 * (t * 0.9).cos() + 20.0 * 3.1 * (t * 3.1).cos()).to_radians(),
                )
            };
            let (accel, gyro) = synthetic_reading(angle, rate, pitch_deg.to_radians());
            let accel = noise.v3(accel, 0.04);
            let mut gyro = noise.v3(gyro, 0.04) + resting_offset;
            if gyro_flipped {
                gyro = gyro * -1.0;
            }
            let (roll, flipped) = fusion.update(accel, gyro, dt);
            if flipped && flipped_at.is_none() {
                flipped_at = Some(t);
            }
            let settled = if gyro_flipped {
                flipped_at.is_some_and(|f| t > f + 2.0)
            } else {
                t > if still { 15.0 } else { 2.0 }
            };
            if settled {
                worst = worst.max((roll - angle * 180.0 / PI).abs());
            }
            t += dt;
        }
        FusionRun { worst, flipped_at, bias: fusion.gyro_bias() - resting_offset }
    }

    #[test]
    fn fusion_follows_the_tilt_at_any_pitch() {
        for pitch in [0.0, 40.0, 80.0] {
            let run = fusion_run(pitch, false, false);
            assert!(run.worst < 3.0, "held at {pitch}°: worst error {:.2}°", run.worst);
            assert!(run.flipped_at.is_none(), "held at {pitch}°: flipped the gyro when it shouldn't have");
        }
    }

    #[test]
    fn fusion_flips_a_backwards_gyro() {
        let run = fusion_run(30.0, true, false);
        let at = run.flipped_at.expect("never flipped the gyro");
        assert!(at < 5.0, "flipped only after {at:.1} s");
        assert!(run.worst < 3.0, "worst error {:.2}°", run.worst);
    }

    #[test]
    fn fusion_learns_the_gyro_offset_while_still() {
        let run = fusion_run(30.0, false, true);
        assert!(run.bias.length() < 0.01, "learned offset is off by {:.3} rad/s", run.bias.length());
        assert!(run.worst < 1.0, "worst error {:.2}°", run.worst);
    }

    #[test]
    fn sdl_readings_convert_to_apple_axes() {
        // Lying flat, face up, still: SDL reads +1 g up (y); gravity pulls along -z in Apple's axes.
        let (accel, _) = from_sdl([0.0, 9.80665, 0.0], [0.0; 3]);
        assert!((accel - V3::new(0.0, 0.0, -1.0)).length() < 1e-6);
        // Right side lowered: the tilt reads positive.
        let (accel, _) = from_sdl([-4.9, 8.5, 0.0], [0.0; 3]);
        assert!(roll_deg(accel) > 25.0);
        // Turning like a wheel to the right while held flat is a turn around SDL's -z, Apple's y.
        let (_, gyro) = from_sdl([0.0; 3], [0.0, 0.0, -1.0]);
        assert!((gyro - V3::new(0.0, 1.0, 0.0)).length() < 1e-6);
    }

    #[test]
    fn steering_curve() {
        // Full lock at 45° and a 2° dead zone.
        for (angle, expected) in [(0.0, 0.0), (1.9, 0.0), (-45.0, -1.0), (90.0, 1.0), (23.5, 0.5), (20.0, 18.0 / 43.0)] {
            let got = steering_output(angle, 45.0, 2.0, 1.0);
            assert!(near(got, expected), "wheel {angle}° -> steering {got:.3}, expected {expected:.3}");
        }
        // Curve 2 turns half the wheel into a quarter of the steering.
        assert!(near(steering_output(23.5, 45.0, 2.0, 2.0), 0.25));
    }

    #[test]
    fn wheel_keeps_turning_past_the_threshold() {
        // 1:1 up to 60° of tilt, then keeps turning at up to 300°/s, full lock 450°.
        let mut wheel = VirtualWheel::default();
        let mut turn = |tilt: f64, seconds: f64| {
            let steps = ((seconds * 100.0) as usize).max(1);
            let mut angle = 0.0;
            for _ in 0..steps {
                angle = wheel.update(tilt, seconds / steps as f64, true, 60.0, 300.0, 450.0);
            }
            angle
        };
        assert!(near(turn(30.0, 0.0), 30.0) && near(turn(60.0, 0.0), 60.0), "1:1 up to the threshold");
        let held = turn(75.0, 1.0);
        assert!((held - 210.0).abs() < 0.5, "held at 75° for 1 s: {held:.1}°, expected 210°");
        assert!(near(turn(60.0, 0.0), held), "back at the threshold the wheel is where it got to");
        let halfway = turn(30.0, 0.0);
        assert!(near(halfway, 67.5), "halfway back it unwinds smoothly: {halfway:.1}°, expected 67.5°");
        assert!(near(turn(0.0, 0.0), 0.0), "level again, the wheel is straight");
        assert!(near(turn(-30.0, 0.0), -30.0), "the other way, it's 1:1 again");
        assert!(near(turn(-90.0, 5.0), -450.0), "it stops at full lock");
        turn(0.0, 0.0);
        assert!(near(turn(20.0, 0.0), 20.0), "starting again from level, it's 1:1 again");

        let mut plain = VirtualWheel::default();
        assert!(near(plain.update(80.0, 1.0, false, 60.0, 300.0, 450.0), 80.0), "keep turning off: follows the tilt");
    }

    #[test]
    fn sticks_as_pedals() {
        assert_eq!(pedal_output(0.0, 0.0, 0.05), 0.0, "middle");
        assert_eq!(pedal_output(0.03, -0.03, 0.05), 0.0, "inside the dead zone");
        assert!(near(pedal_output(0.0, -1.0, 0.05), 1.0), "edge");
        assert!(near(pedal_output(-1.0, 0.0, 0.05), 1.0), "any direction");
        assert!(near(pedal_output(0.72, 0.72, 0.05), 1.0), "diagonal past the edge is capped");
        assert!(near(pedal_output(0.0, 0.525, 0.05), 0.5), "halfway between the dead zone and the edge");
    }
}

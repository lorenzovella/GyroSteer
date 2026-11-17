//! The steering path, on its own thread so drawing the window never delays the steering: reads the controller,
//! turns its tilt into steering and its sticks into pedals, sends them to the mod, and keeps a copy of everything
//! for the window to draw.
//!
//! Packets to the mod (plain text, UDP to 127.0.0.1:47731):
//!   "gs1 s=<steering -1..1, positive = right> f=<BeamNG input filter: 1 gamepad, 2 wheel>"
//!   "gs1 off"                      gyro steering switched off: the mod centres the steering once and stops
//!   "gs1 p t=<throttle> b=<brake> f=<filter>"   pedals from the sticks, 0..1
//!   "gs1 mode pedals=<0|1> gyro=<0|1>"           every 0.5 s, so the mod can pause the stick's camera and steering
//!   "gs1 cam hold=<0|1> x=<-1|0|1> y=<-1|0|1>"   the D-pad, while the camera button is held: turns the camera
//!   "gs1 ping"                     nothing to send, just asking the mod to answer
//! The mod answers with "gs1 ack car=<0|1> on=<0|1> [applied=<the car's steering input>] [v=<mod version>]".

use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::link::{Link, PORT};
use crate::pad::{self, Pad, PadEvent, PadId, PadInfo, Sdl};
use crate::tilt::{TiltFusion, V3, VirtualWheel, from_sdl, pedal_output, roll_deg, steering_output, synthetic_reading};

/// Seconds of history kept for the graphs.
pub const WINDOW_SECONDS: f64 = 10.0;
const TICK: f64 = 1.0 / 60.0;

/// Seconds since the app started, on one clock shared by both threads.
pub fn now() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

#[derive(Clone, Copy, Debug)]
pub struct Sample {
    pub t: f64,
    /// Degrees from straight: gyro and accelerometer combined (what steers the car).
    pub tilt: f64,
    /// Degrees from straight from the accelerometer alone, to show what the gyro smooths out.
    pub accel_tilt: f64,
    /// The steering wheel's angle, degrees: follows the tilt, and keeps turning past the threshold.
    pub wheel: f64,
    /// Steering sent to the game, -1...1; None while gyro steering is off.
    pub sent: Option<f64>,
    /// The car's steering input after the game's smoothing, as last reported by the mod.
    pub applied: Option<f64>,
    /// Raw gyro, degrees per second around the controller's x (right), y (forward) and z (out of the face).
    pub gyro: V3,
    /// Raw accelerometer, g.
    pub accel: V3,
}

/// A controller action and the buttons that, pressed together, trigger it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Action {
    Recenter,
    ToggleGyro,
    /// Held, not pressed: while these buttons are down, the D-pad turns the camera.
    CameraHold,
}

impl Action {
    pub const ALL: [Action; 3] = [Action::Recenter, Action::ToggleGyro, Action::CameraHold];

    pub fn title(self) -> &'static str {
        match self {
            Action::Recenter => "Set straight",
            Action::ToggleGyro => "Gyro on/off",
            Action::CameraHold => "Camera: hold, then D-pad",
        }
    }

    pub fn default_buttons(self) -> BTreeSet<String> {
        let names: &[&str] = match self {
            Action::Recenter => &["back", "start"],
            Action::ToggleGyro => &["leftstick", "rightstick"],
            // RB: in BeamNG's default controller map it's only a modifier, while LB is also the clutch.
            Action::CameraHold => &["rightshoulder"],
        };
        names.iter().map(|s| s.to_string()).collect()
    }

    pub fn default_bindings() -> BTreeMap<Action, BTreeSet<String>> {
        Action::ALL.iter().map(|a| (*a, a.default_buttons())).collect()
    }
}

/// The defaults are a setup that drives well; anything changed in the window is saved over them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tuning {
    /// Wheel angle for full lock, degrees each way.
    pub range: f64,
    pub deadzone: f64,
    pub curve: f64,
    pub invert: bool,
    /// Send as a wheel (BeamNG's FILTER_DIRECT) rather than a gamepad.
    pub direct: bool,
    /// Past `threshold` degrees of tilt the wheel keeps turning, at up to `speed` degrees a second.
    pub keep_turning: bool,
    pub threshold: f64,
    pub speed: f64,
    /// The right stick is the throttle and the left stick the brake, by how far each is pushed from the middle.
    pub pedals: bool,
    /// Stick travel ignored around the middle, percent.
    pub pedal_deadzone: f64,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning {
            range: 50.0,
            deadzone: 1.5,
            curve: 1.2,
            invert: false,
            direct: true,
            keep_turning: true,
            threshold: 48.0,
            speed: 350.0,
            pedals: true,
            pedal_deadzone: 10.0,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct GameStatus {
    pub last_reply: Option<f64>,
    pub has_car: bool,
    pub steering: bool,
    pub applied: Option<f64>,
    /// The mod's version, from its replies; None for mods older than 0.3.0, which didn't say.
    pub mod_version: Option<String>,
}

impl GameStatus {
    pub fn answering(&self, now: f64) -> bool {
        self.last_reply.is_some_and(|t| now - t < 1.5)
    }
}

/// Everything the window shows, copied out of the core.
#[derive(Clone, Debug, Default)]
pub struct CoreState {
    pub version: u64,
    pub history: VecDeque<Sample>,
    pub controller: Option<PadInfo>,
    pub center: f64,
    pub gyro_enabled: bool,
    pub simulate: bool,
    pub game: GameStatus,
    pub bindings: BTreeMap<Action, BTreeSet<String>>,
    pub learning: Option<Action>,
    pub learned: BTreeSet<String>,
    pub notice: Option<(String, f64)>,
    /// Pedals from the sticks, 0...1, as last sent to the game.
    pub throttle: f64,
    pub brake: f64,
}

impl CoreState {
    pub fn motion_rate(&self, now: f64) -> usize {
        self.history.iter().rev().take_while(|s| s.t > now - 1.0).count()
    }
}

pub enum Command {
    Tuning(Tuning),
    Gyro(bool),
    Recenter,
    Learn(Option<Action>),
    ResetButtons(Action),
    Simulate(bool),
    Shutdown(Sender<()>),
}

/// The window's handle on the core thread.
pub struct CoreHandle {
    tx: Sender<Command>,
    shared: Arc<Mutex<CoreState>>,
    thread: Option<JoinHandle<()>>,
}

impl CoreHandle {
    pub fn start(tuning: Tuning, bindings: BTreeMap<Action, BTreeSet<String>>) -> CoreHandle {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Mutex::new(CoreState::default()));
        let out = shared.clone();
        let thread = std::thread::Builder::new()
            .name("gyrosteer-core".into())
            .spawn(move || Core::new(tuning, bindings).run(rx, out))
            .expect("can't start the steering thread");
        CoreHandle { tx, shared, thread: Some(thread) }
    }

    pub fn send(&self, command: Command) {
        let _ = self.tx.send(command);
    }

    /// The core's latest state, if it changed since `version`.
    pub fn snapshot_if_newer(&self, version: u64) -> Option<CoreState> {
        let s = self.shared.lock().ok()?;
        (s.version != version).then(|| s.clone())
    }

    /// Hands the steering and pedals back to the game, and stops the thread.
    pub fn shutdown(&mut self) {
        let (done_tx, done_rx) = mpsc::channel();
        self.send(Command::Shutdown(done_tx));
        let _ = done_rx.recv_timeout(Duration::from_secs(1));
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

struct Core {
    state: CoreState,
    tuning: Tuning,
    link: Link,
    fusion: TiltFusion,
    wheel: VirtualWheel,
    pad: Option<Pad>,
    /// Controllers that send no motion data; not tried again until they reconnect.
    rejected: HashSet<PadId>,
    /// The newest accelerometer reading, in SDL's axes; each gyro reading is paired with it.
    last_accel: Option<[f32; 3]>,
    last_sensor_time: Option<u64>,
    last_motion: Option<f64>,
    last_roll: f64,
    last_send: f64,
    last_packet: Option<String>,
    held: HashSet<Action>,
    simulation_start: f64,
    last_pedal_send: f64,
    last_mode_send: f64,
    last_tick: f64,
    published: u64,
    /// The D-pad camera as last sent: held, and which way (x right, y up).
    camera: (bool, i8, i8),
    last_camera_send: f64,
}

impl Core {
    fn new(tuning: Tuning, bindings: BTreeMap<Action, BTreeSet<String>>) -> Core {
        Core {
            state: CoreState { version: 1, gyro_enabled: true, bindings, ..Default::default() },
            tuning,
            link: Link::new(PORT),
            fusion: TiltFusion::default(),
            wheel: VirtualWheel::default(),
            pad: None,
            rejected: HashSet::new(),
            last_accel: None,
            last_sensor_time: None,
            last_motion: None,
            last_roll: 0.0,
            last_send: 0.0,
            last_packet: None,
            held: HashSet::new(),
            simulation_start: now(),
            last_pedal_send: 0.0,
            last_mode_send: 0.0,
            last_tick: 0.0,
            published: 0,
            camera: (false, 0, 0),
            last_camera_send: 0.0,
        }
    }

    fn run(mut self, commands: Receiver<Command>, out: Arc<Mutex<CoreState>>) {
        let sdl = match Sdl::init() {
            Ok(sdl) => Some(sdl),
            Err(e) => {
                self.say(format!("Can't read controllers: {e}"));
                None
            }
        };
        let mut events = Vec::new();
        loop {
            let wait = ((self.last_tick + TICK - now()) * 1000.0).ceil().clamp(1.0, 16.0) as i32;
            match &sdl {
                Some(sdl) => sdl.wait(wait, &mut events),
                None => std::thread::sleep(Duration::from_millis(wait as u64)),
            }
            for event in events.drain(..) {
                self.on_event(event);
            }
            loop {
                match commands.try_recv() {
                    Ok(Command::Shutdown(done)) => {
                        self.shutdown();
                        self.publish(&out);
                        self.pad = None; // closed before SDL shuts down
                        let _ = done.send(());
                        return;
                    }
                    Ok(command) => self.on_command(command),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        self.shutdown();
                        self.pad = None;
                        return;
                    }
                }
            }
            for reply in self.link.receive() {
                self.on_reply(&reply);
            }
            if now() - self.last_tick >= TICK {
                self.last_tick = now();
                self.tick();
            }
            self.publish(&out);
        }
    }

    fn publish(&mut self, out: &Arc<Mutex<CoreState>>) {
        if self.state.version == self.published {
            return;
        }
        if let Ok(mut s) = out.lock() {
            s.clone_from(&self.state);
            self.published = self.state.version;
        }
    }

    fn on_command(&mut self, command: Command) {
        match command {
            Command::Tuning(t) => {
                self.tuning = t;
                self.update_pedals();
                self.send_mode(now());
            }
            Command::Gyro(on) => self.apply_gyro(on),
            Command::Recenter => self.perform(Action::Recenter),
            Command::Learn(action) => {
                self.state.learning = action;
                self.state.learned.clear();
                self.changed();
            }
            Command::ResetButtons(action) => self.set_binding(action, action.default_buttons()),
            Command::Simulate(on) => self.set_simulate(on),
            Command::Shutdown(_) => {}
        }
    }

    fn set_simulate(&mut self, on: bool) {
        if on == self.state.simulate {
            return;
        }
        self.state.simulate = on;
        self.fusion.reset();
        self.wheel.reset();
        self.last_motion = None;
        self.last_sensor_time = None;
        self.simulation_start = now();
        self.changed();
    }

    fn shutdown(&mut self) {
        self.set_camera((false, 0, 0));
        self.link.send("gs1 off");
        self.link.send("gs1 mode pedals=0 gyro=0");
        if self.state.throttle > 0.0 || self.state.brake > 0.0 {
            self.state.throttle = 0.0;
            self.state.brake = 0.0;
            self.send_pedals(now());
        }
    }

    // MARK: Controller

    fn on_event(&mut self, event: PadEvent) {
        let current = self.pad.as_ref().map(Pad::id);
        match event {
            PadEvent::Added(id) => self.attach(id),
            PadEvent::Removed(id) => {
                self.rejected.remove(&id);
                if current == Some(id) {
                    self.detach();
                }
            }
            PadEvent::Sensor { which, gyro, data, timestamp_ns } if current == Some(which) => {
                self.on_sensor(gyro, data, timestamp_ns)
            }
            PadEvent::Input(which) if current == Some(which) => self.on_buttons(),
            _ => {}
        }
    }

    fn attach(&mut self, id: PadId) {
        if self.pad.is_some() || self.rejected.contains(&id) {
            return;
        }
        let Some(pad) = Pad::open(id) else { return };
        if !pad.has_accel() {
            self.say(format!(
                "{} sends no motion data. GyroSteer needs a controller with a gyro, like a Switch Pro, DualShock 4 or \
                 DualSense; some controllers only send it in their Switch mode.",
                pad.info.name
            ));
            self.rejected.insert(id);
            return;
        }
        pad.enable_sensors();
        let name = pad.info.name.clone();
        self.state.controller = Some(pad.info.clone());
        self.pad = Some(pad);
        self.fusion.reset();
        self.wheel.reset();
        self.last_motion = None;
        self.last_sensor_time = None;
        self.last_accel = None;
        self.update_pedals();
        self.send_mode(now());
        self.say(format!("Using {name}"));
    }

    fn detach(&mut self) {
        self.pad = None;
        self.state.controller = None;
        if !self.state.simulate {
            self.link.send("gs1 off");
        }
        self.update_pedals(); // no controller: lets go of both pedals
        self.set_camera((false, 0, 0));
        self.send_mode(now());
        self.last_packet = None;
        self.say("Controller disconnected; steering handed back to the game".into());
        for id in pad::connected() {
            self.attach(id);
        }
    }

    fn on_sensor(&mut self, gyro: bool, data: [f32; 3], timestamp_ns: u64) {
        if self.state.simulate {
            return;
        }
        let has_gyro = self.pad.as_ref().is_some_and(Pad::has_gyro);
        if !gyro {
            self.last_accel = Some(data);
            // Without a gyro, each accelerometer reading is a motion update on its own.
            if !has_gyro {
                let dt = self.motion_dt(timestamp_ns);
                let (accel, _) = from_sdl(data, [0.0; 3]);
                self.process(accel, V3::ZERO, dt);
            }
            return;
        }
        let Some(accel) = self.last_accel else { return };
        let dt = self.motion_dt(timestamp_ns);
        let (accel, gyro) = from_sdl(accel, data);
        self.process(accel, gyro, dt);
    }

    /// Time since the last motion update: from the controller's own timestamps where it has them, as they don't
    /// carry the Bluetooth jitter, otherwise from when the readings arrived.
    fn motion_dt(&mut self, timestamp_ns: u64) -> f64 {
        let previous = self.last_sensor_time.replace(timestamp_ns);
        if let Some(p) = previous.filter(|p| *p > 0 && timestamp_ns > *p) {
            let dt = (timestamp_ns - p) as f64 / 1e9;
            if dt < 0.25 {
                return dt;
            }
        }
        self.last_motion.map_or(0.015, |t| now() - t)
    }

    // MARK: Buttons

    fn on_buttons(&mut self) {
        self.update_pedals();
        let Some(pad) = &self.pad else { return };
        let pressed = pad.pressed();
        if let Some(action) = self.state.learning {
            // Collect everything pressed until all buttons are let go, then save it.
            if !pressed.is_subset(&self.state.learned) {
                self.state.learned.extend(pressed.iter().cloned());
                self.changed();
            }
            if pressed.is_empty() && !self.state.learned.is_empty() {
                let learned = std::mem::take(&mut self.state.learned);
                let count = learned.len();
                self.set_binding(action, learned);
                self.state.learning = None;
                self.held = Action::ALL.into_iter().collect(); // don't fire on the release
                let what = if count == 1 { "button" } else { "buttons" };
                self.say(format!("{} is now on the controller's {what}", action.title()));
            }
            return;
        }
        let hold = self.state.bindings.get(&Action::CameraHold).is_some_and(|c| !c.is_empty() && c.is_subset(&pressed));
        let axis = |minus: &str, plus: &str| pressed.contains(plus) as i8 - pressed.contains(minus) as i8;
        let (x, y) = if hold { (axis("dpleft", "dpright"), axis("dpdown", "dpup")) } else { (0, 0) };
        self.set_camera((hold, x, y));
        for action in [Action::Recenter, Action::ToggleGyro] {
            let Some(combo) = self.state.bindings.get(&action).filter(|c| !c.is_empty()) else { continue };
            let down = combo.is_subset(&pressed);
            if down && !self.held.contains(&action) {
                self.perform(action);
            }
            if down {
                self.held.insert(action);
            } else {
                self.held.remove(&action);
            }
        }
    }

    /// Sends the D-pad camera when it changes.
    fn set_camera(&mut self, camera: (bool, i8, i8)) {
        if camera != self.camera {
            self.camera = camera;
            self.send_camera(now());
        }
    }

    fn send_camera(&mut self, t: f64) {
        let (hold, x, y) = self.camera;
        self.link.send(&format!("gs1 cam hold={} x={x} y={y}", hold as u8));
        self.last_camera_send = t;
    }

    fn set_binding(&mut self, action: Action, buttons: BTreeSet<String>) {
        self.state.bindings.insert(action, buttons);
        self.changed();
    }

    fn perform(&mut self, action: Action) {
        match action {
            Action::Recenter => {
                self.state.center = self.last_roll;
                self.wheel.reset();
                self.say(format!("Straight is now this tilt ({:+.1}° from level)", self.state.center));
            }
            Action::ToggleGyro => self.apply_gyro(!self.state.gyro_enabled),
            Action::CameraHold => {} // held, not pressed: see on_buttons
        }
    }

    fn apply_gyro(&mut self, on: bool) {
        if on == self.state.gyro_enabled {
            return;
        }
        self.state.gyro_enabled = on;
        if !on {
            self.link.send("gs1 off");
            self.last_packet = None;
        }
        self.send_mode(now());
        self.say(if on { "Gyro steering on" } else { "Gyro steering off: the stick steers as usual" }.into());
    }

    /// Tells the mod whether the sticks are pedals right now and whether the gyro steers, so it can pause the
    /// game's stick camera (and, while the gyro steers, the stick's own steering). Repeated every 0.5 s; the mod
    /// restores them if it hears nothing for 2 s.
    fn send_mode(&mut self, t: f64) {
        let pedals = self.tuning.pedals && self.pad.is_some();
        self.link.send(&format!("gs1 mode pedals={} gyro={}", pedals as u8, self.state.gyro_enabled as u8));
        self.last_mode_send = t;
    }

    // MARK: Pedals

    /// Reads the sticks (right = throttle, left = brake) and sends the pedals when they change. Without a
    /// controller, or with the setting off, both are 0.
    fn update_pedals(&mut self) {
        let (mut throttle, mut brake) = (0.0, 0.0);
        if let (true, Some(pad)) = (self.tuning.pedals, &self.pad) {
            let dz = self.tuning.pedal_deadzone / 100.0;
            let (rx, ry) = pad.stick(false);
            let (lx, ly) = pad.stick(true);
            throttle = pedal_output(rx, ry, dz);
            brake = pedal_output(lx, ly, dz);
        }
        // Steps of 0.001, so changes too small to matter don't each send a packet.
        throttle = (throttle * 1000.0).round() / 1000.0;
        brake = (brake * 1000.0).round() / 1000.0;
        if throttle == self.state.throttle && brake == self.state.brake {
            return;
        }
        self.state.throttle = throttle;
        self.state.brake = brake;
        self.send_pedals(now());
        self.changed();
    }

    /// The mod passes each pedal to the car only when it changes (and again while it's held), so at rest the
    /// triggers' own bindings in the game keep working.
    fn send_pedals(&mut self, t: f64) {
        let filter = if self.tuning.direct { 2 } else { 1 };
        self.link.send(&format!("gs1 p t={:.3} b={:.3} f={filter}", self.state.throttle, self.state.brake));
        self.last_pedal_send = t;
    }

    // MARK: Steering

    fn process(&mut self, accel: V3, gyro: V3, dt: f64) {
        let t = now();
        self.last_motion = Some(t);
        let (roll, flipped) = self.fusion.update(accel, gyro, dt);
        if flipped {
            self.say("The gyro turned the opposite way to the accelerometer, so it was flipped".into());
        }
        self.last_roll = roll;
        let tilt = roll - self.state.center;
        let tu = &self.tuning;
        let angle = self.wheel.update(
            if tu.invert { -tilt } else { tilt },
            dt,
            tu.keep_turning,
            tu.threshold,
            tu.speed,
            tu.range,
        );
        let steer = steering_output(angle, tu.range, tu.deadzone, tu.curve);
        let filter = if tu.direct { 2 } else { 1 };
        if self.state.gyro_enabled {
            self.send(format!("gs1 s={steer:.4} f={filter}"), t);
        }

        let game = &self.state.game;
        let applied = if game.answering(t) && game.steering { game.applied } else { None };
        self.state.history.push_back(Sample {
            t,
            tilt,
            accel_tilt: roll_deg(accel.unit()) - self.state.center,
            wheel: angle,
            sent: self.state.gyro_enabled.then_some(steer),
            applied,
            gyro: gyro * 57.29577951308232,
            accel,
        });
        while self.state.history.front().is_some_and(|s| s.t < t - WINDOW_SECONDS) {
            self.state.history.pop_front();
        }
        self.changed();
    }

    fn send(&mut self, packet: String, t: f64) {
        self.link.send(&packet);
        self.last_packet = Some(packet);
        self.last_send = t;
    }

    fn tick(&mut self) {
        let t = now();
        if self.state.simulate {
            self.simulate_step(t);
        }
        self.update_pedals();
        // While a pedal is held, keep it alive: the mod lets go of the pedals if the app goes quiet for 0.5 s.
        if (self.state.throttle > 0.0 || self.state.brake > 0.0) && t - self.last_pedal_send > 0.1 {
            self.send_pedals(t);
        }
        if t - self.last_mode_send > 0.5 {
            self.send_mode(t);
        }
        // While the camera button is held, keep it alive: the mod lets go of it if the app goes quiet for 0.3 s.
        if self.camera.0 && t - self.last_camera_send > 0.1 {
            self.send_camera(t);
        }
        let moving = self.last_motion.is_some_and(|m| t - m < 1.0);
        if let (true, true, Some(packet)) = (self.state.gyro_enabled, moving, self.last_packet.clone()) {
            // A steady hand can go quiet; resend so the mod doesn't give up.
            if t - self.last_send > 0.15 {
                self.send(packet, t);
            }
        } else if t - self.last_send > 0.5 {
            self.link.send("gs1 ping");
            self.last_send = t;
        }
    }

    /// Made-up sensor readings of a controller held tilted up 30° and turned left and right like a wheel, now and
    /// then past 60°.
    fn simulate_step(&mut self, t: f64) {
        let s = t - self.simulation_start;
        let angle = (50.0 * (s * 0.7).sin() + 22.0 * (s * 1.9).sin()).to_radians();
        let rate = (50.0 * 0.7 * (s * 0.7).cos() + 22.0 * 1.9 * (s * 1.9).cos()).to_radians();
        let (accel, gyro) = synthetic_reading(angle, rate, 30f64.to_radians());
        let j = |k: usize| ((t * 1000.0 + k as f64 * 37.0).sin() * 43758.5453).fract() * 0.03 - 0.015;
        let dt = self.last_motion.map_or(TICK, |m| t - m);
        self.process(accel + V3::new(j(1), j(2), j(3)), gyro + V3::new(j(4), 0.05 + j(5), j(6)), dt);
    }

    fn on_reply(&mut self, text: &str) {
        if !text.starts_with("gs1 ack") {
            return;
        }
        let mut fields = BTreeMap::new();
        for part in text.split(' ') {
            if let Some((k, v)) = part.split_once('=') {
                fields.insert(k, v);
            }
        }
        let game = &mut self.state.game;
        game.last_reply = Some(now());
        game.has_car = fields.get("car") == Some(&"1");
        game.steering = fields.get("on") == Some(&"1");
        game.applied = fields.get("applied").and_then(|v| v.parse().ok());
        game.mod_version = fields.get("v").map(|v| v.to_string());
        self.changed();
    }

    fn say(&mut self, text: String) {
        eprintln!("GyroSteer: {text}");
        self.state.notice = Some((text, now()));
        self.changed();
    }

    fn changed(&mut self) {
        self.state.version = self.state.version.wrapping_add(1);
    }
}

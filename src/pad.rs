//! A thin wrapper over SDL3's gamepad API: connections, motion sensors, sticks and buttons. Everything here must be
//! used on the thread that called `Sdl::init`.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString, c_char};

use sdl3_sys::error::SDL_GetError;
use sdl3_sys::events::*;
use sdl3_sys::gamepad::*;
use sdl3_sys::hints::*;
use sdl3_sys::init::*;
use sdl3_sys::joystick::SDL_JoystickID;
use sdl3_sys::sensor::*;
use sdl3_sys::stdinc::SDL_free;

pub type PadId = u32;

pub enum PadEvent {
    Added(PadId),
    Removed(PadId),
    /// A motion reading: `gyro` in rad/s, otherwise the accelerometer in m/s², in SDL's axes. `timestamp_ns` is
    /// when the controller took it (0 if unknown).
    Sensor { which: PadId, gyro: bool, data: [f32; 3], timestamp_ns: u64 },
    /// A button or stick moved.
    Input(PadId),
}

/// SDL, initialised for gamepads only. Shuts SDL down when dropped; drop every `Pad` first.
pub struct Sdl(());

impl Sdl {
    pub fn init() -> Result<Sdl, String> {
        unsafe {
            // The game has the focus while GyroSteer reads the controller in the background.
            SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, c"1".as_ptr());
            if !SDL_Init(SDL_INIT_GAMEPAD) {
                return Err(sdl_error());
            }
        }
        Ok(Sdl(()))
    }

    /// Waits up to `timeout_ms` for something to happen, then collects every event waiting into `out`.
    pub fn wait(&self, timeout_ms: i32, out: &mut Vec<PadEvent>) {
        let mut event: SDL_Event = unsafe { std::mem::zeroed() };
        let mut got = unsafe { SDL_WaitEventTimeout(&mut event, timeout_ms.max(1)) };
        while got {
            if let Some(e) = convert(&event) {
                out.push(e);
            }
            got = unsafe { SDL_PollEvent(&mut event) };
        }
    }
}

impl Drop for Sdl {
    fn drop(&mut self) {
        unsafe { SDL_Quit() }
    }
}

fn convert(event: &SDL_Event) -> Option<PadEvent> {
    let kind = SDL_EventType(unsafe { event.r#type });
    unsafe {
        match kind {
            SDL_EVENT_GAMEPAD_ADDED => Some(PadEvent::Added(event.gdevice.which.0)),
            SDL_EVENT_GAMEPAD_REMOVED => Some(PadEvent::Removed(event.gdevice.which.0)),
            SDL_EVENT_GAMEPAD_SENSOR_UPDATE => {
                let s = &event.gsensor;
                let gyro = s.sensor == SDL_SENSOR_GYRO.0;
                if !gyro && s.sensor != SDL_SENSOR_ACCEL.0 {
                    return None;
                }
                Some(PadEvent::Sensor { which: s.which.0, gyro, data: s.data, timestamp_ns: s.sensor_timestamp })
            }
            SDL_EVENT_GAMEPAD_AXIS_MOTION => Some(PadEvent::Input(event.gaxis.which.0)),
            SDL_EVENT_GAMEPAD_BUTTON_DOWN | SDL_EVENT_GAMEPAD_BUTTON_UP => Some(PadEvent::Input(event.gbutton.which.0)),
            _ => None,
        }
    }
}

fn sdl_error() -> String {
    unsafe { text(SDL_GetError()) }.unwrap_or_else(|| "unknown SDL error".into())
}

unsafe fn text(p: *const c_char) -> Option<String> {
    if p.is_null() { None } else { Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()) }
}

/// The gamepads connected now.
pub fn connected() -> Vec<PadId> {
    let mut count = 0;
    unsafe {
        let ids = SDL_GetGamepads(&mut count);
        if ids.is_null() {
            return Vec::new();
        }
        let list = std::slice::from_raw_parts(ids, count.max(0) as usize).iter().map(|id| id.0).collect();
        SDL_free(ids.cast());
        list
    }
}

/// Which family a controller belongs to, for naming its buttons the way they're printed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Family {
    #[default]
    Generic,
    Xbox,
    PlayStation,
    PlayStation5,
    Nintendo,
}

#[derive(Clone, Debug)]
pub struct PadInfo {
    pub name: String,
    pub family: Family,
    sdl_type: i32,
}

impl Default for PadInfo {
    fn default() -> Self {
        PadInfo { name: String::new(), family: Family::Generic, sdl_type: SDL_GAMEPAD_TYPE_STANDARD.0 }
    }
}

/// An open gamepad. Closed when dropped.
pub struct Pad {
    ptr: *mut SDL_Gamepad,
    id: PadId,
    pub info: PadInfo,
}

impl Pad {
    pub fn open(id: PadId) -> Option<Pad> {
        let ptr = unsafe { SDL_OpenGamepad(SDL_JoystickID(id)) };
        if ptr.is_null() {
            eprintln!("GyroSteer: can't open gamepad {id}: {}", sdl_error());
            return None;
        }
        let name = unsafe { text(SDL_GetGamepadName(ptr)) }.unwrap_or_else(|| "Controller".into());
        let sdl_type = unsafe { SDL_GetGamepadType(ptr) };
        let family = match sdl_type {
            SDL_GAMEPAD_TYPE_XBOX360 | SDL_GAMEPAD_TYPE_XBOXONE => Family::Xbox,
            SDL_GAMEPAD_TYPE_PS3 | SDL_GAMEPAD_TYPE_PS4 => Family::PlayStation,
            SDL_GAMEPAD_TYPE_PS5 => Family::PlayStation5,
            SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO
            | SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT
            | SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT
            | SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR => Family::Nintendo,
            _ => Family::Generic,
        };
        Some(Pad { ptr, id, info: PadInfo { name, family, sdl_type: sdl_type.0 } })
    }

    pub fn id(&self) -> PadId {
        self.id
    }

    pub fn has_accel(&self) -> bool {
        unsafe { SDL_GamepadHasSensor(self.ptr, SDL_SENSOR_ACCEL) }
    }

    pub fn has_gyro(&self) -> bool {
        unsafe { SDL_GamepadHasSensor(self.ptr, SDL_SENSOR_GYRO) }
    }

    pub fn enable_sensors(&self) {
        unsafe {
            SDL_SetGamepadSensorEnabled(self.ptr, SDL_SENSOR_ACCEL, true);
            SDL_SetGamepadSensorEnabled(self.ptr, SDL_SENSOR_GYRO, true);
        }
    }

    fn axis(&self, axis: SDL_GamepadAxis) -> f64 {
        let v = unsafe { SDL_GetGamepadAxis(self.ptr, axis) };
        (f64::from(v) / 32767.0).clamp(-1.0, 1.0)
    }

    /// A stick's position, each axis -1...1.
    pub fn stick(&self, left: bool) -> (f64, f64) {
        if left {
            (self.axis(SDL_GAMEPAD_AXIS_LEFTX), self.axis(SDL_GAMEPAD_AXIS_LEFTY))
        } else {
            (self.axis(SDL_GAMEPAD_AXIS_RIGHTX), self.axis(SDL_GAMEPAD_AXIS_RIGHTY))
        }
    }

    /// SDL's names of the buttons held down now ("back", "start", "leftstick", ...); a trigger pressed past
    /// halfway counts as a button too ("lefttrigger", "righttrigger").
    pub fn pressed(&self) -> BTreeSet<String> {
        let mut down = BTreeSet::new();
        for b in 0..SDL_GAMEPAD_BUTTON_COUNT.0 {
            let button = SDL_GamepadButton(b);
            if unsafe { SDL_GetGamepadButton(self.ptr, button) } {
                if let Some(name) = unsafe { text(SDL_GetGamepadStringForButton(button)) } {
                    down.insert(name);
                }
            }
        }
        for axis in [SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER] {
            if self.axis(axis) > 0.5 {
                if let Some(name) = unsafe { text(SDL_GetGamepadStringForAxis(axis)) } {
                    down.insert(name);
                }
            }
        }
        down
    }
}

impl Drop for Pad {
    fn drop(&mut self) {
        unsafe { SDL_CloseGamepad(self.ptr) }
    }
}

/// Where a button sorts when several are listed: the small middle buttons first, then sticks, shoulders, triggers.
pub fn button_order(name: &str) -> usize {
    const ORDER: [&str; 9] = [
        "back", "start", "guide", "leftstick", "rightstick", "leftshoulder", "rightshoulder", "lefttrigger",
        "righttrigger",
    ];
    ORDER.iter().position(|n| *n == name).unwrap_or(ORDER.len())
}

/// A button's name as printed on this kind of controller.
pub fn button_label(name: &str, pad: &PadInfo) -> String {
    use Family::*;
    let f = pad.family;
    let pick = |nintendo: &str, ps: &str, ps5: &str, xbox: &str, generic: &str| -> String {
        match f {
            Nintendo => nintendo,
            PlayStation => ps,
            PlayStation5 => ps5,
            Xbox => xbox,
            Generic => generic,
        }
        .to_string()
    };
    match name {
        "back" => pick("Minus (−)", "Share", "Create", "View", "Back"),
        "start" => pick("Plus (+)", "Options", "Options", "Menu", "Start"),
        "guide" => pick("Home", "PS", "PS", "Xbox", "Guide"),
        "misc1" => pick("Capture", "Misc", "Mic", "Share", "Misc"),
        "leftstick" => "L3".into(),
        "rightstick" => "R3".into(),
        "leftshoulder" => pick("L", "L1", "L1", "LB", "LB"),
        "rightshoulder" => pick("R", "R1", "R1", "RB", "RB"),
        "lefttrigger" => pick("ZL", "L2", "L2", "LT", "LT"),
        "righttrigger" => pick("ZR", "R2", "R2", "RT", "RT"),
        "dpup" => "D-pad up".into(),
        "dpdown" => "D-pad down".into(),
        "dpleft" => "D-pad left".into(),
        "dpright" => "D-pad right".into(),
        "touchpad" => "Touchpad".into(),
        _ => face_label(name, pad).unwrap_or_else(|| name.to_string()),
    }
}

/// A, B, X, Y, or Cross, Circle, Square, Triangle, from where the button sits.
fn face_label(name: &str, pad: &PadInfo) -> Option<String> {
    let c = CString::new(name).ok()?;
    let button = unsafe { SDL_GetGamepadButtonFromString(c.as_ptr()) };
    if button == SDL_GAMEPAD_BUTTON_INVALID {
        return None;
    }
    let label = unsafe { SDL_GetGamepadButtonLabelForType(SDL_GamepadType(pad.sdl_type), button) };
    let text = match label {
        SDL_GAMEPAD_BUTTON_LABEL_A => "A",
        SDL_GAMEPAD_BUTTON_LABEL_B => "B",
        SDL_GAMEPAD_BUTTON_LABEL_X => "X",
        SDL_GAMEPAD_BUTTON_LABEL_Y => "Y",
        SDL_GAMEPAD_BUTTON_LABEL_CROSS => "Cross",
        SDL_GAMEPAD_BUTTON_LABEL_CIRCLE => "Circle",
        SDL_GAMEPAD_BUTTON_LABEL_SQUARE => "Square",
        SDL_GAMEPAD_BUTTON_LABEL_TRIANGLE => "Triangle",
        _ => return None,
    };
    Some(text.to_string())
}

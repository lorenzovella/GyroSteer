# GyroSteer

Steer in BeamNG.drive by tilting your controller like a steering wheel, with analog gas and brake on the sticks.

![GyroSteer's window: the steering wheel, pedals and button settings on the left; live graphs of the controller's
tilt, the steering sent to BeamNG and the raw sensors on the right](docs/screenshot.png)

BeamNG can't read a controller's gyro, so GyroSteer comes in two parts:

- **The app** reads the controller's tilt and sticks, and sends steering, throttle and brake to the game. Its window
  shows the steering wheel, the pedals, live graphs and the settings. It runs on Windows, macOS and Linux.
- **The mod** receives them inside BeamNG and applies them through the game's normal inputs, so BeamNG's steering
  assists still work. It answers with what the car actually did, which the app graphs.

The two talk over UDP on `127.0.0.1:47731`, so the app has to run on the same computer as the game.

## What you need

- **BeamNG.drive** on Windows or Linux (native or through Proton), or on a Mac through CrossOver or another Wine
  wrapper.
- **A controller with a gyro**: Nintendo Switch Pro Controller or Joy-Cons, Sony DualShock 4 or DualSense, or a
  third-party pad that acts as one of those. The Machenike G5 Pro works in its Switch mode; in PC/Xbox mode it sends
  no motion data.

## Install

Download the app for your computer from the [Releases](https://github.com/lorenzovella/GyroSteer/releases) page.
Each download also contains the mod, `gyro_steer.zip`, which is on the page on its own too.

### 1. The mod

Put `gyro_steer.zip` as it is, still zipped, into BeamNG's `mods` folder, and restart the game. The mods folder is in
BeamNG's user folder, which you can open from the BeamNG launcher. On Windows it is usually
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`. When updating, replace the old `gyro_steer.zip`.

### 2. The app

**Windows.** Unzip `GyroSteer-<version>-Windows.zip` anywhere and run `GyroSteer.exe`. The app isn't signed, so the
first time Windows may say "Windows protected your PC": click **More info**, then **Run anyway**.

**macOS** (11 or newer). Unzip `GyroSteer-<version>-macOS.zip` and move `GyroSteer.app` to Applications. The app
isn't notarized by Apple, so the first time macOS refuses to open it: open **System Settings > Privacy & Security**,
scroll down to the message about GyroSteer, and click **Open Anyway**. If you prefer the Terminal:
`xattr -dr com.apple.quarantine /Applications/GyroSteer.app`.

**Linux** (x86-64). Extract `GyroSteer-<version>-Linux-x86_64.tar.gz` and run `./gyrosteer`. To get a menu entry,
copy `gyrosteer` to `~/.local/bin/`, `gyrosteer.png` to `~/.local/share/icons/` and `gyrosteer.desktop` to
`~/.local/share/applications/`. If the app doesn't see your controller, see [Troubleshooting](#troubleshooting).

## Playing

1. Connect the controller, start BeamNG, and open GyroSteer. Both lights at the top of the window turn green once
   the controller is sending and the game is answering, and "Gyro steering on" pops up in the game.
2. Hold the controller level to drive straight, and tilt it like a wheel to steer.

### Turning the wheel past 90°

You can't tilt a controller more than 90° each way, but a car's steering wheel turns much further. So:

- Up to a tilt you choose (48° by default), the wheel follows the controller exactly, degree for degree.
- Tilt past that and the wheel keeps turning on its own. The further you tilt, the faster it turns, up to full lock.
- Tilt back and the wheel unwinds smoothly with your hand. It's straight again when the controller is level.

To use it, set **Full lock** above the keep-turning tilt, for example 270°, or about 450° like a real car.

### Gas and brake on the sticks

Many controllers' triggers are only on or off (a Switch Pro's are), so GyroSteer turns the sticks into analog
pedals:

- **Right stick: throttle. Left stick: brake.**
- In the middle the pedal is at 0. Push the stick further from the middle, in any direction, and the pedal goes
  further, up to full at the edge.
- The triggers still work too, while the sticks are at rest.
- If the app closes or the controller drops out while a pedal is down, the mod lets go of it within half a second.

While the sticks are pedals, the mod pauses the game's stick camera and, while the gyro steers, the car takes
steering only from GyroSteer. That way pushing a stick for the pedals doesn't swing the camera or steer. The mouse
camera and the triggers keep working. Everything comes back when you switch off **Gas and brake** (or the gyro) in
the window, quit the app, or it stops answering for 2 seconds. Your BeamNG bindings themselves are never changed.

### Camera on the D-pad

Hold the camera button (**RB** by default, **R** on a Switch-style pad) and press the D-pad to turn the camera.
While you hold the button, whatever BeamNG has on the D-pad (by default the radial menu, look back, recover and reset)
pauses, so pressing right to look right doesn't reset your car. Let go and the D-pad works as usual again.

Press the camera button first, then the D-pad: pressed at exactly the same moment, the game may see the D-pad first.

### Controller buttons

| Press | Does |
| --- | --- |
| **Back + Start** together (− and + on a Switch-style pad) | Makes the current tilt count as straight |
| **L3 + R3** together (click both sticks in) | Gyro steering on/off. While off, the stick steers as usual. |
| Hold **RB**, then the D-pad | Turns the camera |

To use other buttons, click **Change** next to the action in the window, press the buttons you want on the
controller, then let go. Pick buttons that aren't bound to anything important in BeamNG: the game sees the presses
too.

## The window

- **Wheel:** turns to the wheel angle. The blue arc around it is the steering sent to the game, from full left to
  full right.
- **Tilt meter:** under the wheel, how far the controller itself is tilted. The darker ends are where the wheel
  keeps turning.
- **Tilt graph:** degrees from straight over the last 10 seconds. The thick line is the gyro and accelerometer
  combined, which is what steers. The thin grey line is the accelerometer alone, to show the jitter the gyro smooths
  out. The shaded band is the dead zone.
- **Steering graph:** what was sent to BeamNG, and what the car's steering input was after the game's smoothing.
- **Raw sensors:** the gyro (turning speed around each of the controller's axes) or the accelerometer.

Hover over a graph to read the values at that moment. **Pause graphs** freezes them.

## Tuning

These are in the window and are saved between runs.

| Setting | Default | What it does |
| --- | --- | --- |
| Full lock | 50° | How far the wheel turns each way for full lock. Less is quicker steering. |
| Keep turning past a tilt | on | Lets the wheel go past the tilt below, up to full lock |
| Keep turning past | 48° | Up to this tilt, the wheel follows the controller exactly |
| Turning speed | 350°/s | How fast the wheel keeps turning with the controller tilted all the way (90°) |
| Dead zone | 1.5° | Tilt ignored around straight |
| Curve | 1.2 | Above 1 makes small tilts gentler, for finer control at speed |
| Steer the other way | off | Flips left and right |
| Send as a wheel, not a gamepad | on | Skips BeamNG's gamepad smoothing and its speed-based steering limit |
| Gas and brake (sticks as pedals) | on | Right stick is the throttle, left stick the brake |
| Stick dead zone | 10% | Stick movement ignored around the middle, so a resting stick is exactly 0 |

## Troubleshooting

- **"BeamNG isn't answering."** The game isn't running, or the mod isn't loaded. Look in BeamNG's log
  (`beamng.log` in the user folder) for `gyroSteer`: a line saying it's "listening for the GyroSteer app" means the
  mod loaded. Only one copy of the mod should be in the mods folder.
- **"The BeamNG mod is an older version."** Install `gyro_steer.zip` from the same release as the app.
- **"No controller."** Check that the controller is connected and, for third-party pads, in a mode that sends motion
  (Switch mode on the G5 Pro). Close Steam, or turn off Steam Input for the controller, if Steam is running: it can
  hold on to the controller.
- **Linux: the controller isn't seen.** The app reads the controller through `/dev/hidraw*`, which needs
  permission. Steam's controller rules (the `steam-devices` package) allow it; otherwise install the rules that come
  with the app:
  `sudo cp 70-gyrosteer.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger`,
  then reconnect the controller.
- **The wheel drifts or isn't straight.** Hold the controller where you want straight and press **Back + Start**.
- **Testing without a controller:** turn on **Simulate a controller** in the window.
- **Buttons are mixed up on a Switch-style pad:** the face buttons come through in Nintendo's layout. Rebind them in
  BeamNG under Options > Controls.

## Status

Tested with a Machenike G5 Pro (Switch mode, Bluetooth) on macOS, with BeamNG 0.40 running through Wine. The Windows
and Linux builds come from the same code but haven't been tried on real hardware yet. Reports are welcome in the
[issues](https://github.com/lorenzovella/GyroSteer/issues).

## Building from source

You need [Rust](https://rustup.rs). By default the app links the SDL3 installed on your computer
(`brew install sdl3`, `apt install libsdl3-dev`, or vcpkg on Windows):

```sh
cargo run                  # the app
cargo run -- --simulate    # with a made-up controller
cargo test                 # the tilt maths
luajit tests/mod_test.lua  # the mod, against stand-ins for the game
```

Release builds compile SDL3 from source and link it in, which needs CMake:

```sh
cargo build --release --no-default-features --features static-sdl
scripts/bundle-macos.sh    # macOS: dist/GyroSteer.app and its zip
scripts/package-mod.sh     # the mod: dist/gyro_steer.zip
scripts/install-mod.sh     # copies the mod, unpacked, into BeamNG's mods folder (set BEAMNG_MODS to choose it)
```

Other options for the app: `--light` or `--dark` forces the theme, and `--snapshot file.png` saves the window after
a few seconds and quits.

### Layout

| Path | What |
| --- | --- |
| `src/tilt.rs` | Sensor fusion, the virtual wheel, and the steering and pedal curves |
| `src/steer.rs` | The steering thread: reads the controller, sends to the mod |
| `src/pad.rs` | SDL3 gamepad access |
| `src/ui.rs` | The window |
| `mod/gyro_steer/` | The BeamNG mod; the protocol is described at the top of `gyroSteer.lua` |
| `packaging/` | Mac bundle, Linux desktop entry and udev rules, icon script |
| `.github/workflows/build.yml` | Builds and tests everything on each push; publishes releases from tags |

### Releasing

1. Set the new version in `Cargo.toml` and in `VERSION` at the top of `mod/gyro_steer/lua/ge/extensions/gyroSteer.lua`
   (the build checks they match), and run `cargo build` to update `Cargo.lock`.
2. Add a section for it at the top of `CHANGELOG.md`, headed `## <version>`.
3. Commit, then tag and push: `git tag v0.3.0 && git push origin main v0.3.0`.

GitHub Actions then builds the mod and the app for Windows, macOS and Linux, and publishes a release with the
changelog section as its notes. A version with a hyphen, like `0.4.0-beta.1`, is published as a pre-release.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

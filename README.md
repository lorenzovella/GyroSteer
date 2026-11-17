# GyroSteer

Steer in BeamNG.drive by tilting the controller like a steering wheel. Built for the Machenike G5 Pro in Switch
mode, on a Mac running BeamNG through the Wineskin wrapper. It should work with any controller that macOS reads
motion from (Switch Pro, DualShock 4, DualSense).

BeamNG can't read a controller's gyro, so this comes in two parts:

- **GyroSteer.app** reads the controller's tilt and sticks, and sends steering, throttle and brake to the game over
  UDP on `127.0.0.1:47731`. Its window shows the steering wheel, the pedals, live graphs, and the settings.
- **The mod** (`mod/gyro_steer/`) receives the values and applies them through the game's normal inputs, so
  BeamNG's gamepad smoothing and steering assists still apply. It answers with what the car actually did, which
  the app graphs.

## Setup (once)

1. Put the G5 Pro in **Switch mode** and pair it in System Settings > Bluetooth. It shows up as "Pro Controller".
   In PC/Xbox mode it doesn't send motion data at all.
2. Run `./install.sh`. It builds GyroSteer.app and copies the mod into the wrapper's `mods/unpacked/gyro_steer`
   folder.

## Each time you play

1. Start BeamNG and open **GyroSteer.app**. Both status lights at the top of the window turn green once the
   controller is sending and the game is answering. "Gyro steering on" also pops up in the game.
2. Hold the controller level to drive straight, and tilt it like a wheel to steer.

### Turning the wheel past 90°

You can't tilt a controller more than 90° each way, but a car's steering wheel turns much further. So:

- Up to a tilt you choose (48° by default), the wheel follows the controller exactly, degree for degree.
- Tilt past that and the wheel keeps turning on its own. The further you tilt, the faster it turns, up to full lock.
- Tilt back inside that range and the wheel unwinds smoothly with your hand. It's straight again when the
  controller is level, and from there it follows your hand exactly again.

To use it, set **Full lock** above the keep-turning tilt, for example 270°, or about 450° like a real car.

### Gas and brake on the sticks

In Switch mode the triggers are only on or off, so GyroSteer turns the sticks into analog pedals:

- **Right stick: throttle. Left stick: brake.**
- In the middle the pedal is at 0. Push the stick further from the middle, in any direction, and the pedal goes
  further, up to 1 at the edge.
- The triggers still work too, while the sticks are at rest.
- If the app closes or the controller drops out while a pedal is down, the mod lets go of it within half a second.

While the sticks are pedals, the mod pauses the game's stick camera, and, while the gyro steers, the stick's own
steering, so pushing a stick for the pedals doesn't swing the camera or steer. The mouse camera and the triggers
keep working; turning the camera with the keyboard pauses too. "Sticks are gas and brake: stick camera paused" pops up in the game when this starts.
Everything comes back when you switch off **Gas and brake** (or the gyro, for the steering) in the window, quit
the app, or it stops answering for 2 seconds. Your BeamNG bindings themselves are never changed.

### Controller buttons

| Press together | Does |
| --- | --- |
| **Back ⧉ + Menu ≡** (the two small buttons either side of Home; Switch mode reports them as − and +) | Makes the current tilt count as straight |
| **L3 + R3** (click both sticks in) | Gyro steering on/off. While off, the stick steers as usual. |

To use other buttons, click **Change** next to the action in the window, press the buttons you want on the
controller, then let go. Pick buttons that aren't bound to anything in BeamNG; the game sees the presses too.

The stick still steers while the gyro is on, but the next tilt reading takes over again.

## The window

- **Wheel:** turns to the wheel angle. The blue arc around it is the steering sent to the game, from full left
  to full right.
- **Tilt meter:** under the wheel, how far the controller itself is tilted. The darker ends are where the wheel
  keeps turning.
- **Tilt graph:** degrees from straight over the last 10 seconds. The thick line is the gyro and accelerometer
  combined, which is what steers. The thin grey line is the accelerometer alone, to show the jitter the gyro
  smooths out. The shaded band is the dead zone, and the two lines mark full lock.
- **Steering graph:** what was sent to BeamNG, and what the car's steering input was after the game's smoothing.
  The gap between the two is the lag the game adds.
- **Raw sensors:** the gyro (turning speed around each of the controller's axes) or the accelerometer (gravity
  and shakes).

Hover over a graph to read the values at that moment. **Pause graphs** freezes them.

## Tuning

These are in the window and are saved between runs:

| Setting | Default | What it does |
| --- | --- | --- |
| Full lock | 50° | How far the wheel turns each way for full lock. Less is quicker steering. |
| Keep turning past a tilt | on | Lets the wheel go past the tilt below, up to full lock |
| Keep turning past | 48° | Up to this tilt, the wheel follows the controller exactly |
| Turning speed | 350°/s | How fast the wheel keeps turning with the controller tilted all the way (90°). It's slower just past the threshold. |
| Dead zone | 1.5° | Tilt ignored around straight |
| Curve | 1.5 | Above 1 makes small tilts gentler, for finer control at speed |
| Steer the other way | off | Flips left and right |
| Send as a wheel, not a gamepad | on | Skips BeamNG's gamepad smoothing and its speed-based steering limit |
| Gas and brake (sticks as pedals) | on | Right stick is the throttle, left stick the brake |
| Stick dead zone | 5% | Stick movement ignored around the middle, so a resting stick is exactly 0 |

## Troubleshooting

- **"BeamNG isn't answering."** The game isn't running, or the mod isn't loaded. Look in BeamNG's log
  (`.../BeamNG.drive/current/beamng.log` in the wrapper) for `gyroSteer`. A line saying it's
  "listening for the GyroSteer app" means the mod loaded.
- **Testing without the controller:** turn on **Simulate a controller** in the window. It turns a made-up
  controller left and right.
- **Buttons are mixed up in Switch mode:** the face buttons come through in Nintendo's layout. Rebind them in
  BeamNG under Options > Controls.
- **Checking the tilt maths:** `GyroSteer.app/Contents/MacOS/GyroSteer --selftest`.

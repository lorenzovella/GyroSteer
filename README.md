# GyroSteer

Steer in BeamNG.drive by tilting the controller like a steering wheel. Built for the Machenike G5 Pro in Switch
mode, on a Mac running BeamNG through the Wineskin wrapper. It should work with any controller that macOS reads
motion from (Switch Pro, DualShock 4, DualSense).

BeamNG can't read a controller's gyro, so this comes in two parts:

- **GyroSteer.app** reads the controller's tilt and sends a steering value to the game over UDP on
  `127.0.0.1:47731`. Its window shows the steering wheel, live graphs, and the settings.
- **The mod** (`mod/gyro_steer/`) receives the value and applies it through the game's normal steering input, so
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

- Up to a tilt you choose (60° by default), the wheel follows the controller exactly, degree for degree.
- Tilt past that and the wheel keeps turning on its own. The further you tilt, the faster it turns, up to full lock.
- Tilt back inside that range and the wheel unwinds smoothly with your hand. It's straight again when the
  controller is level, and from there it follows your hand exactly again.

To use it, set **Full lock** above the keep-turning tilt, for example 270°, or about 450° like a real car.

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
| Full lock | 45° | How far the wheel turns each way for full lock. Less is quicker steering. |
| Keep turning past a tilt | on | Lets the wheel go past the tilt below, up to full lock |
| Keep turning past | 60° | Up to this tilt, the wheel follows the controller exactly |
| Turning speed | 270°/s | How fast the wheel keeps turning with the controller tilted all the way (90°). It's slower just past the threshold. |
| Dead zone | 1.5° | Tilt ignored around straight |
| Curve | 1.0 | Above 1 makes small tilts gentler, for finer control at speed |
| Steer the other way | off | Flips left and right |
| Send as a wheel, not a gamepad | off | Skips BeamNG's gamepad smoothing and its speed-based steering limit |

## Troubleshooting

- **"BeamNG isn't answering."** The game isn't running, or the mod isn't loaded. Look in BeamNG's log
  (`.../BeamNG.drive/current/beamng.log` in the wrapper) for `gyroSteer`. A line saying it's
  "listening for the GyroSteer app" means the mod loaded.
- **Testing without the controller:** turn on **Simulate a controller** in the window. It turns a made-up
  controller left and right.
- **Buttons are mixed up in Switch mode:** the face buttons come through in Nintendo's layout. Rebind them in
  BeamNG under Options > Controls.
- **Checking the tilt maths:** `GyroSteer.app/Contents/MacOS/GyroSteer --selftest`.

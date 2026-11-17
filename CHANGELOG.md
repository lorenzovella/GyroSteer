# Changelog

## Unreleased

- **Reset to defaults** button for the tuning, with a confirmation. Controller buttons keep their own Default
  buttons.
- Settings are saved half a second after each change, not only when the app quits, so they survive a crash or a
  force-quit.
- Patch updates no longer ask you to reinstall the mod: the app only warns when the mod's major or minor version
  differs.

## 0.3.0

First public release.

- **Windows and Linux.** The app was rewritten in Rust on SDL3, so one app now runs on Windows, macOS and Linux. It
  reads motion from Switch Pro, Joy-Con, DualShock 4 and DualSense controllers, and from third-party pads that act
  as one of those (for example the Machenike G5 Pro in Switch mode).
- **Faster motion updates over Bluetooth.** About 66 a second from a Switch Pro-style controller, up from 22.
- **No more steering twitch when braking.** While the sticks are gas and brake, the car takes steering only from
  GyroSteer, so pushing the left stick to brake can't steer, even for a moment.
- **Camera on the D-pad.** Hold a button (RB by default; pick another in the window) and the D-pad turns the camera.
  While you hold it, the game's own D-pad actions (by default the radial menu, look back, recover and reset) pause so
  they don't fire too.
- **Version check.** The window warns if the BeamNG mod and the app don't come from the same release.
- New defaults: curve 1.2, stick dead zone 10%.

## 0.2

Mac-only app (Swift), not released.

- Sticks as pedals: right stick throttle, left stick brake, with the stick camera paused while they're pedals.
- Keep turning past a tilt, for full lock beyond 90°.

# Touch display (HelixScreen)

Under stock the 800×480 touch display runs Anycubic's `K3SysUi`. Under ShedNaja it runs
[HelixScreen](https://github.com/prestonbrown/helixscreen) 1.0.6, a Klipper touch UI talking
to the local Moonraker. It knows the Kobra S1 (printer preset and image) and finds heaters,
fans, sensors and the probe by itself. How it was chosen and brought up:
[history/display-ui-log.md](history/display-ui-log.md).

## First start

On the first boot (empty settings) HelixScreen runs its setup wizard on the display:
touch calibration (tap the targets), printer (auto-detected), Wi-Fi. The touch controller
reports its raw range, not 800×480, so the one-off calibration is needed. The settings
are kept in `/useremain/shednaja/helixscreen/settings.json` and survive updates.
Settings > System > "Reset all settings and restart wizard" starts it again.

Calibration from the display: Settings > Calibration & Tools (input shaper, PID, Z offset,
bed mesh, screws tilt). In Mainsail the macro `SHEDNAJA_SETUP` opens the same steps.

## Hardware

| | |
|---|---|
| Display | `/dev/fb0` (`rockchipdrmfb`), 800×480, 32 bpp; mounted upside down, so the UI runs with a fixed 180° rotation |
| Backlight | `/sys/class/backlight/backlight`, max 255 (PWM1) |
| Touch | FocalTech `fts_ts` on I2C3 @0x38 → `/dev/input/event0` (5 points). The stock DT also has a Hynitron CST836U node (`hyn,7xx` @0x15), for which there is no driver; the panels seen so far are FocalTech |
| Sound | the buzzer through Klipper (`M300`); HelixScreen beeps through Moonraker |

## Package

- `rootfs/package/helixscreen/`: downloads the official static armv7 release
  `helixscreen-ad5m-v<version>.tar.gz` (sha256 pinned) and installs it to `/opt/helixscreen`
  (read-only). The `ad5m` build (Flashforge AD5M: Cortex-A7, 800×480, fbdev) is fully static,
  so it runs on our uClibc rootfs unchanged; a source build would need gcc ≥ 10.
- Pruned to save space: other printers' images, splash images for large panels, Chinese and
  Japanese translations with their CJK fonts (choosing them leaves the UI in English), the
  tracker music (the buzzer plays tones only), `install.sh`.
- `S70helixscreen` starts `helix-launcher.sh` (watchdog + splash, restarts the UI after a
  crash) with: `HELIX_CONFIG_DIR=/useremain/shednaja/helixscreen`,
  `HELIX_DISPLAY_BACKEND=fbdev`, `HELIX_DISPLAY_ROTATION=180`, `HELIX_TOUCH_DEVICE=/dev/input/event0`,
  `MOONRAKER_HOST=127.0.0.1`, **`HELIX_DISABLE_AUTO_UPDATES=1`**. Logs: `/tmp/helixscreen.log`,
  `/tmp/helixscreen-launcher.log` (RAM).
- Before it starts, `/usr/libexec/kobra/helix-defaults` fills in the Kobra fan roles and the
  extra hardware (box fan, air filter fan, controller fan, ACE return sensor) in
  `settings.json`, so "Hardware Health" does not report them as new on every boot.

## Updates

HelixScreen cannot update itself on ShedNaja (`/opt` is read-only), and its update checks are
off (`HELIX_DISABLE_AUTO_UPDATES=1`, the app then reports updates as firmware-managed). A new
HelixScreen version comes with a ShedNaja image: bump `HELIXSCREEN_VERSION` and the hash in
`rootfs/package/helixscreen/` and build.

## Resources

About 16–18 MB RSS. Showing the camera on the display costs CPU (it decodes the MJPEG
stream), which is one reason for the 640×480 camera default ([peripherals.md](peripherals.md#camera)).

## Open points

- The touch driver could report screen pixels (DT/driver fix), which would make the touch
  calibration unnecessary.
- No source build with the SDK toolchain (gcc 8.3); ShedNaja ships the upstream binary
  (GPL-3.0, source at the pinned tag).

# Touch display UI (HelixScreen)

> **Development log, not a how-to.** This page records an experiment or test from the
> development of ShedNaja (the display UI work log, 2026-10-21; the current page is [display-ui.md](../display-ui.md)). Commands, slot names and file paths in it describe the
> setup at that time and can be wrong or **destructive** on a printer installed today (for
> example, writing "the inactive slot" can overwrite the stock fallback). Paths under `dumps/`,
> `logs/` and `build/` refer to unpublished development files. Current documentation:
> [docs/README.md](../README.md).

Under stock firmware the built-in 800×480 touch display is driven by Anycubic's `K3SysUi`, which we do not ship. Under ShedNaja it stays dark unless we run our own Klipper UI. This page records what the hardware and our kernel offer, compares the two candidates, and describes how the chosen one (HelixScreen) is packaged.

**Status (2026-10-21):** HelixScreen 1.0.5 runs on the real display under our OS (slot B, our kernel 5.10.160). It was started by hand from `/useremain`, first directly and then through `S70helixscreen`. It connects to the local Moonraker, auto-detects the printer as "Anycubic Kobra S1", and shows Klipper state. Touch works after the first-run wizard's calibration, as confirmed at the printer. The rootfs with the package is built (see "Build") and **flashed into slot B and booted (2026-10-21 08:05)**: from stock slot A with `tools/flash_slot.sh <printer-ip> - --system build/rootfs/rootfs.squashfs --write` (old `system_b` saved in `dumps/system_b_before_flash_20261021_080404.img`), then reboot. `S70helixscreen` starts the UI by itself. It reaches the main loop and shows "Printer is ready" about 40 s after power-on, goes straight to the home screen (settings kept on `/useremain`) with the 180° rotation and the stored touch calibration, and the person at the printer confirmed that state, temperatures and touch work. RAM after boot with Klipper, Moonraker and the UI: helix-screen 18 MB RSS, 157 MB available.

## What the board and our kernel provide

Read over SSH on the running board:

| | |
|---|---|
| Display | `/dev/fb0` = `rockchipdrmfb` (DRM fbdev emulation), 800×480, 32 bpp. `/dev/dri/card0`, connector `card0-DPI-1` connected. VOP → RGB `simple-panel` as in `docs/kernel-build.md`. |
| Backlight | `/sys/class/backlight/backlight`, max 255 (PWM1). |
| Touch | **FocalTech**, `fts_ts` on I2C3 @0x38, bound, IRQ GPIO0_A1 → `/dev/input/event0` (MT protocol B, 5 slots). |
| Hynitron CST836U | DT node `hyn,7xx` @0x15 exists, but `i2cdetect -y 3` shows nothing at 0x15. This printer has no Hynitron chip, so the missing `hyn_cst7xx` driver does not matter here and **no kernel change was needed**. |
| Panel orientation | The panel is mounted upside down relative to fb0: the UI needs a 180° rotation. HelixScreen's rotation probe found this, and the person at the printer confirmed it. |
| Touch coordinates | The FocalTech driver declares `ABS_MT_POSITION_X 0..1600` and `Y 0..2176`. That is the controller's raw range, not 800×480, and the DT `focaltech,display-coords = <0 0 799 479>` does not change it. HelixScreen therefore asks for a one-off touch calibration (an affine matrix, stored in `settings.json`). |

RAM: 215 MB visible to Linux, about 162 MB available with Klipper and Moonraker running and no UI.

## Candidates

| | [HelixScreen](https://github.com/prestonbrown/helixscreen) | [vibescreen](https://github.com/JuggyMcNutty/vibescreen) |
|---|---|---|
| What it is | Own project, C++17, LVGL 9.5 with XML layouts | Fork of GuppyScreen (dead since 7/2024), C++17, LVGL 8, `lv_drivers` |
| Display / input | fbdev or DRM, evdev, auto-detects resolution, rotation 0/90/180/270 at runtime, touch calibration wizard | fbdev + evdev (`/dev/input/event0` fixed at build time); rotation only `GUPPY_ROTATE` (90°, build time); calibration only with `EVDEV_CALIBRATE` at build time |
| 800×480 | Yes, the "medium" layout is the default | Yes (default asset set; `GUPPY_SMALL_SCREEN` for smaller panels) |
| Moonraker | WebSocket JSON-RPC (libhv), with API key support, auto-discovers heaters, fans, sensors and macros. 80+ printer presets, **including `anycubic_kobra_s1`** | WebSocket JSON-RPC (libhv), with API key support |
| Prebuilt for us | **Yes.** The `ad5m` release (Flashforge AD5M: Cortex-A7, 800×480, fbdev) is a fully static armv7-a hard-float ELF, so it runs on our uClibc rootfs unchanged. | **No.** Releases exist only for MIPS (K1) and aarch64. armv7 would mean our own cross build (CI uses Bootlin musl, static). |
| Build with our toolchain (gcc 8.3, uClibc-ng) | Not attempted. The cross targets use gcc 10+ (`-lstdc++fs` comments say "GCC 10.x"), LVGL 9 + C++17; gcc 8.3/uClibc is not a tested combination. | Possible in principle (the docs say gcc ≥ 7.2), but untested; it vendors libhv, mbedtls, spdlog, wpa_supplicant. |
| RAM | Measured here: **16 MB RSS** (101 MB VSZ) on the home screen. Upstream claims about 15 MB on 32-bit. | Upstream about 15–20 MB (GuppyScreen numbers); not measured here |
| Disk | Release tree 77 MB; 41 MB in our rootfs after pruning, which adds 19 MiB to the xz squashfs | About 8 MB |
| Licence | GPL-3.0-or-later | GPL-3.0 |
| Maturity | 1.0 released (1.0.5 stable, 1.1 betas weekly), 365 stars, 72 forks, CI, tests on 9 platforms including two Cortex-A7 boards | 8 stars, a single maintainer, about 2 months old, "built and tested on my K1 Max" only |

### Recommendation: HelixScreen

The choice is clear-cut, so the package was built without waiting for a separate pick:

- It runs **today** on our board from the official static armv7 build, with no cross-compilation and no toolchain risk. vibescreen would first need an armv7 build of its own.
- It handles our two hardware quirks at runtime: the 180° panel mounting and the non-800×480 touch range. vibescreen handles both only at build time, and has no 180° option at all.
- It already knows the Kobra S1 (printer preset, image) and found all heaters, fans, filament sensors and the probe on its own.
- It is more mature and better maintained. Its 16 MB RSS fits easily in the ~160 MB that is free.

The cost is size: the squashfs grows by 19 MiB, which is why other printers' images are removed from the package (see below).

## Package

- `rootfs/package/helixscreen/`: a generic package that downloads `helixscreen-ad5m-v<version>.tar.gz` (1.0.6 since 2026-10-22) from the GitHub release (sha256 pinned in `helixscreen.hash`) and installs the tree to `/opt/helixscreen`. A post-extract hook deletes the images of every printer except the Kobra S1 (44 MB of 77 MB), the splash images for large and ultrawide panels, the Chinese and Japanese translations with their CJK fonts (`zh.xml`, `ja.xml`, `assets/fonts/cjk`, 5.4 MB), the tracker music in `assets/sounds` (0.9 MB: the sound-settings test tune, the Snake game music and an About-screen easter egg), and the upstream `install.sh`. The language list in the UI still offers 中文/日本語 (it is compiled in); choosing either loads no pack and the UI stays in English. Beeps do not need `assets/sounds`: they are generated tones, sent as `M300` through Moonraker or played on a PWM buzzer, and a tones-only backend skips the music files anyway. `/var/lib/helixscreen` (where the app writes its `settings.json` backups) is a symlink to `/useremain/shednaja/helixscreen/backup`. `S70helixscreen` sets `HELIX_DISABLE_AUTO_UPDATES=1`: `/opt` is read-only, so the app could not install an update anyway, but it still checked GitHub daily and showed "Update Available". With the variable set it treats updates as firmware-managed (no checks, no prompts); new versions come with a ShedNaja image.
- `BR2_PACKAGE_HELIXSCREEN=y` in `rootfs/configs/kobra_s1_defconfig`.
- `rootfs/board/kobra_s1/overlay/etc/init.d/S70helixscreen`: starts after Moonraker (S61) and lighttpd (S62). It runs `helix-launcher.sh`, which starts `helix-watchdog`; the watchdog shows the splash and restarts `helix-screen` after a crash. Environment:
  - `HELIX_DATA_DIR=/opt/helixscreen` (read-only assets), `HELIX_CONFIG_DIR=/useremain/shednaja/helixscreen` (`settings.json`: wizard state, touch calibration, theme), `HELIX_CACHE_DIR=…/cache`
  - `HELIX_DISPLAY_BACKEND=fbdev`, `HELIX_FB_DEVICE=/dev/fb0`, `HELIX_TOUCH_DEVICE=/dev/input/event0`, `HELIX_BACKLIGHT_DEVICE=sysfs`
  - `HELIX_DISPLAY_ROTATION=180` (this also skips the rotation probe)
  - `MOONRAKER_HOST=127.0.0.1`, `MOONRAKER_PORT=7125`
  - Logs: app log `/tmp/helixscreen.log`, launcher/watchdog output `/tmp/helixscreen-launcher.log` (tmpfs, lost on reboot)

On first start with an empty config dir, the first-run wizard runs on the display. It covers touch calibration (tap the targets), the printer (auto-detected) and Wi-Fi (it uses our `wpa_supplicant` control socket). The settings from the hand test are already in `/useremain/shednaja/helixscreen` on the test printer, so it starts straight to the home screen after the flash.

## Build

```bash
BR_OUT=$HOME/kobra/rootfs-out-display bash tools/build_rootfs.sh
```

Result (2026-10-21, `BR_OUT=~/kobra/rootfs-out-display`, fresh output dir): `build/rootfs/rootfs.squashfs` **40.7 MiB** (42 692 608 B, sha256 `9d360e99…9b85`) of the 48 MiB `system_a/b` partition, so **7.3 MiB left**. Without HelixScreen it was 21.7 MiB. `/opt/helixscreen` is 41 MB uncompressed. That image still had Chinese, Japanese and the sounds; dropping them (see "Package") saves about 6.3 MB uncompressed. **That change is prepared in `helixscreen.mk` but not built or flashed yet.** The next candidate after that would be the combined `ui_xml/translations/translations.xml` (1.1 MB, all languages); the app loads only the per-language files at runtime, but whether 1.0.5 needs it at all is not checked.

## Hand test without flashing

```sh
# on the PC
gzip -dc helixscreen-ad5m-v1.0.5.tar.gz | ssh … root@<printer> 'mkdir -p /useremain/shednaja/ui-test && tar -xf - -C /useremain/shednaja/ui-test'
# on the printer: S70helixscreen with DIR=/useremain/shednaja/ui-test/helixscreen
/tmp/S70helixscreen start
```

BusyBox `tar` on the board has no `-z`, so decompress on the PC.

## Open points

- **Touch range in the kernel.** `fts_ts` declares the controller's raw range (0..1600 × 0..2176) instead of 800×480. A DT/driver fix (report in screen pixels, or set `x_max`/`y_max` from `focaltech,display-coords`) would make the calibration step unnecessary and would help any other UI. Not done; HelixScreen's calibration works.
- **Self-update.** HelixScreen's in-app updater cannot write to the read-only `/opt/helixscreen`. Update by bumping `HELIXSCREEN_VERSION` and the hash, then flashing a new rootfs.
- **Sound.** The printer has a buzzer, but where it is wired is not known yet: our Klipper config has no `[output_pin beeper]`/`M300`, and HelixScreen's PWM export on `/sys/class/pwm/pwmchip0` fails with `errno 19`. The UI is therefore silent. Once the buzzer is found, either add a beeper to the Klipper config (HelixScreen then beeps via `M300`) or set `sound.pwm_channel` if it sits on a host PWM pin.
- **No build from source.** We ship the upstream static binary (GPL-3.0: source at the pinned tag). A source build with the SDK toolchain (gcc 8.3/uClibc) was not attempted. If needed, use a newer Buildroot toolchain, or a static musl build like upstream's `k2` target.

## Calibration from the display and from Mainsail (2026-10-21)
HelixScreen has the calibration tools built in: Settings > Calibration & Tools (Input Shaper
with LIS2DW support, PID, Z-offset paper test, Bed Mesh, Screws Tilt), usable at any time;
they send `SHAPER_CALIBRATE`, `PID_CALIBRATE`, `PROBE_CALIBRATE` / `Z_OFFSET_APPLY_PROBE` and
`SAVE_CONFIG`, which all work with our config. Its first-run wizard can be started again with
Settings > System > "Reset all settings and restart wizard" (also resets touch calibration).
For Mainsail, `SHEDNAJA_SETUP` (kobra_macros.cfg) opens a re-runnable dialog with the same steps
(nozzle/bed PID, Z offset, input shaper, bed mesh, Save and restart).


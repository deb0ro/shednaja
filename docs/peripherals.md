# Kobra S1 peripherals under ShedNaja

Step 4 of the own OS: everything on the printer besides motion and heaters, how stock
drives it, and how ShedNaja drives it now.

Sources: stock GoKlipper config `/userdata/app/gk/printer.cfg` (FW 2.7.2.7, eMMC dump
`dumps/emmc_20261020_133010/userdata.img`), stock scripts (`/userdata/app/kenv/run.sh`,
`/userdata/app/gk/start.sh`, `checkUsbStatus.sh`, `/oem/usr/bin/RkLunch.sh`), strings of
`gklib` / `K3SysUi` / `gkcam`, the stock DTB (`analysis/kobra_s1.dts`), boot logs in
`logs/`, the vanilla-klipper Rinkhals app (Kobra-S1/vanilla-klipper-swu, release
2026-06-01) and the live board on slot B (read-only, 2026-10-21).

## Inventory

| Peripheral | Wired to | Stock driver | ShedNaja |
|---|---|---|---|
| **USB hub** GL850G (`05e3:0610`), 4 ports | SoC USB2 host (DWC3) via a USB switch on **GPIO1_B1 = gpio41** (host board) | `kenv/run.sh`: `echo 1 > gpio41/value` ("usb sel"); `checkUsbStatus.sh` also unbinds/rebinds `xhci-hcd.0.auto` 3 s after start and again if `/dev/ttyACM0` is missing | `S25kobra-usb` sets gpio41 = 1. Without it nothing on USB ever enumerates (that was the case on slot B until now) |
| **Camera** SunplusIT "Integrated Camera" `13d3:784b`, UVC 1.00 | hub port 3 (`1-1.3`) → `/dev/video0` (+ `/dev/video1` metadata node) | `gkcam` (V4L2 capture, Rockchip MPP/rockit encoders: H.264 cloud stream, JPEG snapshots, NPU "AI detect" spaghetti check, timelapse). Rinkhals runs mjpg-streamer on :8080 | **mjpg-streamer** (`input_uvc` + `output_http`) on 127.0.0.1:8080, `S65webcam`, settings in `printer_data/config/webcam.conf`; lighttpd `/webcam/` → Moonraker `[webcam kobra_s1]` → Mainsail / HelixScreen. See "Camera" below |
| **Chamber light** (LED strip) | host **GPIO3_C5 = gpio117**, active high | GoKlipper `[led_pin] gpio:117` (sysfs) | Klipper Linux MCU: `[output_pin chamber_light] pin: host:gpiochip3/gpio21`, macros `LIGHT_ON/OFF/TOGGLE` (`kobra_peripherals.cfg`) |
| **Buzzer** | host **PWM0** (`pwmchip0/pwm0`, pin GPIO1_A2, pinctrl state "active" applied on enable) | `[pause_resume] bee_path: /sys/class/pwm/pwmchip0/pwm0/enable`; K3SysUi toggles `enable` with `sleep 1` | `[output_pin beeper] pin: host:pwmchip0/pwm0` (hardware PWM, fixed tone), `M300 P<ms>` |
| MCU reset | host **GPIO3_C4 = gpio116** (+ gklib also toggles **gpio118** = GPIO3_C6 together with it) | gklib (`echo 0/1 > gpio116/118/value`) | `S60klipper` pulses gpio116 before klippy starts (unchanged, step 2). gpio118 is not driven: both MCUs come up fine without it; its role (second reset / boot pin?) is unverified |
| Part-cooling fan | nozzle MCU **PB6** (HW PWM) | `[fan]` | `[fan]` in `kobra_s1.cfg` (same pin) |
| Hotend fan | nozzle MCU **PB9** | `[heater_fan extruder_fan]` | same |
| Controller (board) fan | main MCU **PB5** | `[controller_fan]` | same |
| Chamber circulation fan ("box fan") | main MCU **PC6** (HW PWM, 30 kHz) | `[fan_generic box_fan]` with a 10-step pwm_table | `[fan_generic box_fan]`; `M106 P2` maps to it |
| Air filter fan | main MCU **PC7** (HW PWM) | `[fan_generic air_filter_fan]` | `[fan_generic air_filter_fan]`; `M106 P3` is on the ignore list of the vanilla M106 macro (use `SET_FAN_SPEED FAN=air_filter_fan`) |
| Toolhead filament runout switch | nozzle MCU **PB0**, **analog** swing-piece board below the extruder gears: ~2.66 V with filament fed through, ~2.93 V without (both logic high) | `[filament_hub] switch_pin` (read as ADC) | `[adc_filament_switch filament_runout_nozzle]` (`extras/adc_filament_switch.py`, threshold 2.78 V ± 0.04 V, `present_above: False`, 0.5 s debounce); a plain `[filament_switch_sensor]` always reports "detected" |
| Filament cutter switch | nozzle MCU **PB1** | `[filament_hub] cutter_pin` | not configured (only the ACE flow needs it) |
| ACE return detection module (RDM, back of printer): presence switch + encoder | main MCU **PB0** (switch, read as ADC) + **PB1** (encoder) | `[filament_tracker]` (pre-feed detection, "stuck"/entangle detection by encoder length) | `[filament_switch_sensor filament_runout_rdm]` (switch only); `[filament_tracker]` alternative commented in `printer_KS1.cfg` |
| Accelerometer LIS2DW12 | nozzle MCU SPI2, CS **PB12** | `[lis2dw12]` | same (SHAPER_CALIBRATE, step 2) |
| Load cell CS1237 (probe, nozzle-block/clog detection) | nozzle MCU PA5/PA6/PA7 | `[cs1237]` | same (`probe_ks1`) |
| **ACE Pro** multi-colour unit | USB CDC-ACM on the hub → `/dev/ttyACM*` (stock searches `/dev/serial/by-id`, `ttyACM0/1`, `ttyUSB0/1`); v1 115200 baud JSON, v2 230400 baud | GoKlipper `[filament_hub]` | packaged driver **Kobra-S1/ACEPRO V0.8.1**, inactive until enabled. See "ACE Pro" below |
| USB stick | hub port (front) | K3SysUi watches `/sys/class/block/sda`, RkLunch links `/media/usb0` | kernel has usb-storage/exFAT; no automount yet (follow-up) |
| Display 800×480 RGB + touch (FocalTech / CST836U) | SoC VOP + I2C3 | K3SysUi (Qt) | HelixScreen (step 3) |
| Wi-Fi / BT RTL8723DS | SDIO / UART1 | stock modules | step 1/2 |
| Power-loss recovery | no detection input found (`[output_pin power_pin] PB4` is commented out in stock) | software only: `enable_continue_print`, GoKlipper writes `ac_app/postion_record` and `last_z` while printing | not implemented. Plan: Klipper `[save_variables]` + a resume macro (e.g. the community "klipper power loss recovery" approach); no hardware support needed |
| Door sensor | none: no pin in the stock config, no matching string in gklib/K3SysUi | — | — |
| Unknown host input | K3SysUi has a `QGpioWatcher` that sets some gpio to `in` (number built at runtime) | — | not identified; candidates are a button or a supply monitor |

Pins with "MCU" are on the Klipper MCUs (main = GD32 on `/dev/ttyS3`, nozzle = toolhead MCU on
`/dev/ttyS5`). Host GPIO numbers are sysfs numbers: bank × 32 + line, e.g. gpio117 =
`gpiochip3` line 21 = GPIO3_C5.

## USB: the missing "usb sel" GPIO

On the first ShedNaja boots `lsusb` showed only the root hub, also after an xHCI unbind/bind.
The boot log of our kernel with the stock userspace (`logs/bootlog_ourkernel_slotB_20261020.log`)
showed the hub at 5.98 s, right after `/userdata/app/kenv/run.sh` ran. That script exports
gpio41 and drives it high before anything else ("# usb sel"). Doing the same on the running
board brought up the hub and the camera immediately:

```
1-1     05e3:0610  USB2.0 Hub
1-1.3   13d3:784b  SunplusIT Inc / Integrated Camera   -> /dev/video0, /dev/video1
```

`S25kobra-usb` does this at boot, before the Wi-Fi modules (S30) and long before klippy (S60),
so the ACE Pro's `/dev/ttyACM0` exists when Klipper starts. The stock xHCI rebind workaround
(`checkUsbStatus.sh`) is not copied; add it only if an ACE ever fails to enumerate.

## Camera

- Kernel: UVC is built in (`CONFIG_USB_VIDEO_CLASS=y`, `uvcvideo: Found UVC 1.00 device
  Integrated Camera (13d3:784b)`), no module needed.
- The camera delivers **MJPEG** itself (`input_uvc: Format: JPEG`). At 1280×720 it runs at
  30 fps whatever is requested (`FPS coerced from 15 to 30`); frames are about 200–270 kB.
  mjpg-streamer stays at ~0 % CPU and ~9 MB RSS. A continuous `?action=stream` is 4–7 MB/s,
  which is why the Moonraker entry uses `mjpegstreamer-adaptive` (Mainsail polls snapshots at
  `target_fps`). The `UVCIOC_CTRL_ADD/MAP ... Inappropriate ioctl` lines at start are
  mjpg-streamer probing Logitech extension controls and are harmless.
- Streamer choice: mjpg-streamer (Buildroot package, jacksonliam `5a6e0a2`) rather than
  ustreamer: no transcoding is needed, it is not in this Buildroot version, and it pulls in
  libevent. Installed: `mjpg_streamer` 17 kB + `input_uvc.so` + `output_http.so` +
  libjpeg-turbo (the other plugins, the www pages, the jpeg tools and libturbojpeg are removed
  by `kobra-webcam`).
- Build fix: Buildroot's mjpg-streamer links the executable without `-rdynamic` with the
  CMake it builds, and `input_uvc.so` then fails to load (`symbol 'parse_resolution_opt':
  can't resolve symbol`). `kobra-webcam.mk` adds `-DCMAKE_ENABLE_EXPORTS=ON` to
  `MJPG_STREAMER_CONF_OPTS`.
- Path: `S65webcam` waits up to 10 s for `/dev/video0` and starts
  `mjpg_streamer -i "input_uvc.so -d /dev/video0 -r 1280x720 -f 15" -o "output_http.so -l 127.0.0.1 -p 8080"`
  (values from `printer_data/config/webcam.conf`). lighttpd proxies `^/webcam/` to it with
  `map-urlpath /webcam/ → /`, so the URLs are `/webcam/?action=stream` and
  `/webcam/?action=snapshot` on port 80. Moonraker `[webcam kobra_s1]` (16:9, 15 fps target)
  makes Mainsail and HelixScreen list it.

Verified on the board (slot B, 2026-10-21) without restarting any service: gpio41 → hub +
camera enumerate; mjpg-streamer from `/tmp` streams; a second lighttpd from `/tmp` on port
8081 with the new `/webcam/` block returned `200 image/jpeg` for the snapshot and a
`multipart/x-mixed-replace` stream (98 frames in 5 s over Wi-Fi). Moonraker accepted a
webcam entry with these URLs and Mainsail listed it (the entry was removed again). The
picture in Mainsail itself could not be checked: the app's built-in browser refuses ports
other than the printer's port 80, where the running lighttpd does not have the new block yet.

## Host-board pins in Klipper: `[mcu host]`

Light and buzzer are on the host SoC, which vanilla Klipper cannot reach from klippy. The
standard way is Klipper's "Linux MCU": package `klipper-host-mcu` builds `out/klipper.elf`
(`CONFIG_MACH_LINUX`) from the same pinned Klipper source as klippy and installs it as
`/usr/bin/klipper_mcu`; `S59klipper-mcu` exports `pwmchip0/pwm0` and starts it with
`-r -I /tmp/klipper_host_mcu` before `S60klipper`. `kobra_peripherals.cfg` (included from
`printer.cfg`) declares `[mcu host]`, the light and the buzzer.

The reported MCU version is the fork's `CONFIG_FIRMWARE_VERSION` (`v2.0.11`), the same
scheme as the printer MCUs. `S59klipper-mcu` also sets the PWM polarity to `normal`: after a
sysfs export it can read back `inverse`, which would keep the buzzer line high at duty 0.

Verified on the board with `klipper_mcu` from `/tmp` and klippy's `console.py`:
`config_digital_out pin=gpiochip3/gpio21 value=1` switched the light on (camera snapshots with
light on/off: 270 kB vs 231 kB, visibly lit bed), `update_digital_out value=0` off, and
`set_pwm_out pin=pwmchip0/pwm0 cycle_ticks=20000 value=16384` gave
`pwm-0: enabled period 400000 ns duty 200000 ns` (2.5 kHz, 50 %) with the pin muxed to
`pwm0m0`. Whether the buzzer is loud enough at 2.5 kHz was not checked by ear; change
`cycle_time` in `[output_pin beeper]` if another tone is better. klippy itself was not
restarted, so the `[mcu host]` section is checked only by this protocol test.

## ACE Pro

No ACE Pro was connected to the test printer (no `/dev/ttyACM*` after the hub came up), so
nothing here is tested with hardware.

Options looked at:
- **Kobra-S1/ACEPRO** (GPL-3.0, tag V0.8.1 = `2d20ef9`, 2026-07-14): the driver the
  Kobra-S1 vanilla-klipper Rinkhals app ships (its `acepro.patch` is generated from this
  fork), written against the same Kobra-S1 Klipper fork we run. Pure Python (`extras/ace/`,
  `temperature_ace.py`, `virtual_pins.py`), needs only pyserial (already there for klippy).
  Supports ACE 1 (JSON, 115200) and ACE 2 (230400), several units, RFID, dryer, endless spool,
  runout via the existing `filament_runout_nozzle` / `filament_runout_rdm` sensors. It finds
  the ports with `serial.tools.list_ports` and sorts them by USB location, so `/dev/ttyACM0`
  vs `ttyACM1` does not matter. Its configs expect the vanilla-klipper macro set
  (`TO_THROW_POSITION`, `CUT_TIP`, `FLUSH_POOP`, `VEL_PUSH`, `PURGE_IN_CHUNKS`, ...); ACEPRO
  V0.8.1 ships those two files (`printer_KS1.cfg`, `printer_generic_macros.cfg`, identical to
  vanilla 2026-06-01). Since 2026-10-21 ShedNaja no longer uses them (plain Klipper macros in
  `kobra_macros.cfg`, see docs/rootfs-build.md "Plain Klipper configuration").
- DuckACE / ACEResearch (the earlier community drivers) were not evaluated further: ACEPRO is
  the maintained KS1-specific one and already matches our Klipper fork and macros.

So it was straightforward and is **packaged** (`kobra-acepro`): the extras go into
`/usr/lib/klipper/klippy/extras` (compiled like klippy), `ace_KS1.cfg` and
`ace_macros_generic.cfg` become printer_data defaults. It stays **inactive**: nothing includes
`ace_KS1.cfg`. Most printers have no ACE, its `ACE_Pro` switch defaults to "on" (ACE feeding),
and its behaviour without a unit was not tested.

To use an ACE Pro:
1. Connect it to the USB port on the back (it shows up as `/dev/ttyACM0`, `dmesg`: cdc_acm).
2. **Not ready on ShedNaja's own macros:** ACEPRO's `ace_KS1.cfg` calls the vanilla macros
   listed above, which `kobra_macros.cfg` does not have. Either port those calls to
   `kobra_macros.cfg` (`_PARK_BIN`, `_KNOCK_OFF`, `_WIPE_NOZZLE`, `CUT_TIP`; a follow-up), or
   use ACEPRO's own `printer_KS1.cfg` + `printer_generic_macros.cfg` instead of
   `kobra_s1.cfg` + `kobra_macros.cfg` (keep `printer.cfg`'s MCU ports) and add
   `[include ace_KS1.cfg]`. Its slicer start G-code is then `G9111 ...` again.
3. `FIRMWARE_RESTART`, then `ACE_STATUS` / the ACE panel commands from the ACEPRO README.

Not included: ACEPRO's Moonraker component + web dashboard (`ace_status_integration`) and its
KlipperScreen panels (we run HelixScreen). The stock cutter switch (`nozzle_mcu:PB1`) is only
needed if `CUT_TIP` should check it; it is not configured.

## Image size

`tools/build_rootfs.sh` with `BR_OUT=~/kobra/rootfs-out-periph` (not flashed):

| | squashfs | left in the 48 MiB slot |
|---|---|---|
| before (main, ea54246) | 47 226 880 B (45.0 MiB) | 3.0 MiB |
| with step 4 | 47 677 440 B (45.5 MiB) | 2.5 MiB |

+440 kB compressed. Installed (uncompressed) per package: kobra-acepro 1 161 kB (source +
.pyc), jpeg-turbo 243 kB, mjpg-streamer 83 kB, klipper-host-mcu 47 kB, kobra-webcam 1 kB.
It fits. If space gets tight later, the cheapest cuts are: ACEPRO without the `.py` sources
(only `.pyc`, about −0.15 MiB compressed), Mainsail source maps (`*.map`), and further
HelixScreen assets (it is 39 MB uncompressed, by far the largest package).

## Existing printers (config already in printer_data)

`printer-data-init` only copies default files that do not exist yet. On a printer that already
has `printer_data/config`:
- `kobra_peripherals.cfg`, `webcam.conf`, `ace_KS1.cfg`, `ace_macros_generic.cfg` appear
  automatically on the next boot.
- Add `[include kobra_peripherals.cfg]` to `printer.cfg` (in the defaults since the plain Klipper configuration).
- Add the `[webcam kobra_s1]` section from the default `moonraker.conf` to yours, or add the
  camera in Mainsail (Settings → Webcams, stream URL `/webcam/?action=stream`, snapshot URL
  `/webcam/?action=snapshot`).

## Not done / follow-ups

- Stock camera features not ported: H.264 cloud stream, NPU spaghetti detection, timelapse
  (`[timelapse]` snap position 47,275). moonraker-timelapse would need ffmpeg (several MB).
- USB stick automount (`/media/usb0`) for printing from a stick.
- Power-loss resume (software only, see table).
- gpio118 and the K3SysUi input GPIO are not identified.

## Toolhead filament sensor is analog (2026-10-21)

With `[filament_switch_sensor filament_runout_nozzle] switch_pin: nozzle_mcu:PB0` the sensor
always reported "detected", also with `^` (pull-up). Read through the ADC (temporary
`[adc_temperature]` on PB0) it switches between **2.89 V (filament in)** and **2.67 V (out)**,
both above the MCU's logic-high level. Our module `extras/adc_filament_switch.py` (rootfs
overlay) compares the ADC voltage with `threshold` ± `hysteresis`, drives Klipper's
RunoutHelper and registers itself also as `filament_switch_sensor <name>`, so the existing
runout/insert macros, Mainsail, HelixScreen and the ACE driver keep working. Verified with
the user: insert/remove toggles the state (2.89/2.67 V) and the insert prompt appears.

Not done: the ACE return detection module (main MCU PB0, `filament_runout_rdm`) is probably
analog too (stock reads it via ADC; it stayed "not detected" during the test). The fork's
`filament_tracker` ADC mode calls the old ADC API (`setup_adc_callback(report_time, cb)`)
and would fail with the current `mcu.py`; measure the RDM voltages before switching it to
`adc_filament_switch` (with `present_above` as needed).

**Correction (2026-10-21, after the first print):** the polarity above was wrong. The
first hand test (2.89 V "in", 2.67 V "out") mixed up states while the filament was pushed
by hand. Anycubic's wiki ("Material break detection board") shows a spring-loaded swing
piece; it sits below the extruder gears. Measured: whole first print with filament 2.66 V
(also after cooling to 68 °C, so not temperature); filament pulled out 2.93 V; pushed only up
to the gears still 2.93 V; after `LOAD_FILAMENT` (fed through by the extruder) 2.665 V. So
present = low voltage: `present_above: False`. The wrong polarity caused a false runout pause
in the first print (resumed with the sensor disabled).

## Camera frame rate (2026-10-21)
Mainsail showed about 10 fps. Measured: the camera itself sends about 20 fps (on the board,
1280x720: 20.2 fps, 5.3 MB/s); the printer's Wi-Fi carries about 3.4 MB/s, so a 1280x720
stream reaches the PC with 11-12 fps (~250 kB frames), and Mainsail's `mjpegstreamer-adaptive`
mode (snapshot polling) only 5-10 fps. Over Wi-Fi: 640x480 20.1 fps (2.06 MB/s, ~100 kB
frames), 960x720 12.6-16 fps, 1280x720 11.3 fps; 800x600 / 1024x576 are not offered (fallback
to 640x480 / 960x720). Defaults now: `WEBCAM_RESOLUTION=640x480`, `WEBCAM_FPS=30` and the
Moonraker webcam `service: mjpegstreamer` (continuous stream, `target_fps: 30`,
`aspect_ratio: 4:3`): 20.0 fps at 2.04 MB/s on the PC.

**Update (same day): Wi-Fi power saving was the real limit.** The camera's JPEG quality is
fixed (the "JPEG quality" control belongs to mjpg-streamer's YUYV encoder; `Sharpness 0`
saves only ~5 %), and on the board the 1280x720 stream runs at 20 fps / 5 MB/s, but the
throughput to the PC varied between 1.7 and 4.6 MB/s. The RTL8723DS driver ran with
`rtw_power_mgnt=2`, `rtw_ips_mode=1`. Reloaded with both 0: pings 1-27 ms (40/40, before up
to 605 ms), 640x480 steady 20 fps, 1280x720 15-20 fps for one viewer (seen in Mainsail; a
second parallel stream halves it). Now `/etc/modprobe.d/kobra-wifi.conf` sets both to 0 and
the default is back to 1280x720 (16:9). Disabling "Exposure, Auto Priority" made the camera
drop to ~7 fps (the control stays set until the stream restarts), so it is left on.

**But: CPU.** With the 1280x720 stream, `CUT_TIP` twice shut the printer down during its
homing: `MCU 'mcu' shutdown: Timer too close`. The CPU was at 100 % (0 % idle, load 4.3):
HelixScreen ~45 % (it shows the Moonraker webcam on the display and decodes the stream) and
Moonraker ~45 %, so klippy did not get the CPU in time. Fixes: klippy now starts with
`nice -10` and Moonraker with `nice 5` (`S60klipper` / `S61moonraker`, start-stop-daemon
`-N`), and the camera default is back to 640x480 (4:3). With both, load dropped to ~2.5 and
klippy uses ~9 %. 1280x720 can still be set in `webcam.conf`, at the cost of display CPU.


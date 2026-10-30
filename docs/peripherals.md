# Peripherals

Everything on the printer besides motion and heaters: how stock drives it and how
ShedNaja drives it. The investigation and measurements behind this page:
[history/peripherals-log.md](history/peripherals-log.md).

## Current state

| Peripheral | ShedNaja | Status |
|---|---|---|
| Camera (UVC, MJPEG) | mjpg-streamer, **640×480, 15 fps**, 4:3, continuous MJPEG stream in Mainsail and HelixScreen | works |
| Chamber light | `LIGHT_ON` / `LIGHT_OFF` / `LIGHT_TOGGLE` | works |
| Buzzer | `M300 [P<ms>]` (fixed tone) | works |
| Fans | part, hotend, controller, box (`M106 P2`), air filter (`M106 P3`) | works |
| Toolhead filament sensor (analog) | `[adc_filament_switch filament_runout_nozzle]`: pause on runout, load on insert, then `RESUME` | works (runout during a print tested 2026-10-22) |
| ACE return module (RDM) switch | `[filament_switch_sensor filament_runout_rdm]` | configured, not tested (no ACE) |
| Accelerometer LIS2DW12 | `SHAPER_CALIBRATE` on the printer | works |
| Load cell CS1237 | Z probe (`probe_ks1`) | works |
| **ACE Pro** | **not supported yet.** The Kobra-S1/ACEPRO driver is packaged but inactive and not integrated with ShedNaja's macros | see below |
| Wi-Fi | stock Wi-Fi settings, power saving off | works |
| Bluetooth | `hci0` comes up; no bluez tools, nothing uses it | controller only |
| USB stick | kernel support (FAT, exFAT, MBR/GPT) for USB updates; no automount for printing | partial |
| Power-loss recovery | `[kobra_plr]`: state saved at every layer change, `RESUME_INTERRUPTED` after a power cut | works (tested 2026-10-22) |

## Inventory

| Peripheral | Wired to | Stock driver | ShedNaja |
|---|---|---|---|
| USB hub GL852G (`05e3:0610`, marking on U11), 4 ports | SoC USB2 host via a USB switch on **gpio41** (GPIO1_B1) | `kenv/run.sh` drives gpio41 high ("usb sel") | `S25kobra-usb` sets gpio41 = 1; without it nothing on USB enumerates |
| Camera SunplusIT `13d3:784b`, UVC | hub port 3 → `/dev/video0` | `gkcam` (H.264 cloud, snapshots, NPU spaghetti detection, timelapse) | mjpg-streamer `S65webcam` → lighttpd `/webcam/` → Moonraker `[webcam kobra_s1]` |
| Chamber light | host **gpio117** (GPIO3_C5), active high | GoKlipper `[led_pin]` | `[output_pin chamber_light] pin: host:gpiochip3/gpio21` (Klipper Linux MCU) |
| Buzzer | host **PWM0** (GPIO1_A2) | `bee_path` (PWM enable) | `[output_pin beeper] pin: host:pwmchip0/pwm0`, `M300` |
| MCU reset | host **gpio116** (GPIO3_C4); stock also toggles gpio118 | gklib | `S60klipper` pulses gpio116 before klippy starts; gpio118 is not needed |
| Part-cooling fan | nozzle MCU **PB6** (HW PWM) | `[fan]` | same |
| Hotend fan | nozzle MCU **PB9** | `[heater_fan extruder_fan]` | same |
| Controller fan | main MCU **PB5** | `[controller_fan]` | same |
| Box (chamber circulation) fan | main MCU **PC6** (HW PWM) | `[fan_generic box_fan]` | same, `M106 P2` |
| Air filter fan | main MCU **PC7** (HW PWM) | `[fan_generic air_filter_fan]` | same, `M106 P3` |
| Toolhead filament sensor | nozzle MCU **PB0**, analog: about 2.66 V with filament fed through the extruder, 2.93 V without | `[filament_hub]` (ADC) | `[adc_filament_switch]`, threshold 2.78 V, `present_above: False`, 0.5 s debounce. Filament that only reaches the gears is not detected |
| Filament cutter switch | nozzle MCU **PB1** | `[filament_hub] cutter_pin` | not configured |
| ACE return module (RDM) | main MCU **PB0** (switch, probably analog) + **PB1** (encoder) | `[filament_tracker]` | switch only |
| Accelerometer LIS2DW12 | nozzle MCU SPI2, CS **PB12** | `[lis2dw12]` | same, `spi_bus: spi2` |
| Load cell CS1237 | nozzle MCU PA5/PA6/PA7 | `[cs1237]` | same, `probe_ks1` |
| ACE Pro | USB CDC-ACM on the hub (`/dev/ttyACM*`) | GoKlipper `[filament_hub]` | see "ACE Pro" |
| Display + touch | VOP + I2C3 | K3SysUi | HelixScreen ([display-ui.md](display-ui.md)) |
| Power-loss detection | no input found | software only (position records) | state saved ahead of time per layer (`kobra_plr`) |
| Door sensor | none | — | — |

Host GPIO numbers are sysfs numbers: bank × 32 + line (gpio117 = `gpiochip3` line 21).
The host pins reach Klipper through the Klipper Linux MCU (`[mcu host]`, `S59klipper-mcu`).

## Filament runout during a print

Tested 2026-10-22 with a PETG print: filament cut above the toolhead. The sensor went from
2.66 V to 2.86 V ("absent"), Klipper paused the print within the 0.5 s debounce and parked
the toolhead (`_RUNOUT`, mainsail.cfg PAUSE), the nozzle stayed at print temperature. New
filament pushed in read "present" at 2.66 V about 30 s later, `_INSERT` loaded it, and
`RESUME` continued the print from the same file position and it went on printing (the
print was then ended by a deliberate power cut, which led to the power-loss recovery below).

## Power-loss recovery

The printer has no power-fail input, so `kobra_plr` (klippy/extras/kobra_plr.py, `[kobra_plr]`
and the `RESUME_INTERRUPTED` / `CLEAR_INTERRUPTED` macros in `kobra_macros.cfg`) saves the
print state ahead of time: at every layer change (`SET_PRINT_STATS_INFO CURRENT_LAYER=`,
written by the ShedNaja OrcaSlicer profile) it writes the file and the position of the next
line, the G-code position and modes, temperatures, fans, pressure advance, the bed mesh and
the object list to `printer_data/power_loss_recovery.json` (temp file, fsync, rename). A
completed or cancelled print removes it, and so does starting a new print.

After a power cut the display shows "Interrupted print" and Mainsail a dialog (Resume /
Later / Discard). `RESUME_INTERRUPTED`:
1. heats the bed, takes the saved Z, lowers the bed 5 mm, homes X and Y above the print;
2. purges into the bin (`PURGE=`, default 15 mm) and wipes the nozzle while it cools to
   140 °C;
3. probes the bed 40 mm next to the print and corrects Z by the difference to the saved mesh
   (`PROBE=0` skips this; a correction over 3 mm stops the resume). Without it a cut during a
   layer leaves Z off by the mesh compensation or a z-hop;
4. heats to print temperature over the wiper, restores the state and continues the file
   from the start of the interrupted layer.

Tested 2026-10-22: a PETG cube cut off at layer 15; Z corrected by +0.24 mm, the resumed
layer joined the print cleanly. Limits: the print must still stick to the cooled bed; a
print that covers almost the whole bed leaves no spot to probe (the saved Z is used); the
layer info comes only from slicers that call `SET_PRINT_STATS_INFO CURRENT_LAYER`.

## Camera

- The camera delivers MJPEG itself; mjpg-streamer only forwards it (about 0 % CPU).
- Defaults (`printer_data/config/webcam.conf`): `WEBCAM_RESOLUTION=640x480`, `WEBCAM_FPS=15`.
  Moonraker `[webcam kobra_s1]`: `service: mjpegstreamer` (continuous stream; the adaptive
  mode polls snapshots and got only 5–10 fps), `target_fps: 15`, `aspect_ratio: 4:3`.
- URLs on port 80: `/webcam/?action=stream`, `/webcam/?action=snapshot`.
- 1280×720 (16:9) works and can be set in `webcam.conf`, but with HelixScreen decoding the
  stream on the display the single CPU core reached 100 % and klippy shut down with
  `Timer too close` during a print preparation. 640×480 at 15 fps keeps the load low.
- Wi-Fi power saving is off: with it the stream stalled with 600 ms latency spikes.

## ACE Pro

**Not supported yet.** No ACE Pro has been connected to a ShedNaja printer.

The image contains the Kobra-S1/ACEPRO driver V0.8.1 (`kobra-acepro`: Klipper extras,
`ace_KS1.cfg`, `ace_macros_generic.cfg` in the default config), but nothing includes
`ace_KS1.cfg`, so it is inactive. It is not integrated: its configs call the vanilla-klipper
macros (`TO_THROW_POSITION`, `FLUSH_POOP`, `VEL_PUSH`, …), which ShedNaja's
`kobra_macros.cfg` does not have, and its behaviour without a unit is untested. Making it
work means porting those calls to `kobra_macros.cfg` (TODO). Until then a multi-colour
G-code fails at its first `T<n>` (unknown command); single-filament prints do not use it.

## Existing printers

The Klipper config ShedNaja maintains (`kobra_s1.cfg`, `kobra_macros.cfg`,
`kobra_peripherals.cfg`, `mainsail.cfg`) comes with the image in `/usr/share/shednaja/klipper`
(read-only, shown in Mainsail as `config/shednaja/`), and `printer.cfg` includes it from there,
so updates bring its fixes. To change something, override it in `printer.cfg` below the
includes. `printer.cfg`, `moonraker.conf` and `webcam.conf` are the owner's: copied once,
never overwritten; compare them with `/usr/share/shednaja/printer_data/config/` after an
update.

Images before this copied the four files into `printer_data/config` and included them by
name. At every boot `kobra-config-migrate --auto` (from `printer-data-init`) switches each
include whose copy is unmodified (its sha256 is one a ShedNaja image shipped,
`rootfs/board/kobra_s1/klipper_config/known-versions.sha256`) to the image's file and moves
the copy and the old `printer.cfg` into `config/backup-<n>/` (numbered; with the date,
`backup-<n>-<date>-<time>`, when the clock is set, which at boot it usually is not yet). A
copy you edited stays in use without updates (the kernel log says so): move your changes
into `printer.cfg`, then run `kobra-config-migrate --force` over SSH.

## Not done

- Stock camera features: H.264 cloud stream, NPU spaghetti detection, timelapse.
- USB stick automount for printing from a stick.
- ACE Pro integration.

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
| Toolhead filament sensor (analog) | `[adc_filament_switch filament_runout_nozzle]`, pauses on runout, insert detection | sensor works; a full runout-and-resume during a print is **not tested yet** |
| ACE return module (RDM) switch | `[filament_switch_sensor filament_runout_rdm]` | configured, not tested (no ACE) |
| Accelerometer LIS2DW12 | `SHAPER_CALIBRATE` on the printer | works |
| Load cell CS1237 | Z probe (`probe_ks1`) | works |
| **ACE Pro** | **not supported yet.** The Kobra-S1/ACEPRO driver is packaged but inactive and not integrated with ShedNaja's macros | see below |
| Wi-Fi | stock Wi-Fi settings, power saving off | works |
| Bluetooth | `hci0` comes up; no bluez tools, nothing uses it | controller only |
| USB stick | kernel support (FAT, exFAT, MBR/GPT) for USB updates; no automount for printing | partial |
| Power-loss recovery | — | not implemented |

## Inventory

| Peripheral | Wired to | Stock driver | ShedNaja |
|---|---|---|---|
| USB hub GL850G (`05e3:0610`), 4 ports | SoC USB2 host via a USB switch on **gpio41** (GPIO1_B1) | `kenv/run.sh` drives gpio41 high ("usb sel") | `S25kobra-usb` sets gpio41 = 1; without it nothing on USB enumerates |
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
| Power-loss detection | no input found | software only (position records) | — |
| Door sensor | none | — | — |

Host GPIO numbers are sysfs numbers: bank × 32 + line (gpio117 = `gpiochip3` line 21).
The host pins reach Klipper through the Klipper Linux MCU (`[mcu host]`, `S59klipper-mcu`).

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

`printer-data-init` copies only default files that do not exist yet, so on a printer that
was set up with an older image new default files appear, but changes to existing ones
(`printer.cfg`, `moonraker.conf`, `kobra_*.cfg`) do not. Compare with
`/usr/share/shednaja/printer_data/config/` and merge by hand (TODO: split shipped and user
config).

## Not done

- Stock camera features: H.264 cloud stream, NPU spaghetti detection, timelapse.
- USB stick automount for printing from a stick.
- Power-loss resume (software only; no detection input).
- ACE Pro integration.

# ShedNaja documentation

## Current

| Page | What |
|---|---|
| [update.md](update.md) | A/B slots, the USB installer, updates over SSH and USB, going back to stock, what to do if ShedNaja does not start |
| [rootfs-build.md](rootfs-build.md) | building the system image; what runs, where files and settings live, the Klipper configuration |
| [kernel-build.md](kernel-build.md) | building the kernel, boot image and oem image; device tree, Wi-Fi/BT modules, boot logo |
| [mcu.md](mcu.md) | MCU firmware: ShedNaja uses the Anycubic v1.4.3 and does not flash the MCUs |
| [peripherals.md](peripherals.md) | camera, light, buzzer, fans, sensors, ACE Pro: status and pins |
| [display-ui.md](display-ui.md) | HelixScreen on the touch display |
| [hardware.md](hardware.md) | boards, chips, serial console, SWD |
| [firmware-analysis.md](firmware-analysis.md) | the stock firmware: boot chain (no secure boot), kernel, device tree, MCU flash layout |

Installing and the build overview are in the main [README](../README.md); open items in
[TODO.md](../TODO.md).

## History

[history/](history/) holds the development logs: experiments and tests in the order they
happened, with the setup of that time. **They are not instructions.** Commands in them
assume board states that no longer exist and can overwrite the stock fallback slot on a
printer installed today.

| Page | What |
|---|---|
| [history/phase0.md](history/phase0.md) | first access to the test boards: UART, SWD, eMMC backup (Czech) |
| [history/test-board-access.md](history/test-board-access.md) | SSH on a spare host board through a backup + Wi-Fi USB package and Rinkhals |
| [history/console-test.md](history/console-test.md) | finding the serial console on J1 |
| [history/kernel-build-log.md](history/kernel-build-log.md) | how the kernel config and DT were derived, first boots |
| [history/rootfs-build-log.md](history/rootfs-build-log.md) | rootfs steps 1–4, first boots, bugs found on the printer |
| [history/peripherals-log.md](history/peripherals-log.md) | USB hub, camera, host pins, filament sensor, camera frame rate |
| [history/display-ui-log.md](history/display-ui-log.md) | choosing and bringing up the display UI |
| [history/mcu-flash-test.md](history/mcu-flash-test.md) | MCU firmware experiments (do not repeat for an install) |

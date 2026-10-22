# MCU firmware

The Kobra S1 has two Klipper MCUs: the main MCU on the motion board (`mcu`, `/dev/ttyS3`)
and the toolhead MCU (`nozzle_mcu`, `/dev/ttyS5`), both 576000 Bd.

**ShedNaja does not flash the MCUs.** It runs with the Anycubic MCU firmware **v1.4.3** that
the stock firmware 2.7.2.7 installs on both of them. Install ShedNaja without touching the
MCUs; going back to stock needs no MCU change either.

## Check the version

Mainsail → Machine → system info, or in `klippy.log`:

```
Loaded MCU 'mcu' ... ("v1.4.3" / ...)
Loaded MCU 'nozzle_mcu' ... ("v1.4.3" / ...)
```

Under ShedNaja, Klipper logs `MCU 'mcu' (Anycubic stock firmware "v1.4.3") lacks feature
'STEPPER_STEP_BOTH_EDGE'` at info level: v1.4.3 is an older Klipper code base, and the
host works with it (our patch `rootfs/package/klipper/0002-*` turns the "recompile and
flash" warning into this log line).

The official 2.7.2.7 update carries this image, and the development printer ran v1.4.3
before any experiment. How stock decides to flash it is not known. If your printer shows
another version under stock 2.7.2.7, it is untested with ShedNaja.

## About v1.4.3

- Klipper-based (`stm32f103xe` build, 120 MHz, USART1 576000 Bd), 67 commands, one image
  for both MCUs. It includes Anycubic's commands for the CS1237 load cell, the LIS2DW12
  accelerometer, OTA and the board-ID page.
- The file `firmware_v1.4.3_20260303.bin` is in the official update; `tools/fetch_stock.sh`
  extracts it and its data dictionary (`build/stock/firmware_v1.4.3.dict`, used by the
  offline check).
- Layout: Anycubic IAP bootloader at 0x08000000, application at 0x08008000, OTA staging
  and record above it, board-ID page at 0x0801F800 (must never be erased). Details:
  [firmware-analysis.md](firmware-analysis.md).
- With v1.4.3 the LIS2DW12 works only on hardware SPI (`spi_bus: spi2`, as in
  `kobra_s1.cfg`); software SPI reads 0xff.

## Earlier experiments

During development both MCUs ran the community Klipper fork's v2.0.12 and the toolhead MCU
our v2.0.13 (CS1237 calibration commands ported from Anycubic's firmware). Those were
experiments: their flow/PA calibration was never verified, the v2.0.13 sources and
binaries are not published, and the printer went back to v1.4.3 with the stock OTA. The
log: [history/mcu-flash-test.md](history/mcu-flash-test.md).

# Phase 2 – Klipper MCU firmware on the motion board (test board, SWD)

## Build
- Source: `Kobra-S1/klipper-kobra-s1`, branch `Kobra-S1-Dev`, commit in `build/mcu/SOURCE_COMMIT`. Built in WSL Ubuntu 24.04 with `./build.sh --clean` (arm-none-eabi-gcc 13.2).
- Config `build/mcu/kobra_s1_mcu.config`: STM32F103 (stm32f103xe), 8 MHz crystal, **120 MHz** (like the community v2.0.12 and Anycubic 1.4.3; the stock 1.4.0 on the test board ran at 72 MHz), USART1 PA10/PA9 @ **576000**, `INITIAL_PINS=PB4`, app at **0x08008000**, APP2 0x08012000, factory 0x0801C000, OTA record 0x0801E000.
  The serial pins, baud rate and initial pin match the stock dictionary.
- Output: `build/mcu/klipper.bin` = `firmware_v2.0.11_20261020.bin`, 37 793 B (APP1 slot is 40 960 B). Vector table SP 0x20005000, reset 0x0800B791.
- Compared with the stock v1.4.0 dictionary, the build is **missing** `cs1237_calibration_phase`, `cs1237_calibration_DataProcess`, `overflow_cs1237`, `pcba_read/write`, `usart_test`. It adds the vanilla `i2c_*`, `debug_*`, `config_reset`, `spi_set_sw_bus`. So flow/PA auto-calibration will not work (known in the fork).

## Flashing over SWD (APP1 only)
`tools/swd/gd32_flash_app.cfg`: connect-under-reset → erase only the pages of the image inside APP1 → write → verify. The bootloader, OTA areas, OTA record and board-ID page are not touched.
```
openocd -c "set PROBE cmsis-dap" -c "set IMG build/mcu/klipper.bin" -f tools/swd/gd32_flash_app.cfg -c "flash_app"
```
Hold P7 pad 5 (NRST) to pad 2 (GND) until `RELEASE NRST NOW` is printed.

Going back to stock: same command with `IMG=build/mcu/stock_v1.4.0_app1.bin` (APP1 from the dump, 27 289 B). The full 128 KB dump is in `dumps/mcu_ur_20261020_111219_flash.bin`.

## Test
1. Test lower board on the bench, 24 V, Debug Probe on P7 → flash → verify.
2. Communication check without the printer: CH340 (3.3 V) on **P6** (TX1/RX1 = USART1 PA9/PA10, GND) at 576000 Bd. Klipper's `scripts/console.py` (or our helper) should get the `identify` response and the dictionary `v2.0.11`.
3. Only then: test lower board in the printer (host = test upper board with Rinkhals + Vanilla-Klipper app) → `FIRMWARE_RESTART`, homing, temperatures.

## Result – OTA from the upper board (2026-10-20, **printer's own lower board**, no backup)
- Before: `mcu` = **v1.4.3** (120 MHz), `nozzle_mcu` = v1.4.3. There is no backup of this board's MCU flash. A possible way back is the test board's v1.4.0 dump (`build/mcu/stock_v1.4.0_app1.bin`), but only over SWD. OTA would need the Anycubic CRC footer.
- GoKlipper OTA: `OTA_START MCU=mcu UPDATE_PATH=/userdata/firmware_v2.0.12_20260907.bin`
  - **The file name must have the form `firmware_vX.Y.Z_YYYYMMDD.bin`.** GoKlipper takes the version and date from it with a regex (`/userdata/.bin` → "firmware file format error").
  - It returns `ok` after about 3 s, `validateFirmwareTarget PASSED`, and writes `/tmp/version` = `mcu:"v2.0.12"`. The transfer itself is not logged.
  - GoKlipper's `FIRMWARE_RESTART` does **not** reset the MCU. **A printer power cycle is needed.** The bootloader then copies APP2 → APP1.
- After the power cycle: **`mcu` = v2.0.12**, 120 MHz, `Printer is ready`, temperatures read correctly (bed 23 °C, nozzle 26 °C), no retransmits.
  The "Unknown message … while identifying" warnings appear with the stock firmware too.
  `QUERY_ENDSTOPS` sent over the web API made gklib's web handler panic (`interface conversion … *list.List`). That is a GoKlipper web layer bug, not the MCU. Printer state stays `ready`.
- Next: functional tests on the printer (homing XYZ, CS1237 probe, heating bed/nozzle, fans), then the same for `nozzle_mcu`.
- **nozzle_mcu** (2026-10-20 14:17): same procedure, `OTA_START MCU=nozzle_mcu UPDATE_PATH=/userdata/firmware_v2.0.12_20260907.bin` → `validateFirmwareTarget PASSED` → power cycle.
  Result: **`mcu` = v2.0.12, `nozzle_mcu` = v2.0.12**, both 120 MHz, 0 retransmits, `Printer is ready`, temperatures OK (nozzle 26 °C, bed 23 °C).

## Anycubic MCU firmware v1.4.3 (from the official update KS1_2.7.2.7, 2026-10-21)
- `KS1_2.7.2.7.swu` is the usual stock USB package (zip with the channel.sh password →
  `update_swu/setup.tar.gz`). Next to `update.sh`, `update_ota.tar` (rk_ota, A/B) and the
  `app/` binaries it holds **`firmware_v1.4.3_20260303.bin`** (27 745 B). `update.sh` does
  not copy it; GoKlipper presumably takes it from the unpacked update.
- Same layout as the v1.4.0 dump: app image for 0x08008000 (reset 0x0800BE95, SP
  0x20008000) followed by the CRC32 of the body as 8 hex digits + `\n` (`e81e9f95`,
  matches). So it is in the format the GoKlipper `OTA_START` accepts.
- Data dictionary (zlib at 0x5cd4, `tools/mcu_dict.py`, written to `build/stock/firmware_v1.4.3.dict` by `tools/fetch_stock.sh`):
  `v1.4.3`, stm32f103xe, 120 MHz, USART1 576000, 67 commands. One image for both MCUs (both
  ran v1.4.3 before the OTA to v2.0.12).
- Against our dictionaries: v1.4.3 lacks the vanilla `config_reset`, `debug_*`, `i2c_*`,
  `spi_set_sw_bus` (klippy falls back to `spi_set_software_bus`), and has the Anycubic
  `pcba_read/write`, `usart_test`, `cs1237_calibration_*`, `overflow_cs1237` (v2.0.13 has
  those except `pcba_write`). `config_cs1237 ... sensitivity` is `%u` there, `%i` in ours
  (the host encodes from the dictionary). Responses: same signatures.
- **Our klippy with v1.4.3 on both MCUs, offline** (batch mode, default config, `-d` for
  mcu and nozzle_mcu = v1.4.3, host = klipper_mcu dictionary): config loads, no errors,
  12 886 B of MCU commands (12 899 B with our dictionaries). Not tested on hardware yet.
- **On the printer (2026-10-22):** OTA of v1.4.3 to `mcu` and `nozzle_mcu` from stock
  (`OTA_START ... UPDATE_PATH=/userdata/firmware_v1.4.3_20260303.bin`, sent through the
  Rinkhals Moonraker, `validateFirmwareTarget PASSED`), power cycle → stock `ready`, both
  MCUs `v1.4.3`, no "Lookup command failed". Then ShedNaja `d4d3f01`: `Printer is ready`,
  endstops, probe (`QUERY_PROBE`), filament ADC sensor, temperatures OK. The LIS2DW12 read
  `0xff` (`Invalid lis2dw12 id`) over software SPI; with `spi_bus: spi2` (hardware SPI on the
  same pins, as in the stock printer.cfg) it works: `ACCELEROMETER_QUERY` z ≈ -9644 mm/s².
  `G28` homes xyz (Z by the load-cell probe). `PROBE_ACCURACY SAMPLES=5` at the centre:
  range 0.0025 mm, standard deviation 0.0009 mm (0.012 mm with the fork firmware).
  Rollback to the fork firmware: OTA `firmware_v2.0.12_20260907.bin` (mcu) and
  `firmware_v2.0.13_20261020.bin` (nozzle_mcu), both still in /userdata.

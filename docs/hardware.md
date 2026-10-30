# Anycubic Kobra S1 – hardware

What is known about the electronics, from the boards, the stock firmware and tests under
ShedNaja. Photos of the boards: `reference/board_*.jpg`. Peripherals (fans, sensors,
camera, light, buzzer, ACE Pro) and their pins: [peripherals.md](peripherals.md).

## NF031_UPPER_V2.1 – host board (Linux)

| Ref | Part | Notes |
|---|---|---|
| U1 | Rockchip **RV1106G3** | Cortex-A7 single core 1416 MHz, 256 MB DDR3 in package (215 MB visible to Linux), RISC-V MCU core, NPU |
| U2 | FORESEE **FEMDNN008G-08A39** | 8 GB eMMC (`/dev/mmcblk0`), A/B partition layout ([update.md](update.md)) |
| U23 | Fn-Link **6223A-SRD** | Realtek RTL8723DS: Wi-Fi b/g/n on SDIO, Bluetooth 4.2 on UART1 (`ttyS1`, H5 @115200) |
| J1 | 3-pin `GND RX TX` | **Serial console: UART2 (GPIO1_B2/B3), 3.3 V, 115200 Bd.** The DDR blob prints to it; SPL and U-Boot are silent. The stock kernel has its console off; ShedNaja's kernel logs to it from the first line and runs a getty (FIQ debugger, `ttyFIQ0`) |
| J5 | FPC | 800×480 RGB display + FocalTech touch (I2C3, `fts_ts` @0x38) |
| J6 | harness to the lower board | power for the host board and signals from the lower board (pinout not traced) |
| SW1 | tact switch next to the SoC | **pulls SARADC_IN0 to 0 V** (measured 2026-10-27: channel 0 1023 → 0 while pressed, 1.80 V → 0 V; channel 1 stays at ~1.15 V): the Rockchip recovery/download key. Not yet tried at power-on with USB to a PC |
| U11 | QFN, left side | not identified |
| Back | `USB` silkscreen next to TP7, two square pads near R31, test points | the SoC's only USB2 port (host mode) feeds the hub U11 (camera, rear USB/ACE); the lines needed for maskrom are not traced yet |
| U11 | USB hub **GL852G**, QFN-28 (marking; earlier notes said GL850G, both enumerate as `05e3:0610`) | upstream port to the SoC on **pin 1 = DM0, pin 2 = DP0**; pins count counter-clockwise from the dot, pin 28 = V33 (3.3 V out) is the other pin at the dot corner. Datasheet: `reference/datasheets/GL852G_Datasheet_Rev1.32.pdf` (Table 3.2) |
| gpio41 (GPIO1_B1) | "usb sel" in Anycubic's `run.sh` | 0 (reset default): hub and camera gone, only the root hub; 1: hub + camera enumerate (2026-10-27, Armbian). A USB switch (SoC USB → hub or elsewhere) or the hub's power: not measured |

Host GPIOs used by ShedNaja: gpio41 (GPIO1_B1) USB switch, gpio116 (GPIO3_C4) MCU reset,
gpio117 (GPIO3_C5) chamber light, PWM0 (GPIO1_A2) buzzer, PWM1 backlight.

Boot chain: BootROM → idblock (DDR blob, SPL with A/B slots) → U-Boot (FIT) → kernel (FIT).
**Secure boot is not enforced**: the FIT images carry hashes but no signatures, and U-Boot has
no public key ([firmware-analysis.md](firmware-analysis.md)).

## NF031_LOWER_V2.2 – motion board (main MCU)

| Ref | Part | Notes |
|---|---|---|
| U9 | GigaDevice, marked **GD32FCES RBT6** | GD32F30x high density (DBGMCU_IDCODE dev id 0x414), **Cortex-M4** r0p1, 128 KB flash, LQFP64. Klipper builds it as stm32f103xe. **RDP and write protection are off** |
| Y4 | 8.000 MHz crystal | HSE |
| P7 | 5 pads, pad 1 square | **SWD:** 1 = 3V3, 2 = GND, 3 = SWDIO (pin 46), 4 = SWCLK (pin 49), 5 = NRST (pin 7). The firmware turns SWD off at runtime: attach under reset (hold NRST low) |
| P6 | 3-pin `TX1 RX1 GND` | USART1 (PA9/PA10), the MCU's Klipper serial port |
| — | 3× stepper drivers (TMC2209) under the heatsink, 24 V input, fans, bed, thermistor | |

The host talks to the main MCU on `/dev/ttyS3` (UART3) and to the toolhead MCU on
`/dev/ttyS5` (UART5), both 576000 Bd, Klipper protocol. Both MCUs run the Anycubic firmware
v1.4.3 (Klipper-based, 120 MHz) with the Anycubic IAP bootloader at 0x08000000 and the
application at 0x08008000: [mcu.md](mcu.md).

### U9 LQFP64 pins used for debugging

Pinout of GD32F303Rx (GD32F303xB datasheet Rev1.1, Fig. 2-3 / Table 2-4, from the
[GD32F303 product page](https://www.gigadevice.com/product/mcu/main-stream-mcus/gd32f30x-series/gd32f303)).

| Pin | Signal |
|---|---|
| 7 | NRST |
| 42 / 43 | PA9 / PA10 = USART0 TX/RX (factory serial bootloader) |
| **46** | **PA13 = SWDIO** |
| 47 / 48 | VSS_2 / VDD_2 |
| **49** | **PA14 = SWCLK** |
| 60 | BOOT0 |
| 1, 12/13, 18/19, 31/32, 63/64 | VBAT, VSSA/VDDA, VSS/VDD pairs |

Numbering is counter-clockwise from pin 1 (16 per side), so pin 64 is next to pin 1 and
the SWD pins sit at the corner where pin 48 meets pin 49.

## Toolhead board

Toolhead MCU (Klipper `nozzle_mcu`, same firmware image as the main MCU): extruder
stepper + TMC2209, hotend heater and thermistor, part and hotend fans, CS1237 load cell
(the Z probe), LIS2DW12 accelerometer on SPI2, analog filament sensor. Pins: `kobra_s1.cfg`.

## Bench setup

- On the bench the lower board gets 24 V on its `24V` connector; the upper board is powered
  from it through the harness (lower J1 ↔ upper J6) and boots to the logo with the display.
- The wide FPC on the upper board's J5 goes to the touch display (the upper board sits in
  the display housing).

## Open questions

- SW1 at power-on: rockusb/maskrom over USB? (SW1 itself is SARADC_IN0, see above)
- Maskrom over USB (`2207:110c`): where the SoC's USB D+/D− can be reached before the hub.
- gpio118 (toggled by stock together with the MCU reset) and an input GPIO watched by the
  stock UI: not identified.

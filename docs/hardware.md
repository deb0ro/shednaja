# Anycubic Kobra S1 – hardware notes

Source: photos in `reference/` (test boards, 2026-10-19).

## NF031_UPPER_V2.1 – host board (Linux)

| Ref | Part | Notes |
|---|---|---|
| U1 | Rockchip **RV1106G3** (date 2439) | Cortex-A7 single core, 256 MB DDR3L in package, RISC-V MCU core, NPU |
| U2 | FORESEE **FEMDNN008G-08A39** | 8 GB eMMC (`/dev/mmcblk0`, A/B layout per Rinkhals docs) |
| U23 | Fn-Link **6223A-SRD** | Realtek RTL8723DS, SDIO Wi-Fi b/g/n + BT 4.2; mainline driver `rtw88_8723ds` (≥ 6.5), vendor driver in Rockchip SDK |
| SW1 | tact switch next to SoC | Probably maskrom/recovery (like SW2 on Kobra 3) – TO VERIFY |
| J1 | 3-pin `GND RX TX` | Debug UART, expect 3.3 V, 1 500 000 baud – TO VERIFY |
| J5 | FPC (right edge) | Display + touch |
| U11 | QFN (left side) | Unidentified – USB hub? needs close-up |
| Back | `USB` silkscreen, TP7, U6 (TSSOP), test points TP1–TP34 | USB D+/D− probably reachable here; a factory bodge wire is near C31 |

## U9 LQFP64 pinout (GD32F303Rx, GD32F303xB datasheet Rev1.1, Fig. 2-3 / Table 2-4, from the [GD32F303 product page](https://www.gigadevice.com/product/mcu/main-stream-mcus/gd32f30x-series/gd32f303))
Assumes the "GD32FCES RBT6" is pin-compatible with GD32F303Rx/STM32F103Rx (standard for GD32 LQFP64 – confirm via SWD IDCODE).

| Pin | Signal | Note |
|---|---|---|
| 1 | VBAT | corner with pin-1 mark |
| 7 | NRST | |
| 12 / 13 | VSSA / VDDA | |
| 18 / 19 | VSS_4 / VDD_4 | |
| 31 / 32 | VSS_1 / VDD_1 | |
| 42 / 43 | PA9 / PA10 | USART0 TX/RX = factory serial bootloader |
| **46** | **PA13 = SWDIO** | |
| **47 / 48** | **VSS_2 / VDD_2** | |
| **49** | **PA14 = SWCLK** | |
| 60 | BOOT0 | |
| 63 / 64 | VSS_3 / VDD_3 | |

Numbering is counter-clockwise from pin 1: 1–16 on side A, 17–32 on side B, 33–48 on side C, 49–64 on side D, so pin 64 is next to pin 1. SWD sits in the corner where 48 meets 49, i.e. at the far end of the side that starts with pin 64 next to pin 1.

## NF031_LOWER_V2.2 – motion board (MCU)

| Ref | Part | Notes |
|---|---|---|
| U9 | GigaDevice, marked **GD32FCES RBT6** (PJ2523) | No public datasheet for this marking. RBT6 = LQFP64, 128 KB flash. Likely a custom/OEM GD32F30x-class part (Cortex-M3/M4). The Kobra-S1 Klipper fork builds it as STM32. Confirm with SWD: DBGMCU_IDCODE + flash-size register |
| Y4 | 8.000 MHz crystal (JSCC) | HSE 8 MHz |
| P7 | 5 pads, pad 1 = square | **SWD header, measured 2026-10-20:** 1 = VDD 3V3 (pin 48), 2 = GND, 3 = SWDIO (pin 46), 4 = SWCLK (pin 49), 5 = NRST (pin 7) |
| P6 | 3-pin `TX1 RX1 GND` | MCU UART (probably the host link or debug) |
| Back | TP14–TP59 | Test points incl. probably SWD/BOOT0 |
| — | 3× stepper (X, Y, Z) under heatsink, 24 V input, FAN, BED-CTRL, T1 (thermistor) | |

## Cabling (bench setup)
- The wide black FPC on the upper board's **J5** goes to the **touch display** (the upper board sits in the display housing). It is not a power cable.
- On the bench the lower board gets 24 V into its `24V` connector. The upper board then boots to the Anycubic logo with the display attached, so the host gets its power from the lower board through the multi-wire harness (lower J1 ↔ upper J6). Pinout not traced yet: probably 24 V or 5 V, GND and a data link (UART or USB) to the MCU.

## Open questions
- Is secure boot (OTP keys) enabled on the RV1106? → check the U-Boot log on J1.
- Which connector carries the USB used for maskrom (`2207:110c`)?
- Is RDP (read protection) set on the GD32? → SWD read attempt.
- How does the host reach the MCUs (UART on P6 vs. USB)?

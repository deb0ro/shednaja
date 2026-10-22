# Stock firmware analysis (FW 2.7.2.7, backups from 2026-10-20)

Sources: a full eMMC backup and an SWD dump of the motion MCU of the development printer
(`dumps/`, not published). Extracted files that can be shared are in `analysis/`; the boot,
oem and system images of 2.7.2.7 can be reproduced from the official update with
`tools/fetch_stock.sh`. The MCU app layout of v1.4.3 and how ShedNaja uses it: [mcu.md](mcu.md).

## Boot chain and signing – **secure boot is NOT enforced**

| Stage | Location | Findings |
|---|---|---|
| BootROM → idblock | `idblock` (RKNS v2 header) | DDR blob `DDR V1.11 285bced5c1 (23/03/28)`. SPL is `U-Boot SPL 2017.09-gf616e842c5 (Oct 17 2025)`, handles A/B slots (`ab_data_spl`) and reads the secure OTP. SPL contains the error string *"Verified-boot requires CONFIG_SPL_FIT_SIGNATURE enabled"*, i.e. it was built **without** FIT signature support. With the OTP verified-boot flag set, it would stop there. |
| SPL → U-Boot | `uboot_a/b` = FIT "ATF/OP-TEE/U-Boot/MCU" | `U-Boot 2017.09-gf616e842c5 (Jan 26 2026)`, lzma, plus U-Boot DTB (`rockchip,rv1106-evb`). The config has a `signature` node (`sha256,rsa2048`, key-name-hint `dev`) **but no `value`** → unsigned. The U-Boot DTB has **no `/signature` public-key node** → U-Boot cannot verify anything. `bootdelay=0`. |
| U-Boot → kernel | `boot_a/b` = FIT "Linux kernel, FDT blob and resource" | Images `fdt` (36 917 B), `kernel` (zImage, 3.2 MB, xz), `resource` (RSCE, logo). sha256 hashes match (verified). The `signature` node again has **no `value`** → unsigned. |

**Conclusion:** the whole chain boots unsigned images, so the OTP secure-boot flag is not set. Our own U-Boot, kernel and rootfs can be booted. The only protection is integrity (sha256 hashes in the FIT), which `mkimage` regenerates. The rollback index is 0 everywhere.

## Kernel
- `Linux 5.10.160`, toolchain `arm-rockchip830-linux-uclibcgnueabihf-gcc 8.3.0` (Rockchip RV1106 SDK, uClibc). Built 2026-01-26.
- **No embedded config** (no `IKCFG_ST`, no `/proc/config.gz`). The config has to be rebuilt from the RV1106 SDK defconfig (`rv1106_defconfig` / Luckfox Pico) plus the observed drivers.
- Decompressed image: `analysis/vmlinux_Image.bin` (7.1 MB).

## Device tree (`analysis/kobra_s1.dts`, 1658 lines)
- Base: `rockchip,rv1106g-38x38-ipc-v10-spi-nand` (Rockchip EVB "IPC38"), adapted.
- bootargs in DT: `earlycon=,mmio32,0xff4c0000 console= …` → **UART2 (0xff4c0000) is the console**, but the driver name is blanked and `console=` is empty. J1 is almost certainly UART2. Re-enabling is a DT/bootargs change.
- Enabled devices: 3× UART (BT, 2× MCU), 2× I2C, 2× PWM, 2× SD/MMC (eMMC + SDIO Wi-Fi), SFC, DWC3 USB (host mode), GMAC + PHY `0044.1400`, VOP + **RGB parallel panel** (`simple-panel`) + PWM backlight, **FocalTech `fts` touch** (I2C, 5 points), 2× `charlie,spidev` (custom SPI devices – to identify), RKISP/CIF/CSI (camera pipeline, unused, the camera is on USB), NPU, VEPU, RGA, BT/Wi-Fi platdata.

## MCU (GD32F30x, 128 KB) – flash layout and OTA

| Range | Size | Content |
|---|---|---|
| 0x08000000–0x08003000 | 12 KB | **Anycubic IAP bootloader** |
| 0x08008000–0x08012000 | 40 KB slot | **Application** (Klipper MCU, 28 KB used, offset 0x8000) |
| 0x08012000–0x0801E000 | 48 KB | **Backup / OTA staging area** (empty now) |
| 0x0801E000 | 12 B used | **OTA record**: `00040100 78563412 00000000` → u32 `0x00010400` (likely app version **1.4.0**), magic `0x12345678`, u32 `0` = no update pending |
| 0x0801F800 | 72 B used | **Board identity**: `01 00 …`, then `01 00 15 00` + a 21-character ASCII serial / hardware ID (board-specific, not reproduced here) |

Bootloader logic (from strings + address constants 0x08008000 / 0x08012000 / 0x0801E000): "iap init" → read the OTA record → if an update is pending, check CRC32 (`app_fla:%x,crc32:%x,offset:%x`), copy backup → app (`Upgrade copy of backup area successful, ready goto app`), otherwise `No need to update the app` → `GotoApp->addr=0x8008000`. It logs on USART2 (0x40004800, PB10/PB11) and also touches USART0 (0x40013800).
The application disables SWD at runtime → SWD only works with connect-under-reset.

**Klipper data dictionary** (zlib JSON at 0x0800DB10, extracted to `analysis/mcu_data_dictionary.json`):
version **`v1.4.0`** (Anycubic fork), built with gcc 10.3.1, `MCU = stm32f103xe`, `CLOCK_FREQ = 72 MHz`, 67 commands.
Anycubic-specific commands: `config_cs1237`, `enable_cs1237`, `reset_cs1237`, `checkself_cs1237`, `overflow_cs1237`,
`query_cs1237_adc`, `query_cs1237_diff`, `start_cs1237_report …sensitivity`, **`cs1237_calibration_phase`**, **`cs1237_calibration_DataProcess`**
(likely the commands the community fork is missing for flow/PA calibration), `config_lis2dw12`/`query_lis2dw12*`,
`config_ota`/`ota_start`/`ota_erase`/`ota_transfer_response`/`query_ota_*`, `pcba_read`/`pcba_write` (board ID page), `usart_test`.
The dictionary gives exact message formats. The algorithm behind `DataProcess` has to be reverse-engineered from the binary (Ghidra, Cortex-M4/M3 Thumb, base 0x08008000).

**Implications:**
- Mainline Klipper for this MCU = build with flash offset **0x8000** (keep the Anycubic bootloader). It can be written over SWD (under reset) or via OTA into 0x08012000 + record at 0x0801E000.
- The 0x0801F800 page (board ID) and the bootloader must never be erased.
- Full replacement (e.g. Katapult at 0x08000000) is possible because RDP and WRP are off, but it loses the stock OTA path. Keep the backup.

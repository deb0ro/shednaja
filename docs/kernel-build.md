# Kernel and boot image

ShedNaja's kernel: Rockchip Linux 5.10.160 from the Luckfox Pico SDK with our device tree
and config, the RTL8723DS Wi-Fi and Realtek Bluetooth modules, packed into a boot image
in the stock FIT layout. It runs on every ShedNaja install; Wi-Fi, Bluetooth, display, touch,
eMMC, USB and the MCU UARTs work with it. How it was derived and tested:
[history/kernel-build-log.md](history/kernel-build-log.md).

## Build

```bash
bash tools/fetch_stock.sh             # once: build/stock/boot.img is the FIT template
bash tools/build_kernel.sh            # -> build/kernel/
bash tools/build_oem_ours.sh          # -> build/kernel/oem_ours.img (needs build/kernel/oem-ko/)
```

- Linux or WSL2 (from Git Bash the script re-runs itself in WSL). The first run clones the
  SDK (kernel + toolchain, about 2 GB, sparse and blobless) into `~/kobra/luckfox-pico`;
  objects go to `~/kobra/kernel-out` (on the Linux filesystem, `/mnt/d` would be slow).
- Environment: `SDK_DIR`, `KOUT`, `TEMPLATE` (default `build/stock/boot.img`), `JOBS`,
  `CLEAN=1`.
- Needs git, make, gcc, bc, bison, flex, libssl-dev, python3, patch. No sudo, no host `dtc`
  or `mkimage`.
- Reproducible: timestamp (SDK commit date), user/host, `LOCALVERSION` and the `#N` build
  counter are pinned; clean and incremental builds give identical `zImage`, DTB, `boot.img`
  and modules.

## Inputs (pinned)

| What | Where |
|---|---|
| Kernel source, toolchain | `LuckfoxTECH/luckfox-pico` @ `824b817f` (2026-03-22): `sysdrv/source/kernel` (Rockchip 5.10.160), `arm-rockchip830-linux-uclibcgnueabihf` gcc 8.3.0, the same compiler as stock |
| Device tree | [kernel/dts/rv1106g-kobra-s1.dts](../kernel/dts/rv1106g-kobra-s1.dts) |
| Config fragment | [kernel/configs/kobra_s1.config](../kernel/configs/kobra_s1.config), on top of `rv1106_defconfig` + `rv1106-evb.config` |
| SDK patches | [kernel/patches/](../kernel/patches/): `0001` FocalTech touch driver built in, `0002` RTL8723DS vendor driver on 5.10 |
| BT driver | `radxa/rkwifibt` @ `b61a1e84`, `drivers/bluetooth_uart_driver` |
| Boot image template | `build/stock/boot.img` from the official `KS1_2.7.2.7.swu` |
| Boot logo | [kernel/logo/boot_logo.bmp](../kernel/logo/boot_logo.bmp) |

## Outputs (`build/kernel/`)

| File | Content |
|---|---|
| `boot.img` | FIT for `boot_a` / `boot_b` (about 4 MB, partition 16 MiB): zImage + DTB + RSCE resource (DTB as `rk-kernel.dtb`, our logo) |
| `zImage`, `rv1106g-kobra-s1.dtb`, `System.map`, `config`, `kobra_s1_defconfig` | kernel artifacts (the config is also in `/proc/config.gz`) |
| `modules-5.10.160.tar.gz`, `modules.txt` | `lib/modules/5.10.160` for the rootfs; `RTL8723DS.ko` and `hci_uart.ko` in `extra/` |
| `oem-ko/` | `RTL8723DS.ko`, `hci_uart.ko`, `cfg80211.ko`, laid out like stock `/oem/usr/ko/` |
| `oem_ours.img` | stock oem squashfs with those three modules replaced (`tools/build_oem_ours.sh`) |
| `dtb_vs_stock.diff` | normalized DTB diff against stock (only when `analysis/boot_fdt.bin` exists) |

## Boot image format

`tools/mkboot_kernel.py` keeps the stock FIT header (nodes, `load`/`entry` = 0xffffff01,
the unsigned `signature` stub, timestamp, Rockchip record) and changes only data sizes,
positions, sha256 hashes and `totalsize`. The kernel is a self-decompressing XZ zImage with
`compression = "none"`, as in stock. **Rockchip U-Boot boots with the DTB from the RSCE
resource (`rk-kernel.dtb`), not the FIT `fdt`**, so both are written and checked to be
identical. The boot chain does not verify signatures ([firmware-analysis.md](firmware-analysis.md)).

`--logo` replaces `logo.bmp` and `logo_kernel.bmp` in the resource: 800×480, 8 bit with a
palette, stored upside down (the panel is mounted rotated). `tools/make_update_splash.py`
generates it together with the update screens. U-Boot and the kernel show it until
HelixScreen starts; the stock slot keeps its own logo.

## Config

Stock has no embedded config. It was rebuilt from the SDK defconfig by comparing the
stock kernel's symbols with ours (`analysis/kernel/compare_syms.py`) and adding what stock
has built in: high-res timers, Bluetooth core + rfkill, BT/Wi-Fi crypto, USB storage and
serial (CDC-ACM, CP210x, CH341), USB network adapters, HID, UVC, exFAT, FocalTech touch.
Same vermagic as stock (`5.10.160 mod_unload ARMv7 thumb2 p2v8`).

Additions over stock: 8250 console + earlycon (log from the first line), `IKCONFIG`,
partition tables for USB sticks (`MSDOS_PARTITION`, `EFI_PARTITION`, `CMDLINE_PARTITION`).
Left out: mainline `BT_HCIUART` (the Realtek vendor `hci_uart.ko` is used, as in stock),
the USB gadget (the port is host-only on this board).

## Device tree

Anycubic's DTB is the Rockchip EVB `rv1106g-38x38-ipc-v10-spi-nand` with board overrides.
Ours includes the same dtsi set and carries only the Kobra parts:
- **Display:** VOP → RGB `simple-panel` 800×480, PWM1 backlight.
- **Touch:** I2C3 m2, `focaltech,fts` @0x38 (and the `hyn,7xx` node of stock, no driver).
- **Wi-Fi/BT:** RTL8723DS on SDIO (sdmmc), BT on UART1 with the stock platdata.
- **UARTs:** UART3 (m0) and UART5 (m2) to the two MCUs.
- **USB:** DWC3 in host mode.
- **CPU:** the single stock OPP (1416 MHz).
- **Console:** FIQ debugger on UART2 m1 (J1), 115200, `console=ttyFIQ0`.
- **RK630 PHY:** `rockchip,thermal-zone` removed (tsadc is disabled like in stock; the PHY
  logged an error every second).
- Camera CSI path and SPI NAND controller disabled (the camera is UVC on USB, there is no
  SPI flash).

`build/kernel/dtb_vs_stock.diff` lists the rest (newer SDK dtsi properties).

## Wi-Fi and Bluetooth modules

| Module | Source | Version |
|---|---|---|
| `RTL8723DS.ko` | SDK `drivers/net/wireless/rockchip_wlan/rtl8723ds` + patch `0002` | Rockchip `v5.10.1-20-g5af20e016.20200310_beta` |
| `hci_uart.ko` | `radxa/rkwifibt` | Realtek `2.2.3634cd9.20220519` |

Stock runs `RTL8723DS.ko` `v5.13.5-34-gf315764ad.20220118` and `hci_uart` `2.2.813d11a`.
That exact Wi-Fi driver version is in `radxa/rkwifibt` (`drivers/rtl8723ds`); ShedNaja still
builds the SDK's older v5.10.1, which has been stable (3 h test without disconnects; the
camera stream over Wi-Fi). Switching to the radxa copy is an open option. Name, aliases,
dependencies and vermagic match stock; the Wi-Fi firmware is inside the module. The BT
firmware comes from the stock `ac_lib` image ([rootfs-build.md](rootfs-build.md)).

Wi-Fi power saving is off (`rtw_power_mgnt=0`, `rtw_ips_mode=0` in
`/etc/modprobe.d/kobra-wifi.conf`): with it on, latency spikes of 600 ms limited the
camera stream.

## Open points

- Hynitron CST836U touch (`hyn,7xx`): no driver in the public tree. Printers with that
  panel instead of FocalTech would have no touch (none seen so far).
- The touch driver reports the controller's raw range (0..1600 × 0..2176), so HelixScreen
  needs a one-off touch calibration.
- `tsadc` (CPU temperature) is disabled, as in stock.

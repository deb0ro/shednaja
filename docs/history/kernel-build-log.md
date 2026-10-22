# Own kernel build for the Kobra S1 host board (RV1106G3)

> **Development log, not a how-to.** This page records an experiment or test from the
> development of ShedNaja (the kernel build log, 2026-10-20/21; the current page is [kernel-build.md](../kernel-build.md)). Commands, slot names and file paths in it describe the
> setup at that time and can be wrong or **destructive** on a printer installed today (for
> example, writing "the inactive slot" can overwrite the stock fallback). Paths under `dumps/`,
> `logs/` and `build/` refer to unpublished development files. Current documentation:
> [docs/README.md](../README.md).

First step of the own-OS phase: a reproducible Linux 5.10.160 build that can replace the stock kernel in an A/B boot slot.
**Status (2026-10-20):** the build works end to end and produces `build/kernel/boot.img`, the in-tree modules and the out-of-tree RTL8723DS Wi-Fi + Realtek hci_uart BT modules. It has **not been booted on hardware yet**. Flashing is a separate decision; see "Testing on the board" below.

## Quick start

```bash
bash tools/build_kernel.sh            # from Git Bash: re-runs itself in WSL Ubuntu-24.04
```

Inside WSL the same script runs directly. The first run clones the SDK (about 2 GB, a few minutes). A full build takes about 1.5 min on 12 threads. Options are environment variables: `CLEAN=1` (fresh object dir), `SDK_DIR`, `KOUT`, `TEMPLATE`, `JOBS`.
Needs: git, make, gcc, bc, bison, flex, libssl-dev, python3, patch. No sudo, no host `dtc` or `mkimage`.

## Inputs (pinned)

| What | Where |
|---|---|
| Kernel source | Luckfox Pico SDK `LuckfoxTECH/luckfox-pico` @ `824b817f889c2cbff1d48fcdb18ab494a68f69d1` (2026-03-22), `sysdrv/source/kernel` = Rockchip 5.10.160. Sparse, blobless clone in `~/kobra/luckfox-pico`. |
| Toolchain | Same repo, `tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf` (gcc 8.3.0, crosstool-NG 1.24.0). This is the same compiler as stock. |
| Our DTS | [kernel/dts/rv1106g-kobra-s1.dts](../../kernel/dts/rv1106g-kobra-s1.dts) (copied into `arch/arm/boot/dts/` by the script) |
| Our config fragment | [kernel/configs/kobra_s1.config](../../kernel/configs/kobra_s1.config) |
| SDK fixes | [kernel/patches/](../../kernel/patches/) (applied idempotently to the SDK tree): `0001` fixes linking of the FocalTech touch driver when built in, `0002` ports the RTL8723DS vendor Wi-Fi driver to 5.10 |
| BT driver source | `radxa/rkwifibt` @ `b61a1e8499a4f1956ef417cbcfaa6c2cf805ce08` (develop, 2026-04-14), only `drivers/bluetooth_uart_driver` (sparse, in `~/kobra/rkwifibt`) |
| Boot image template | `build/stock/boot.img` from the official `KS1_2.7.2.7.swu` (`tools/fetch_stock.sh`; identical to the eMMC dump of boot_a) |

Object files live on the Linux filesystem (`~/kobra/kernel-out`); building on `/mnt/d` would be very slow.
Build metadata is pinned (`KBUILD_BUILD_TIMESTAMP` = SDK commit date, user/host fixed, `LOCALVERSION=` empty, and since 2026-10-20 also `KBUILD_BUILD_VERSION=1`, the `#N` build counter). Verified on 2026-10-20: two real `CLEAN=1` builds and one incremental build give identical `zImage`, DTB, `boot.img` and modules tarball. *Correction:* the earlier "`CLEAN=1` rebuild was bit-identical" check was not clean, because `CLEAN` did not reach WSL when the script was started from Git Bash (fixed). With the counter pinned, the zImage changes once compared with the image booted at 18:33 (`#2` → `#1` in `uname -v`; zImage `b6ef13…` → `76e814…`, boot.img `f117c2…` → `77e30f…`). Code, DTB and modules are unchanged.

## Outputs (`build/kernel/`)

| File | Content |
|---|---|
| `boot.img` | FIT for `boot_a`/`boot_b` (4.0 MB, partition 16 MiB): our zImage + DTB + RSCE resource (our DTB as `rk-kernel.dtb`, stock `logo.bmp` / `logo_kernel.bmp` byte-identical) |
| `zImage`, `rv1106g-kobra-s1.dtb`, `System.map` | kernel artifacts |
| `config`, `kobra_s1_defconfig` | full `.config` and `savedefconfig` output (also in the kernel as `/proc/config.gz`) |
| `modules-5.10.160.tar.gz`, `modules.txt` | `lib/modules/5.10.160/...` (stripped), for a rootfs; out-of-tree `RTL8723DS.ko` and `hci_uart.ko` are in `extra/`, `modules.dep` included |
| `oem-ko/` | `RTL8723DS.ko`, `hci_uart.ko`, `cfg80211.ko` as flat files, named and laid out like stock `/oem/usr/ko/` |
| `dtb_vs_stock.diff` (+ `stock_dtb.txt`, `kobra_dtb.txt`) | normalized DTB diff against stock (`tools/dtb_normalize.py`) |
| `SHA256SUMS`, `build.log`, `rtl8723ds.log`, `hci_uart.log` | checksums and logs |

Tools added for this step: `tools/build_kernel.sh`, `tools/mkboot_kernel.py` (FIT/RSCE builder, based on the layout of `fit_patch_console.py` and using `fdtpatch.py`), `tools/dtb_normalize.py` (DTB to text with phandles resolved to paths, for diffing). Analysis helper: `analysis/kernel/compare_syms.py`.

## Boot image format

`tools/mkboot_kernel.py <stock boot.img> <zImage> <dtb> <out>` keeps the stock FIT header: same nodes, `load`/`entry` = 0xffffff01 (U-Boot chooses), the unsigned `signature` stub, the FIT timestamp, and the Rockchip mkimage record in the header's free space. It changes only data sizes, positions, sha256 hashes and `totalsize`. Layout is the stock one: header room 2048 B, 512-byte aligned blobs, total aligned to 4 KiB. The kernel is a self-decompressing XZ zImage with `compression = "none"`, as in stock.
The RSCE resource is rebuilt generically (header block, one index block per entry, files packed in 512-byte blocks) with our DTB as `rk-kernel.dtb`. **Rockchip U-Boot boots with that copy, not the FIT `fdt`** (see console-test.md), so both are written and checked to be identical.
Verified on the output: all three sha256 hashes match. Header properties differ from stock only in size/position/hash/totalsize. RSCE `rk-kernel.dtb` equals the FIT fdt. Both logos are byte-identical to stock.

## Kernel config: how it was derived

Stock has no embedded config. Method:
1. Symbols from the stock image: `vmlinux-to-elf`'s `kallsyms_finder --bit-size 32` on `analysis/vmlinux_Image.bin` gives 35 982 symbols. Base address 0xB0008000, i.e. `CONFIG_VMSPLIT_3G_OPT` like the SDK defconfig.
2. Candidate = SDK `rv1106_defconfig` + `rv1106-evb.config`. Its module set matches stock `/oem/usr/ko` (cfg80211, mac80211, ipv6, gcm, rknpu, rga3, rkisp/rkcif, csi2-dphy, sc3336/sc4336/sc530ai, os04a10, gc2053, gspca_main …).
3. `analysis/kernel/compare_syms.py` diffs the stock text symbols against our `System.map` and maps the missing ones to source files and Kconfig symbols. A list of marker symbols covered features that the file mapping misses.
4. What stock has built in that the SDK defaults lack went into `kobra_s1.config`: high-res timers, Bluetooth core + rfkill-rk + rfkill-gpio, BT/Wi-Fi crypto (ECDH, CCM, CMAC, DRBG, jitterentropy, AF_ALG user API), SCSI + sd + usb-storage, CDC-ACM, USB serial (generic, CP210x, CH341), USB net (r8152, AX88179, cdc_ether), usbmon, HID/usbhid/hiddev/hidraw, UVC (gspca as module), exFAT + NLS utf8/cp936, serio/serport, uinput, mousedev, FocalTech touch.
5. **Additions over stock:** `SERIAL_8250_CONSOLE` + `SERIAL_EARLYCON` (log from the first line via `earlycon=uart8250`), `IKCONFIG(_PROC)`.

The script checks that every option of the fragment survived Kconfig ("all fragment options applied").
Result: same vermagic as stock modules: `5.10.160 mod_unload ARMv7 thumb2 p2v8`, no MODVERSIONS, HZ=100.

Deliberately **not** copied from stock:
- Mainline `BT_HCIUART` stays off: stock uses Realtek's vendor `hci_uart.ko` (built out of tree, see below), and both would register the same line discipline (N_HCI).
- Legacy USB gadget mass storage (`g_mass_storage` is built into stock) is left out because the DWC3 is host-only on this board.
- gspca sub-drivers: only `gspca_main` is a module, as in stock (the `sd_probe` hits were SCSI-disk false positives).

## Device tree: rv1106g-kobra-s1.dts

Anycubic's DTB is the Rockchip EVB `rv1106g-38x38-ipc-v10-spi-nand` with board overrides. It was built with `CONFIG_DTC_OMIT_DISABLED`, which drops unreferenced disabled nodes; the SDK does the same. So our DTS includes the same dtsi set (`rv1106.dtsi`, `rv1106-evb.dtsi`, `rv1106-ipc.dtsi`) and carries only the Kobra overrides:
- **Display:** VOP → RGB (`lcd_pins`) → `simple-panel` 800×480, 31.25 MHz, bus format 0x1009 (RGB666_1X18), PWM1 (m2) backlight with `enable-gpios` GPIO0_A0. Boot logos come from the resource via `route-rgb`.
- **Touch on I2C3 m2 @100 kHz:** `focaltech,fts` @0x38 and `hyn,7xx` (Hynitron CST836U) @0x15, IRQ GPIO0_A1, reset GPIO1_B0. I2C4 (m0) is disabled with the unused `xpt7603` node, as in stock.
- **Storage / Wi-Fi:** eMMC 8-bit HS200. The RTL8723DS SDIO is on the *sdmmc* controller (SDMMC0 pins). `vcc3v3-wifi` is GPIO0_A3 active high. `wireless-wlan` / `wireless_bluetooth` platdata: BT on UART1 with CTS, RTS as GPIO0_A5, reset on GPIO0_A4.
- **UARTs:** UART3 (m0) and UART5 (m2) go to the two MCUs. UART0 uses the m1 pins but stays disabled, as in stock.
- **USB:** DWC3 `dr_mode = "host"` + u2phy.
- **CPU:** OPP table reduced to the single stock OPP, 1416 MHz at 925 mV / 850–1050 mV.
- **Console:** FIQ debugger on UART2 m1 (J1), 115200, irq mode, `console=ttyFIQ0`. The node is identical to the one in the tested `build/boot_fiq_test.img`. UART2 stays disabled, so the 8250 driver only provides the earlycon. Bootargs: stock ones with `earlycon=uart8250,mmio32,0xff4c0000 console=ttyFIQ0`. U-Boot still replaces `root=` and appends `blkdevparts=` (`CMDLINE_PARTITION=y`).

Remaining differences to stock (`build/kernel/dtb_vs_stock.diff`, about 70 lines each way), all deliberate or from the newer SDK dtsi:

| Area | Stock | Ours | Why |
|---|---|---|---|
| model/compatible | IPC38 EVB | `anycubic,kobra-s1` | identification |
| fiq-debugger, bootargs | absent, console blanked | enabled | console on J1 |
| CSI camera path (csi2-dphy0, mipi csi2) | dphy0 okay with dangling endpoints | disabled, endpoints removed | camera is UVC on USB; stock pointed at deleted sensor nodes |
| SFC (SPI NAND) | okay (no flash on the board) | disabled | the EVB's SPI flash is not on this board |
| PWM7 (vdd_arm PWM) | disabled | disabled | matched to stock: the pwm-regulator never probes, so CPU voltage stays where the bootloader set it |
| psci | absent | removed | unused (`ARM_PSCI` off); kept equal to stock |
| GMAC rx-dma-size/flow-ctrl, PHY bgs/thermal props, PWM irqs, 2nd timer irq, hpmcu-sram 8 KiB, rockchip-suspend, power-management | older SDK dtsi | newer SDK dtsi | these come with the newer SDK kernel's drivers. Low risk, but this is the first place to look if Ethernet, PWM or suspend misbehave |
| sdio (ff9a0000) props, unreferenced pin groups (sdmmc1m0, backlight-pwren, lcd-pwren) | present but disabled/unused | omitted | no effect |

## Wi-Fi and Bluetooth modules (RTL8723DS)

### What stock does (from the dumps)
- **Wi-Fi:** `/oem/usr/ko/RTL8723DS.ko` (oem squashfs, identical in oem_a/oem_b): Realtek `v5.13.5-34-gf315764ad.20220118_COEX20210106-3b3b`, `name=RTL8723DS`, `depends=cfg80211`, `import_ns=VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver`, SDIO aliases `024c:d723`/`d724`, vermagic `5.10.160 mod_unload ARMv7 thumb2 p2v8`.
  - `insmod_wifi.sh` does **not** load it; it only handles other chips.
  - The Anycubic app loads it: `insmod /oem/usr/ko/cfg80211.ko; insmod /oem/usr/ko/RTL8723DS.ko; wpa_supplicant -Dnl80211 -i wlan0 -c /userdata/wifi_cfg/wpa_supplicant.conf` (strings in the app on userdata). `S98_wifi_connect` has the same lines commented out.
- **Wi-Fi firmware is inside the module** (`array_mp_8723d_fw_nic`, no `request_firmware`). The only file paths are optional: `/system/etc/wifi/wifi_efuse_8723ds.map` and `/data/wifimac.txt`; neither exists on stock.
- **Bluetooth** (`/etc/init.d/S98_bluetooth_connect`):
  1. Toggles `/sys/class/rfkill/rfkill0/state` and `/proc/bluetooth/sleep/btwrite`. Both come from the kernel's `rfkill-rk`/`rfkill-bt`.
  2. `insmod /oem/usr/ko/hci_uart.ko`. This is Realtek's vendor driver `2.2.813d11a.20230413-173903` (H4 + Realtek H5 + rtk_coex, `alias=tty-ldisc-15`).
  3. `rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5`.

  The BT firmware is userspace: `rtk_hciattach` loads `/lib/firmware/rtlbt/rtl8723d_fw` + `rtl8723d_config` (in the ac_lib partition).

### What we build
| Module | Source | Version | Notes |
|---|---|---|---|
| `RTL8723DS.ko` | SDK `drivers/net/wireless/rockchip_wlan/rtl8723ds` + `kernel/patches/0002` | `v5.10.1-20-g5af20e016.20200310_beta` (Rockchip) | older than stock's v5.13.5, see below |
| `hci_uart.ko` | `radxa/rkwifibt` `drivers/bluetooth_uart_driver` (pinned) | `2.2.3634cd9.20220519-142433` (Realtek) | same 2.2 driver line as stock (2.2.813d11a, 2023-04); builds unpatched |

The exact stock Wi-Fi source (v5.13.5, Jan 2022) is not public. It comes from Rockchip's RV1106 IPC SDK, and none of the rockchip-linux/radxa/armbian kernel trees carry it; they all have v5.10.1. The public lwfinger/rtl8723ds is older still (v5.1.1.5, 2016). So the closest available source is the Rockchip v5.10.1 copy from the SDK. Mainline `rtw88_8723ds` only appeared in Linux 6.x and would need a backport plus a different userspace (no `RTL8723DS.ko` name, different behaviour), so it is not used.

Patch `0002` (8 files, no functional changes beyond API adaptation):
- `crc32` and `sha256_*` renames, to avoid name clashes with kernel headers
- `<uapi/linux/sched/types.h>` for `struct sched_param`
- `proc_ops` (5.6)
- `.update_mgmt_frame_registrations` (5.8), as a thin wrapper that keeps the old AUTH-only behaviour
- `MODULE_IMPORT_NS(VFS_internal_...)` for `filp_open`/`kernel_read`/`kernel_write`, like stock

Build options were matched to stock by comparing strings and symbols:
- generic Linux platform with `CONFIG_PLATFORM_ROCKCHIPS` (not the RK3188/Android profile)
- `CONFIG_IOCTL_CFG80211` + `RTW_USE_CFG80211_STA_EVENT`
- `CONFIG_RTW_DEBUG=n`, `CONFIG_PROC_DEBUG=n`, `CONFIG_WOWLAN=n`, `CONFIG_GPIO_WAKEUP=n`
- `MODULE_NAME=RTL8723DS`, efuse map path as stock

Result:

| | stock | ours |
|---|---|---|
| name | `RTL8723DS` | `RTL8723DS` |
| depends | `cfg80211` | `cfg80211` |
| import_ns | `VFS_internal_...` | `VFS_internal_...` |
| SDIO aliases | `024c:d723`, `d724` | `024c:d723`, `d724` |
| vermagic | same | same |
| stripped size | 1.37 MB | 1.40 MB |
| functions | 4 622 | 4 398 shared with stock |
| WOWLAN/debug strings | - | same counts as stock |
| embedded firmware | yes | yes |

`hci_uart.ko`: 97 shared functions with stock; the differences are a few rtk_coex/timer helpers. Alias, depends and vermagic are the same as stock.

Kernel side, all present:
- cfg80211/mac80211 (modules)
- BT core with BR/EDR/LE/RFCOMM (built in)
- `rfkill-rk` with `rfkill-wlan` + `rfkill-bt` + bluesleep `/proc/bluetooth/sleep/btwrite` (built in)
- UART1 = `ttyS1` via 8250-dw
- `wireless-wlan` / `wireless_bluetooth` nodes in the DT

All exports the two modules need are resolved (modpost clean). Both modules rebuild bit-identically.

### Remaining Wi-Fi/BT risks
- **Older Wi-Fi driver than stock:** Realtek base 2020 vs 2022, COEX 20200103 vs 20210106. It should work with the same wpa_supplicant/nl80211 flow, but behaviour around BT coexistence, power save and regulatory may differ. Not tested on hardware.
- **Rockchip glue at load time:** our build calls `rockchip_wifi_power(1)` / `rockchip_wifi_set_carddetect(1)` (the glue in `sdio_intf.c`); stock does not. On this board both are no-ops: there is no power GPIO in the DT, `vcc3v3-wifi` is always on, and `set_carddetect` returns 0 in this kernel.
- **MAC address source:** our build also asks `rockchip_wifi_mac_addr()` for a MAC from vendor storage before falling back to efuse. If Anycubic stored a Wi-Fi MAC there, ours would use it while stock may not.
- **Management frames:** the `.update_mgmt_frame_registrations` wrapper only forwards AUTH frame registration, as the old callback did. P2P/AP-mode probe-request reporting is untouched (already `#ifdef not_yet` in the driver).
- **BT driver age:** hci_uart 2.2.3634cd9 is about a year older than stock's 2.2.813d11a. `rtk_hciattach` and the firmware stay the stock userspace ones.

## What is still missing / open

1. **Wi-Fi / BT:** both modules build now (see the section above). Still open: a hardware test. A newer Wi-Fi driver would help if Rockchip's v5.13.x source turns up.
2. **Bluetooth userspace:** `rtk_hciattach` and the `rtlbt` firmware come from the stock ac_lib partition. For our own OS they have to be packaged, e.g. from `radxa/rkwifibt` / `radxa/rtkbt` (`rtk_hciattach` sources).
3. **Closed / prebuilt SDK modules:** `rockit.ko` and `mpp_vcodec.ko` (the SDK ships them as prebuilts/asm in `sysdrv/drv_ko`). Not needed for Klipper; only for camera encoding.
4. **Anycubic touch drivers missing from the public tree:** Hynitron CST7xx (`hyn,7xx`), TLSC6x and XPT7603 (`xptek`). Only the FocalTech driver (`focaltech,fts`) is built. Printers with a CST836U panel would have no touch. This needs Hynitron's public `hyn_cst7xx` driver or a rewrite.
5. **`charlie,spidev`:** stock spidev has an Anycubic compatible string. SPI1 is disabled in the stock DT, so nothing uses it. Nothing to do unless the devices behind it turn out to matter.
6. **Modules vs the stock rootfs:** if this kernel boots with the stock `system`/`oem` userspace, `/oem/usr/ko` modules have the same vermagic and no MODVERSIONS, so they *will load*. Struct layouts of our config can still differ (BT, timers, USB), so a mismatched module can crash. Safest first test: put our rebuilt `oem-ko/RTL8723DS.ko`, `hci_uart.ko`, `cfg80211.ko` (and the other modules from the tarball) in place of the stock ones, e.g. via a bind mount over `/oem/usr/ko`, so nothing stock-built runs on our kernel. Alternatively, test only to the shell on ttyFIQ0 and over USB Ethernet.
7. **Not checked on hardware:** panel/backlight, touch, eMMC HS200, SDIO, USB host with the GL850G hub, UART3/5 at 576000 to the MCUs, earlycon on UART2 alongside the FIQ debugger, reboot path.
8. Later, for our own OS: rootfs (Buildroot) with these modules, a dedicated defconfig (drop EVB camera/ISP/NPU modules if unused), cpufreq/vdd_arm and thermal (tsadc is disabled in stock) after measuring the regulator.
9. WSL prints harmless "clock skew" warnings during the build (WSL clock drift against the ext4 timestamps).

## Testing on the board (not done – needs a go-ahead)

Same procedure as the console test (docs/console-test.md): logger on J1 at 115200, then
`bash tools/flash_boot_slot.sh <ip> build/kernel/boot.img` (dry run), then `--write` into the **inactive** slot.
The A/B retry logic falls back to the other slot if ours does not finish booting. Expected on J1: DDR blob, then `Booting Linux on physical CPU 0x0` from earlycon, then `Registered fiq debugger ttyFIQ0`. Check `/proc/config.gz` and `uname -v` (timestamp = SDK commit date).

## First boot on hardware – WORKS (2026-10-20 18:33, test host board in the printer, slot B)
Written with `tools/flash_slot.sh <printer-ip> build/kernel/boot.img build/kernel/oem_ours.img --write`:
`boot_b` = our kernel (DTB bootargs + `panic=5 oops=panic`), `oem_b` = stock oem with our `RTL8723DS.ko` / `hci_uart.ko` / `cfg80211.ko` (`tools/build_oem_ours.sh`). Slot A stays stock. The previous `boot_b` / `oem_b` were saved in `dumps/*_before_flash_20261020_183147.img`.
- J1 console: DDR blob → earlycon `Booting Linux` → `Linux version 5.10.160 (kobra@shednaja) … #2 Sun, 22 Mar 2026` → `Registered fiq debugger ttyFIQ0` → stock userspace. **No panic or oops** in 5 min. Log: `logs/bootlog_ourkernel_slotB_20261020.log`.
- **Wi-Fi with our RTL8723DS v5.10.1 works**: wlan0 got <printer-ip>, SSH OK.
- BT: `hci_uart` (ours) loaded, `rtk_hciattach … /dev/ttyS1 rtk_h5` running.
- UI: `K3SysUi` running, DRM `fb0` bound to VOP + RGB. GoKlipper `ready`, `mcu` v2.0.12 / `nozzle_mcu` v2.0.13 connected over ttyS3/ttyS5, temperatures OK.
- Stock vendor modules from `/oem/usr/ko` (rockit, rknpu, mpp_vcodec, rga3, rkisp, rkcif, csi2-dphy, rk_dvbm) **also loaded on our kernel** without errors so far. They are prebuilt against the stock kernel, so this is a residual risk (see "still missing" item 6). For our own OS, build them from the SDK or drop them.
- Boot warnings compared with the stock-kernel boot log: same `failed to find panel` (-517, deferred, then bound), BT `clk_get failed`, squashfs xattrs, `cpu_leakage`, `hub doesn't have any ports`.
  **New:** `RK630 PHY stmmac-0:02: failed to read out thermal zone (-22)` once per second (271× in 5 min). The internal FE PHY driver polls a thermal zone that our config/DT doesn't provide. To fix: config (THERMAL / rockchip tsadc) or DT, or disable the unused GMAC.
- `/proc/config.gz` is present, but stock busybox has no `zcat`: use `gunzip -c`.

## Clean-up round (2026-10-21)
- **RK630 PHY log spam fixed:** the PHY service task read `soc-thermal` every second and logged `failed to read out thermal zone (-22)` (207 lines in about 3.5 min; 11 000+ per 3 h). `tsadc` is disabled (as in stock), so the zone has no sensor. The PHY only uses the temperature to choose its RX signal-detect config, which therefore never ran on stock either. `kernel/dts/rv1106g-kobra-s1.dts` now deletes `rockchip,thermal-zone` from `&rmii_phy`; the driver then skips the read. Only boot_b was rewritten (DTB change only). Checked: the property is gone in `/proc/device-tree`, one remaining boot-time `Error getting thermal zone, not yet ready?` (from probe, once), no more per-second lines; Klipper/HelixScreen/camera unaffected. Enabling `tsadc` instead would give a CPU temperature but changes what stock does; left for later.
- **Stock vendor modules:** our rootfs never loads them (only `cfg80211`, `RTL8723DS`, `hci_uart`, `ipv6` in `lsmod`; `S30kobra-modules` loads Wi-Fi only). The rockit/rknpu/mpp note above was from the test with the stock rootfs. They stay in `oem_ours.img` unused (oem partition, not the system slot).
- **Wi-Fi / BT check on our OS:** 3 h 10 min uptime with no disconnects in `dmesg`, link quality 86, -61 dBm; 300 pings from the PC: 0 % loss, avg 8 ms, max 605 ms (single spike); wlan0: 0 errors, 385 dropped of 980 k RX packets, 2.2 GB TX (camera stream). `regulatory.db` present, ntpd keeps the clock correct.

## Boot logo

`boot.img` carries the logo that U-Boot and the kernel show from power-on until HelixScreen
starts: `logo.bmp` and `logo_kernel.bmp` in the Rockchip resource (RSCE) next to
`rk-kernel.dtb`. `tools/build_kernel.sh` passes `kernel/logo/boot_logo.bmp` to
`tools/mkboot_kernel.py --logo`, which replaces both entries (stock: the Anycubic logo).
Format as in stock: 800x480, 8 bit with a 256-colour palette, uncompressed, stored upside
down (the panel is mounted rotated). The BMP is generated by `tools/make_update_splash.py`
together with the update screens. The stock slot keeps its own boot.img and logo.

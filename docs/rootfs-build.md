# Rootfs (system_a / system_b)

ShedNaja's system image: a read-only Buildroot squashfs with Klipper, Moonraker, Mainsail,
HelixScreen and the camera streamer, for the printer's `system_a` / `system_b` partitions
(48 MiB). It boots with our kernel ([kernel-build.md](kernel-build.md)) and keeps the stock
data partitions. Installing it on a printer: [update.md](update.md). How it got here, with
all the test results: [history/rootfs-build-log.md](history/rootfs-build-log.md).

## Build

```bash
bash tools/fetch_stock.sh             # once: stock boot image layout (kernel) and MCU dictionary (offline check)
bash tools/build_kernel.sh            # build/kernel/ (modules for the rootfs)
bash tools/build_rootfs.sh            # -> build/rootfs/rootfs.squashfs
bash rootfs/tests/offline_check.sh    # optional, see "Offline checks"
```

- Linux or WSL2 (from Git Bash the script re-runs itself in WSL Ubuntu-24.04). No sudo:
  Buildroot uses fakeroot.
- The first run downloads the sources into `~/kobra/br-dl` and builds the host tools; later
  runs are incremental. When `rootfs/configs/kobra_s1_defconfig` or the busybox fragment
  changes, the script starts from a clean output dir, because Buildroot does not rebuild a
  package when only its options change.
- Environment: `SDK_DIR`, `BT_DIR`, `BR_OUT` (default `~/kobra/rootfs-out`), `BR_DL`,
  `STOCK` (default `build/stock`), `JOBS`, `CLEAN=1`.
- The SDK checkout must be at the pinned commit, otherwise the build stops.
  `ALLOW_UNPINNED=1` builds anyway and appends `+unpinned` to the build id (also when
  `build/kernel` comes from such a kernel build). **Not for releases.**
- `SSH_KEY=<file.pub>` bakes that key into root's `authorized_keys` and appends `+devkey` to
  the build id (and the update bundle name). **For development only, never release such a
  build.** Without it (a release build) root's keys live in `/userdata/shednaja/ssh`.
- WSL2's clock is pulled back by Windows every few tens of seconds, which randomly breaks
  autoconf's sanity check or make's stamp order. The script recognises these failures, wipes
  only the affected package's build dir and retries (at most 5 times).

## Inputs (all pinned)

| What | Source |
|---|---|
| Buildroot | `buildroot-2023.02.6.tar.gz` from the Luckfox SDK (`sysdrv/tools/board/buildroot`, SDK @ `824b817f`), sha256 checked, extracted unpatched |
| Toolchain | the SDK's `arm-rockchip830-linux-uclibcgnueabihf` (gcc 8.3.0, uClibc-ng 1.0.31), same as the kernel and the stock userspace |
| Our tree | `rootfs/` = BR2_EXTERNAL `KOBRA`: `configs/kobra_s1_defconfig`, `board/kobra_s1/` (overlay, `post-build.sh`, `post-fakeroot.sh`, `busybox.fragment`, default printer config), `package/*` |
| Kernel modules | `build/kernel/modules-5.10.160.tar.gz` (ours) → `/lib/modules/5.10.160` |
| rtk_hciattach | `radxa/rkwifibt` @ `b61a1e84`, `tools/rtk_hciattach` |
| BT firmware | Realtek's `rtl8723d_fw` + `rtl8723d_config` from `radxa/rkwifibt`, as a fallback in `/usr/share/shednaja/rtlbt-fallback`. `/lib/firmware/rtlbt` → `/run/rtlbt`: `S42bluetooth` copies the printer's own stock files once from its stock `ac_lib` partition (mounted `ro,noload`) to `/userdata/shednaja/rtlbt` and uses them; the radxa config lacks two board entries (0x008d/0x008f) |
| Root password hash | generated: `openssl passwd -1 -salt shednaja rockchip` (default password `rockchip`, as on stock) |

## Packages and versions

| Component | Version / source | Notes |
|---|---|---|
| Klipper (klippy) | Kobra-S1/klipper-kobra-s1 @ `45f35e8c` (`V1.3.1-51-g45f35e8c`) | `rootfs/package/klipper`: `c_helper.so` cross-compiled, `.pyc` precompiled; patches: never rebuild chelper on a read-only install, no "recompile and flash" warning for the Anycubic MCU firmware |
| Klipper Linux MCU | same source, `CONFIG_MACH_LINUX` | `klipper-host-mcu`: host pins (light, buzzer) as `[mcu host]` |
| Moonraker | Arksine/moonraker v0.11.0 | |
| Mainsail, mainsail.cfg | 2.19.0, mainsail-config v1.2.1 | |
| HelixScreen | 1.0.6, official static armv7 build (`ad5m`) | pruned assets; [display-ui.md](display-ui.md) |
| mjpg-streamer | Buildroot (jacksonliam `5a6e0a2`) | `kobra-webcam`: only `input_uvc` + `output_http` |
| numpy | 1.23.5 (`kobra-numpy`) | for `SHAPER_CALIBRATE`; Buildroot's numpy needs glibc/musl, ours adds an ARM `fenv.h` and a uClibc patch |
| ACEPRO | Kobra-S1/ACEPRO V0.8.1 (`kobra-acepro`) | packaged, **inactive**; [peripherals.md](peripherals.md#ace-pro) |
| Python | 3.11.6 + zlib, sqlite3, ssl, lzma, ctypes; greenlet, cffi, pyserial, jinja2, markupsafe, tornado, pillow, distro, libsodium (Buildroot); streaming-form-data, inotify-simple, libnacl, importlib-metadata, zipp, dbus-fast (our packages, sha256 pinned) | `sitecustomize.py`: `ctypes.util.find_library()` and `os.getloadavg()` for uClibc |
| Base | busybox (+ ntpd, mdev, modprobe, i2c tools, rfkill, flock …), iproute2 (`ip -json` for Moonraker), dropbear 2022.83, wpa_supplicant 2.10, e2fsprogs (e2fsck), lighttpd 1.4.69, wireless-regdb | |

Not included on purpose: the Anycubic app/UI (`/ac_lib`, `/ac_app` are not mounted,
K3SysUi/GoKlipper never start), bluez userspace, the stock vendor modules (rockit, rknpu,
mpp…), rk_ota.

## What runs (busybox init)

| Script | What |
|---|---|
| `S00kobra-mounts` | `/dev/block/by-name/*` links; `oem_<slot>` → `/oem` (ro), `userdata` → `/userdata`, `useremain` → `/useremain` (ext4, `e2fsck -p`, then rw, then ro fallback). **Never formats** (stock does if a mount fails). Creates `/userdata/shednaja/{dropbear,seedrng,log,ssh}`, links `/etc/shadow` → `/userdata/shednaja/shadow`, fresh `/run/passwd` |
| `S10mdev`, `S01seedrng`, `S01syslogd`, `S02klogd`, `S02sysctl`, `S40network` | Buildroot defaults (camera/ISP/NPU modules blacklisted) |
| `S25kobra-usb` | USB hub on (gpio41, "usb sel"); without it nothing on USB enumerates |
| `S27kobra-usbupdate` | update bundle from a USB stick ([update.md](update.md)) |
| `S30kobra-modules` | `cfg80211`, `RTL8723DS` (Wi-Fi power saving off: `/etc/modprobe.d/kobra-wifi.conf`) |
| `S41wifi` | `wpa_supplicant` with the **stock** `/userdata/wifi_cfg/wpa_supplicant.conf`, `udhcpc` |
| `S42bluetooth` | firmware link (the printer's stock files, copied once from `ac_lib`, else the fallback), power cycle, `hci_uart`, `rtk_hciattach` → `hci0` (no bluez tools) |
| `S48ntpd` | waits for DNS, sets the clock once, then busybox ntpd |
| `S50dropbear` | SSH; host keys in `/userdata/shednaja/dropbear` |
| `S59klipper-mcu` | Klipper Linux MCU (`/tmp/klipper_host_mcu`) |
| `S60klipper` | MCU reset pulse (gpio116), klippy with `nice -10` |
| `S61moonraker` | Moonraker with `nice 5` |
| `S62lighttpd` | port 80: Mainsail, proxy to Moonraker and `/webcam/` |
| `S65webcam` | mjpg-streamer on 127.0.0.1:8080 (settings in `printer_data/config/webcam.conf`) |
| `S70helixscreen` | HelixScreen on the display (`HELIX_DISABLE_AUTO_UPDATES=1`) |
| `S99kobra-bootok` | marks the boot good for the A/B logic ([update.md](update.md#if-shednaja-does-not-start)) |

Getty on the serial console `ttyFIQ0` (J1, 115200). All services run as root, like stock.

## Files and persistent state

| Path | What |
|---|---|
| `/usr/lib/klipper/klippy`, `/usr/lib/moonraker`, `/usr/share/mainsail`, `/opt/helixscreen` | code, read-only |
| `/usr/share/shednaja/printer_data/config` | default config: `printer.cfg`, `kobra_s1.cfg` (hardware), `kobra_macros.cfg`, `kobra_peripherals.cfg`, `mainsail.cfg`, `moonraker.conf`, `webcam.conf`, ACEPRO's `ace_KS1.cfg` / `ace_macros_generic.cfg` |
| `/useremain/shednaja/printer_data/{config,logs,gcodes,database,comms}` | the live `printer_data`. `printer-data-init` copies **missing** default files on boot and never overwrites existing ones, so a new image does not change an existing config (see TODO). `/root/printer_data` links here |
| `/useremain/shednaja/helixscreen` | HelixScreen settings (touch calibration, wizard state) |
| `/useremain/shednaja/update` | update bundles, logs, lock |
| `/userdata/shednaja/` | SSH host keys, `ssh/authorized_keys`, `shadow` (root password), `rtlbt/` (the printer's BT firmware), random seed |
| `/userdata/wifi_cfg/wpa_supplicant.conf` | the stock Wi-Fi config, shared with stock |
| `/userdata/app/gk` | the stock GoKlipper tree: **never touched** |

Root password: `/etc/shadow` → `/run/shadow` → `/userdata/shednaja/shadow`, seeded from the
image default on first boot, so `passwd` works and the password survives updates (delete
the file and reboot to get the default back). `/etc/passwd` → `/run/passwd`, a fresh copy
of the image's file on every boot (busybox `passwd` rewrites it too).

## Klipper configuration

- `printer.cfg`: includes, MCU ports (`[mcu]` `/dev/ttyS3`, `[mcu nozzle_mcu]` `/dev/ttyS5`,
  576000 Bd, `restart_method: command`), and every value `SAVE_CONFIG` may change (PID,
  input shaper, probe `z_offset`). Klipper refuses to autosave an option that an included
  file also sets, so those live only here.
- `kobra_s1.cfg`: hardware. Pins, steppers, TMC, heaters, thermistors, fans, load cell and
  accelerometer are the values of the stock GoKlipper `printer.cfg` (2.7.2.7), checked pin by
  pin. Differences from stock: `probe_ks1` (the fork's load-cell probe module),
  `homing_override` (Y before X, Z in the bed centre at 1000 mm/s²), `bicubic` mesh with
  faulty regions, `[adc_filament_switch]` for the analog toolhead sensor, realistic
  `min_temp`, LIS2DW12 on hardware `spi_bus: spi2` (the Anycubic MCU firmware returns 0xff
  over software SPI).
- `kobra_macros.cfg`: `PRINT_START` / `PRINT_END`, `LOAD_FILAMENT` / `UNLOAD_FILAMENT`,
  `CUT_TIP`, runout/insert, wipe/purge positions, `M106/M107 P2/P3`, `SHEDNAJA_SETUP`
  (calibration dialog in Mainsail).
- `kobra_peripherals.cfg`: `[mcu host]`, chamber light, buzzer (`M300`), `[kobra_slot]` +
  `REBOOT_TO_STOCK`.
- `moonraker.conf`: `[machine] provider: none` (no systemd; Mainsail's service restart
  buttons do not work, use SSH; Reboot and Shutdown work through `/usr/bin/sudo`, a
  pass-through, since everything runs as root), `trusted_clients` = LAN ranges, `[history]`, `[octoprint_compat]`,
  `[webcam kobra_s1]`. No `update_manager`: updates come as images.

## Offline checks

`bash rootfs/tests/offline_check.sh` (WSL/Linux, qemu-arm-static, no printer) runs the
target's own binaries:
1. klippy in batch mode with the default config against the MCU data dictionary of the
   Anycubic firmware v1.4.3 (`build/stock/firmware_v1.4.3.dict`) for both MCUs and the
   `klipper_mcu` dictionary for `[mcu host]`, with a short G-code test.
2. Moonraker starts and `/server/info` lists no failed components.
3. lighttpd accepts its config and serves Mainsail, the proxy and the websocket upgrade.

Without a build (also in CI, `.github/workflows/checks.yml`, on every push):
`shellcheck --severity=error` on all shell scripts, Python syntax, `bash
rootfs/package/kobra-abctl/test/unit_test.sh` (A/B data on hand-made misc images) and
`python3 -m unittest discover -s rootfs/tests -p 'test_*.py'` (kobra_plr with stand-ins
for Klipper).

## Size and RAM

- `build/rootfs/manifest.txt` lists the size per package. The image is about 43 MiB of the
  48 MiB partition; HelixScreen (about 39 MB unpacked) and Mainsail are the largest parts.
- RAM on the printer (215 MB visible): about 155 MB available after boot with Klipper,
  Moonraker, HelixScreen and the camera. `SHAPER_CALIBRATE` peaks klippy at about 60 MB RSS.
- CPU: one Cortex-A7 core. The camera stream at 1280×720 plus HelixScreen showing it can
  starve klippy (`Timer too close`), hence `nice` for klippy and the 640×480 camera default.

## Known limits

- Default config changes do not reach printers that already have `printer_data` (TODO).
- No watchdog: a hang after `S99kobra-bootok` needs a power cycle.
- No authentication on the LAN (`trusted_clients`), like Rinkhals / stock.
- No USB stick automount for printing from a stick.

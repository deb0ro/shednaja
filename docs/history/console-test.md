# Enabling the UART2 console on the test host board (slot A)

> **Development log, not a how-to.** This page records an experiment or test from the
> development of ShedNaja (serial console on J1 with the stock kernel, 2026-10-20). Commands, slot names and file paths in it describe the
> setup at that time and can be wrong or **destructive** on a printer installed today (for
> example, writing "the inactive slot" can overwrite the stock fallback). Paths under `dumps/`,
> `logs/` and `build/` refer to unpublished development files. Current documentation:
> [docs/README.md](../README.md).

## What changes
`build/boot_console.img` (from `tools/fit_patch_console.py`) = stock kernel FIT where only the DTB is changed:
- `/serial@ff4c0000` (UART2 → `ttyS2`, pins GPIO1_B2/B3 = J1) `status = "okay"`
- bootargs: `earlycon=,mmio32,0xff4c0000 console=` → `console=ttyS2,115200n8`

Kernel and resource are bit-identical to stock. The FIT header differs only in the fdt sha256, and the DTB keeps its stock size (36917 B).
Verified: all three sha256 hashes match, and the round trip of the stock DTB is byte-identical.
U-Boot replaces `root=` with the slot's own partition, as it does in stock (we saw `root=/dev/mmcblk0p9` while the DT says p8).

**Build the image from the test board's own boot image**, not from the printer's. A different FW version could have kernel modules (Wi-Fi) that don't match the kernel.

## Prerequisite: SSH access to the test board
The procedure runs over SSH (dropbear from Rinkhals). Options:
1. Install Rinkhals on the test board the same way as on the printer (USB stick with `update.swu`). For Wi-Fi you need the display.
2. Swap the boards in the printer for a while (connectors only, no wiring changes).

## Procedure
1. **Back up the test board:** `bash tools/backup_emmc.sh <test-ip>`
2. **Build the image from its own boot:**
   `.venv\Scripts\python.exe -I tools\fit_patch_console.py dumps\emmc_<…>\boot_<active>.img build\boot_console_test.img`
3. **Dry run** (checks the active slot, partition size, saves the current inactive boot):
   `bash tools/flash_boot_slot.sh <test-ip> build/boot_console_test.img`
4. **Write** (inactive slot only + readback md5 + `rk_ota --misc=other --mode=retry`):
   `bash tools/flash_boot_slot.sh <test-ip> build/boot_console_test.img --write`
5. Start the UART logger on J1: `tools\uart_log.py COM8 --baud 115200` (CH340, RXD → J1 TX pad). Then reboot the board.

## Expected result and fallback
- From U-Boot up to the kernel you will still see nothing (SPL and U-Boot have the UART turned off). From the start of the kernel you should see the `Booting Linux…` log and later a login prompt or shell on ttyS2.
- The running slot (B) is untouched. The A/B logic in SPL (`tries_remaining`, `successful_boot`) falls back to slot B when slot A does not finish booting (`S99_bootcontrol` marks the slot). If slot A gets stuck, power-cycle the board a few times. Once the attempts run out, SPL boots B.
- Going back by hand: on a running system, `rk_ota --misc=other --mode=retry` switches back to the other slot, and `dumps/boot_a_before_flash_*.img` restores the original boot_a.
- Slot A runs the userspace from `system_a` / `ac_lib_a` / `ac_app_a`. On the printer, `ac_lib_a` is a different (older) app version than B, which is fine for testing the console.

## Result (2026-10-20, test board in the printer)
- First attempt: slot B booted, but nothing changed. **Rockchip U-Boot takes the DTB from `rk-kernel.dtb` inside the RSCE `resource` image, not from the FIT `fdt`.** `fit_patch_console.py` now patches both copies (same size, in-place).
- Second attempt: slot B boots with `console=ttyS2,115200n8`, `serial@ff4c0000` = okay, `ttyS2` exists (`ff4c0000.serial: ttyS2 … 16550A`).
- **J1 is UART2 (GPIO1_B2/B3)**, confirmed: text written to `/dev/ttyS2` arrives on the RPi Debug Probe (port U, COM3) at 115200.
- **The stock kernel still prints nothing to ttyS2**: `/proc/consoles` is empty. The kernel is built **without `SERIAL_8250_CONSOLE`** (no `serial8250_console_setup` / `univ8250_console_setup` in kallsyms). It has the Rockchip **FIQ debugger** console instead (`fiq_debugger_console_write`). The DT has no `fiq-debugger` node (removed by Anycubic).
- Options for a kernel log on J1:
  1. add a `fiq-debugger` node (rockchip,serial-id = <2>, UART2 disabled) + `console=ttyFIQ0`. This needs node insertion into the DTB, i.e. an RSCE rebuild. The GIC interrupt number has to come from the RV1106 SDK dtsi, not guessed.
  2. our own kernel (later phase) with `CONFIG_SERIAL_8250_CONSOLE=y` → full log from earlycon onward.
  3. right now: a getty/shell on `ttyS2` from userspace = a serial login for recovery when the network is down.
- Slot state: B (console image) active, A = stock. Previous boot_b saved in `dumps/boot_b_before_flash_*.img`.
- **Reboot capture (13:55, probe on the correct J1 pad, 115200):** the DDR init blob prints to J1:
  ```
  DDR V1.11 285bced5c1 wesley.yao 23/03/28-14:23:36
  S5P1 / f967 / F / DDRConf2
  DDR3, BW=16 Col=10 Bk=8 CS0 Row=14 CS=1 Die BW=16 Size=256MB
  924MHz
  DDR bin out
  ```
  Then silence: SPL and U-Boot have their console turned off, and the kernel has no 8250 console. The console runs at **115200**, not 1.5 M. That explains the earlier failed attempts (wrong rate / wrong pad). The board then boots normally into slot B.

## FIQ debugger console – WORKS (2026-10-20 14:00, slot B, `build/boot_fiq_test.img`)
- Built with `tools/fit_patch_console.py --mode fiq`: adds `/fiq-debugger` (from the RV1106 SDK `rv1106.dtsi` + `rv1106-evb.dtsi`: `rockchip,serial-id = <2>`, `irq-mode-enable = <1>`, `baudrate = <115200>`, `interrupts = <GIC_SPI 125 LEVEL_HIGH>`, `pinctrl-0 = <&uart2m1_xfer>`), UART2 stays disabled, `console=ttyFIQ0`. The DTB grew to 37181 B, which still fits the existing RSCE slot (37376 B).
- J1 @ 115200 now shows: the DDR blob → **full kernel log from `[0.000000] Booting Linux`** → init/eudev → GoKlipper/gkapi logs → Rinkhals start. Full log: `logs/bootlog_fiq_slotB_20261020.log` (71 KB).
- Kernel: `printk: console [ttyFIQ0] enabled`, `Registered fiq debugger ttyFIQ0`. `IRQ uart_irq not found` is expected in irq mode. No panic or oops, Klipper/Moonraker/UI running, SSH OK.
- SPL and U-Boot are still silent (their own UART is disabled in their builds). Not needed for now.
- Input: connecting probe TX (orange) to the J1 RX pad gives a FIQ debugger prompt (`console`, `help`, `sysrq`, …). No getty runs on ttyFIQ0 yet.
- Slot state: **B = FIQ console image (active)**, A = stock.

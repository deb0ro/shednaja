# Fáze 0: přístup a záloha (jen čtení)

> **Development log, not a how-to.** This page records an experiment or test from the
> development of ShedNaja (phase 0: read-only access and backup of the test boards, 2026-10-19/20; in Czech). Commands, slot names and file paths in it describe the
> setup at that time and can be wrong or **destructive** on a printer installed today (for
> example, writing "the inactive slot" can overwrite the stock fallback). Paths under `dumps/`,
> `logs/` and `build/` refer to unpublished development files. Current documentation:
> [docs/README.md](../README.md).

> Later results replace some conclusions below: the console on J1 runs at 115200 Bd (not 1.5 M),
> and the boot images are **not** signed (see [firmware-analysis.md](../firmware-analysis.md)).
> `.venv` is a Python virtual environment with `pyserial` (`python -m venv .venv` and
> `.venv\Scripts\pip install pyserial`).

Cíl: získat boot log hostitele a záložní kopii firmwaru MCU. Nic se nezapisuje.

## Napájení testovacích desek
- Spodní deska (NF031_LOWER) dostává **24 V** do konektoru `-24V+`. Použij laboratorní zdroj s proudovým limitem kolem 1 A. Motory, topení ani hlavu nepřipojuj.
- Horní deska (hostitel) se nejspíš napájí přes **plochý kabel ze spodní desky** (J1 dole ↔ J6 nahoře). Spoj obě desky originálním kabelem.
- Jiný zdroj napájení (ST-Link, USB-UART) **nepřipojuj na 3V3**. Propojuj jen GND a datové vodiče.

## A) UART log z hostitele (J1 „GND RX TX“ vpravo dole na horní desce)
1. Nejdřív multimetrem při zapnuté desce změř, že **TX vůči GND má zhruba 3,3 V** (klidová úroveň UARTu).
2. Zapoj: GND ↔ GND, **TX desky → RX převodníku**. TX převodníku zatím **nezapojuj** (jen posloucháme).
3. Převodník musí zvládnout **1 500 000 Bd**. To umí FT232R/FT232H, CP2102N, CH343 i **CH340G**, protože 1,5 M = 12 MHz / 8 je přesný dělič. Starý CP2102 to nezvládne (umí max. 1 Mbaud). U modulu s CH340G dej jumper do polohy **3V3**. Druhá možnost je port **„U“** na Raspberry Pi Debug Probe (3,3 V, TX/GND/RX), ten se v systému hlásí jako další COM port.
4. Spusť logger a potom zapni 24 V:
   ```
   .venv\Scripts\python.exe tools\uart_log.py --list
   .venv\Scripts\python.exe tools\uart_log.py COMx
   ```
   Když uvidíš nesmysly, použij `--autobaud` a během vzorkování desku několikrát resetuj.
5. Nech běžet zhruba 2 minuty, dokud nenaběhne UI. Log se uloží do `logs/`.

**Co z logu chceme:** verzi DDR/SPL/U-Bootu, jestli U-Boot ověřuje podpis („FIT: verified“, „secure boot“), dobu autobootu, příkazovou řádku jádra, verzi jádra, tabulku oddílů a jestli je na konzoli login nebo shell.

## B) SWD na MCU (GD32 na spodní desce)
1. **Najdi SWD piny.** Kandidátem je 5pinová ploška **P7** vedle krystalu Y4. Multimetrem (pípákem) proti nožičkám MCU v pouzdře LQFP64:
   - SWDIO = **pin 46** (PA13)
   - SWCLK = **pin 49** (PA14)
   - NRST = **pin 7**
   - GND = piny 12/18/31/47/63
   - 3V3 = piny 13/19/32/48/64
   - BOOT0 = pin 60 (jen pro zajímavost)

   Pin 1 je u tečky na pouzdře. Když P7 nesedí, hledej mezi testpointy vzadu (TP14–TP59).
2. Zapoj **Raspberry Pi Debug Probe**, port **„D“** (JST-SH, 3 piny), barvy kabelu podle dokumentace Raspberry Pi:
   - oranžová = SWCLK
   - černá = GND
   - žlutá = SWDIO

   Probe desku nenapájí a NRST nemá, to nevadí. Desku napájej z 24 V.
   S ST-Linkem zapoj GND, SWDIO a SWCLK a skriptu předej `-Probe stlink`.
3. Spusť:
   ```
   powershell -ExecutionPolicy Bypass -File tools\swd\dump_mcu.ps1
   ```
   Skript **nehaltuje jádro, nic nemaže a nic neodemyká**. Vypíše ID čipu, velikost flash, UID a option bytes. Když není zapnutá ochrana proti čtení (RDP), uloží celou flash do `dumps/`.
4. **Když hlásí RDP active, nic dalšího nedělej.** Odemčení RDP smaže celou flash, včetně proprietárního bootloaderu Anycubicu. Ten pak nebude čím nahradit, protože OTA flasher na něm závisí.

## Výsledky (sem doplníme)
- UART baud / log (2026-10-20): **J1 is silent.** Tried 1 500 000 Bd (RPi Debug Probe, both signal pads) and 115 200 Bd (CH340G). Each run captured only 11–16 bytes of power-on glitches (`logs/`). The signal pad idles high after power-on and the CH340 RX LED never flickers. The board boots (LED, buzzer beeps after ~1 min). Conclusion: console probably disabled in the Anycubic firmware (DDR loader, U-Boot and kernel), or J1 is not the console UART. Next: read `/proc/cmdline`, `dmesg`, `fw_printenv` and the DT over SSH on the live printer (Rinkhals).
- Live system over SSH (2026-10-20, FW 2.7.2.7, Rinkhals 20260716_02, raw output in `logs/printer_info*_20261020.txt`):
  - Kernel `5.10.160`. DT `rockchip,rv1106g-38x38-ipc-v10-spi-nand`, i.e. the Rockchip EVB "IPC38" DTS with small changes, which makes porting easier.
  - Cmdline `console=` (empty) → **kernel console disabled**. UART0 (ff4a0000) and UART2 (ff4c0000) have `status=disabled` in DT. No ttyFIQ (fiq-debugger off). That explains the silent J1.
  - UARTs in use: `ttyS1` = Bluetooth (RTL8723DS, H5 @115200); `ttyS3` + `ttyS5` = opened by klippy → the two MCUs (motion board + toolhead).
  - USB: the RV1106 OTG port runs as **host** → GL850G hub (05e3:0610) → camera (SunplusIT 13d3:784b). For maskrom, the same D+/D− is needed (only one USB2 on the SoC).
  - eMMC 7.28 GiB (CID name `S03611`). A/B active slot **B** (`root=/dev/mmcblk0p9`). uboot_a == uboot_b and boot_a == boot_b (same md5).
  - RAM: 217 MB visible. ~100 MB free with gkapi + K3SysUi + vanilla klippy + moonraker running.
  - U-Boot env (`env` part, 32K): just `blkdevparts`, `sys_bootargs`, `sd_parts`. No fw_printenv binary.
- **eMMC backup (2026-10-20):** `dumps/emmc_20261020_095608/`, made with `tools/backup_emmc.sh` over SSH. 16 partitions (all except `useremain`) + the first 32 KB of the raw disk, 1.4 GB total. **All 16 md5 checks OK** (`md5.txt`). Note: `userdata` and `ac_*` were mounted read-write during the dump, so they are a live snapshot. The bootloader/kernel/rootfs partitions are read-only and exact. Identical pairs: uboot_a=b, boot_a=b, system_a=b, oem_a=b. ac_lib and ac_app differ between A and B.
- Secure boot: **partially.** boot_a/b is a **signed FIT** (`sha256,rsa2048`, `signature`, `key-name-hint`). U-Boot contains a `signature` node, `rollback-index` and `rockchip,rv1106-secure-otp`; no `required` string found. Non-secure OTP readable (`rockchip-otp0`), secure-OTP state unknown from Linux (no OP-TEE device). → Whether BootROM/U-Boot **enforce** signatures has to be tested on the test board once maskrom recovery works.
- **MCU over SWD (2026-10-20), test board NF031_LOWER_V2.2:**
  - Normal attach fails (`cannot read IDR`): the firmware disables or remaps SWD at runtime. It **works with manual connect-under-reset**: hold P7 pad 5 (NRST) to pad 2 (GND), run `tools/swd/gd32_under_reset.cfg`, release when prompted. The vector catch halts the core before the firmware runs.
  - DPIDR `0x2ba01477`, CPU **Cortex-M4 r0p1** (CPUID `0x410FC241`), DBGMCU_IDCODE `0x21040414` (dev id 0x414 = GD32F30x high-density), flash-size register **128 KB**.
  - **RDP off** (option byte RDP = `0x5AA5`, OBR = `0x03FFFFFC`), **no write protection** (WRPR = `0xFFFFFFFF`).
  - Dump: `dumps/mcu_ur_20261020_111219_flash.bin` (128 KB, SHA256 `62b05a34…42cfaebe`), plus `_sysmem.bin`. The 128 KB above the reported size reads back as all 0xFF.
  - Flash map:

    | Range | Size | Content |
    |---|---|---|
    | 0x08000000–0x08003000 | 12 KB | Anycubic bootloader (SP 0x20001070, reset 0x08000149; strings "ota data check error", "ota data flash write error") |
    | 0x08003000–0x08008000 | 20 KB | empty |
    | 0x08008000–0x0800F000 | 28 KB | application = Klipper MCU (SP 0x20005000, reset 0x0800BE95; strings "CanBoot!", "Request Serial Bootloader!! ~") → app offset **0x8000** |
    | 0x0800F000–0x0801E000 | 60 KB | empty (OTA staging bank?) |
    | 0x0801E000–0x0801E800 | 2 KB | data (OTA/config metadata?) |
    | 0x0801F800–0x08020000 | 2 KB | data (last page – flags/calibration?) |

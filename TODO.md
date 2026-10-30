# TODO

## Before going public

- Rename the local repository folder (still `KobraS1_` + the old name) and pick the
  remote name `shednaja`. The project itself is renamed to ShedNaja (2026-10-22).
- From the external review, still open before a community alpha:
  - long tests: unload, cancel, a long print with
    the display and the camera in use (CPU load)
  - MCU: stock v1.4.3 is the default; v2.0.13 (CS1237 calibration port) stays an optional
    experiment for the toolhead MCU only, its flow/PA calibration is not verified
- Announcement post (why, what works, what does not; README.md has the facts).
- The README's apt package list on a fresh Linux install (the clean-clone build of
  2026-10-22 ran in a WSL that already had every package).
- Root password: every interactive login asks for a new one while it is the default
  `rockchip` (`/etc/profile.d/shednaja-password.sh`); non-interactive SSH (scp, commands)
  and the web UI do not. A per-printer password (shown on the display) would close it.

## Open items

- Run Klipper and Moonraker as an unprivileged user: both run as root, and their configs
  are editable over the web without a login (README "Security").

- Config on installed printers: test `kobra-config-migrate` on the development printer
  (its copies may predate the public history and then count as edited: `--force`), and
  check Mainsail with the read-only `config/shednaja/` link.
- Maskrom: SW1 pulls SARADC_IN0 to 0 V (measured 2026-10-27, docs/hardware.md). Still open:
  find the RV1106 USB OTG lines (the SoC USB goes through gpio41 "usb sel" to the GL852G hub
  U11, upstream DM0/DP0 = QFN pins 1/2; "USB" pads on the back of the upper board), then power on with SW1 held and the pads on a PC: does
  `2207:110c` (maskrom/loader) appear?
- ACE Pro: driver (`kobra-acepro`, inactive), T0-T3 macros, Spoolman per slot.
- A/B update variant with our system in both slots.
- Recovery without network: a way back to stock when ShedNaja boots but neither the web UI,
  the display nor SSH works (USB stick trigger or a button); a watchdog for hangs.
- ACE Pro: port the ACEPRO macro calls (`TO_THROW_POSITION`, `FLUSH_POOP`, ...) to
  `kobra_macros.cfg`.
- Printing: Z-offset fine tuning, flow and pressure advance calibration, UNLOAD_FILAMENT test, back-left bed corner (about 0.87 mm low).

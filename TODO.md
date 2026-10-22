# TODO

## Before going public

- Rename the local repository folder (still `KobraS1_` + the old name) and pick the
  remote name `shednaja`. The project itself is renamed to ShedNaja (2026-10-22).
- From the external review, still open before a community alpha:
  - long tests: unload, cancel, a long print with
    the display and the camera in use (CPU load)
  - MCU: stock v1.4.3 is the default; v2.0.13 (CS1237 calibration port) stays an optional
    experiment for the toolhead MCU only, its flow/PA calibration is not verified
- Release images: `oem_ours.img` is the stock oem image with three modules replaced, so a
  published installer redistributes Anycubic/Rockchip userspace. Either ship only the
  build (users run `tools/fetch_stock.sh`), or get the oem content cleared / rebuild it
  from sources. Same question for the stock BT firmware in the rootfs.
- Announcement post (why, what works, what does not; README.md has the facts).
- The README's apt package list on a fresh Linux install (the clean-clone build of
  2026-10-22 ran in a WSL that already had every package).
- Root password: a release could force a password change on first login (now the stock
  default `rockchip` stays until the owner runs `passwd`).

## Open items

- Config files on installed printers: `printer-data-init` only adds missing files, so new
  sections in `kobra_*.cfg` (e.g. `[kobra_slot]`) do not reach printers that are already
  set up. Split shipped config (read-only, updated with the image) from user config.
- Maskrom: test whether SW1 on the upper board pulls SARADC_IN0 low (read
  `in_voltage0_raw` while pressing it), find the RV1106 USB OTG lines (the SoC USB goes
  through the GL850G hub; "USB" test pads on the back of the upper board).
- ACE Pro: driver (`kobra-acepro`, inactive), T0-T3 macros, Spoolman per slot.
- A/B update variant with our system in both slots.
- Recovery without network: a way back to stock when ShedNaja boots but neither the web UI,
  the display nor SSH works (USB stick trigger or a button); a watchdog for hangs.
- ACE Pro: port the ACEPRO macro calls (`TO_THROW_POSITION`, `FLUSH_POOP`, ...) to
  `kobra_macros.cfg`.
- Printing: Z-offset fine tuning, flow and pressure advance calibration, UNLOAD_FILAMENT test, back-left bed corner (about 0.87 mm low).

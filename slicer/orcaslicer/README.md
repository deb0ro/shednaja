# OrcaSlicer profile for ShedNaja

Kobra S1 profiles made for the Anycubic firmware (or Rinkhals + vanilla Klipper) carry their
own start sequence: nozzle wipes, `M420 S1`, `:complex wipe` lines, a blob and purge line,
and then `G9111` (the Anycubic-slicer macro of vanilla-klipper), which homes, wipes, probes
and purges a second time. ShedNaja uses plain Klipper macros instead: `PRINT_START` /
`PRINT_END` in `kobra_macros.cfg`; `M420`/`M601`/`G9111` do not exist, and the layer
number never reached Klipper.

## Based on

The ShedNaja profile is made from **MPC561's Kobra S1 OrcaSlicer profiles**
([MPC561/Anycubic-Kobra-S1-Orcaslicer-Profiles](https://github.com/MPC561/Anycubic-Kobra-S1-Orcaslicer-Profiles),
bundle "Anycubic Kobra S1 0.4 nozzle - MPC561 - New Startcode 2.0"): PETG, ABS, ASA and PLA
filament presets and 0.08–0.24 mm Standard / Medium / Structural process presets, which MPC561
based on the Prusa MK4S profiles. They inherit from OrcaSlicer's built-in
"Anycubic Kobra S1 0.4 nozzle" system profiles. ShedNaja changes only the printer preset's
G-code (below); filament and process settings are MPC561's.

MPC561's repository has no licence, so the converted bundle is not published here. Download
their bundle and convert it yourself. MPC561's "New Startcode 2.0" needs their enhanced
nozzle wiper; the ShedNaja printer preset replaces that start code with `PRINT_START`, which
uses the stock wiper.

## Converting

`tools/make_orca_bundle.py` converts an exported printer bundle into a ShedNaja one and keeps
everything else (machine limits, retraction, all filament and process presets):

```
python tools/make_orca_bundle.py "<exported>.orca_printer"
```

Use MPC561's `.orca_printer` file directly, or export your own: printer preset > Export >
"Printer config bundle". The result is
`build/slicer/Kobra S1 ShedNaja 0.4 nozzle.orca_printer`; import it with File > Import > Import
Configs. The printer preset is named "Kobra S1 ShedNaja 0.4 nozzle", and the `rename` pairs in
`printer_overrides.json` rename the filament and process presets (" - MPC561" becomes
" - ShedNaja"), so they sit next to the originals.
The keys it sets are in `printer_overrides.json`:

| Field | ShedNaja value |
|---|---|
| Start G-code | `SET_PRINT_STATS_INFO TOTAL_LAYER=…`, `PRINT_START BED=… EXTRUDER=…` (the 3 min bed settle above 80 °C is in the macro) |
| End G-code | `PRINT_END` |
| Pause G-code | `PAUSE` (was `M601`) |
| Change filament | `T[next_extruder]`: only for multi-colour prints with an ACE Pro, which ShedNaja does not support yet ([docs/peripherals.md](../../docs/peripherals.md#ace-pro)); single-filament prints never emit it |
| After layer change | `SET_PRINT_STATS_INFO CURRENT_LAYER=…` (layer shown in Mainsail/HelixScreen) |

Physical printer in OrcaSlicer: Host type **Octo/Klipper**, hostname = printer IP.
Keep "Label objects" on: `PRINT_START`'s adaptive bed mesh (`BED_MESH_CALIBRATE ADAPTIVE=1`) uses the object outlines.

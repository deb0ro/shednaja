# OrcaSlicer profile for ShedNaja

Kobra S1 profiles made for the Anycubic firmware (or Rinkhals + vanilla Klipper) carry their
own start sequence: nozzle wipes, `M420 S1`, `:complex wipe` lines, a blob and purge line,
and then `G9111` (the Anycubic-slicer macro of vanilla-klipper), which homes, wipes, probes
and purges a second time. ShedNaja uses plain Klipper macros instead: `PRINT_START` /
`PRINT_END` in `kobra_macros.cfg`; `M420`/`M601`/`G9111` do not exist, and the layer
number never reached Klipper.

`tools/make_orca_bundle.py` converts an exported printer bundle into a ShedNaja one and keeps
everything else (machine limits, retraction, all filament and process presets):

```
python tools/make_orca_bundle.py "<exported>.orca_printer"
```

Export in OrcaSlicer: printer preset > Export > "Printer config bundle". The result is
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

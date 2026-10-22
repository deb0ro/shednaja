#!/usr/bin/env python3
"""Turn an OrcaSlicer printer bundle (.orca_printer) made for the Anycubic firmware into one
for ShedNaja (native Klipper).

    python tools/make_orca_bundle.py "<exported>.orca_printer" [out.orca_printer]

The printer preset gets the keys from slicer/orcaslicer/printer_overrides.json (start/end/
pause/layer G-code for our macros) and the name "printer_name" from there, so it can live next
to the original in OrcaSlicer. Filament and process presets keep their settings; the
"rename" pairs (e.g. " - MPC561" -> " - ShedNaja") are applied to their names, file names and
every reference between presets. G-code fields in filament/process presets are listed so
they can be checked by hand.
Default output: build/slicer/<printer_name>.orca_printer. Import: File > Import > Import Configs.
"""
import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    ov = json.load(open(os.path.join(ROOT, "slicer", "orcaslicer", "printer_overrides.json"),
                        encoding="utf-8"))
    zin = zipfile.ZipFile(src)
    files = {n: zin.read(n) for n in zin.namelist()}
    bs = json.loads(files.pop("bundle_structure.json"))
    old_name = bs["printer_preset_name"]
    new_name = ov["printer_name"]
    pairs = [(old_name, new_name)] + list(ov.get("rename", {}).items())

    def ren(v):
        if isinstance(v, str):
            for a, b in pairs:
                v = v.replace(a, b)
            return v
        if isinstance(v, list):
            return [ren(x) for x in v]
        if isinstance(v, dict):
            return {k: ren(x) for k, x in v.items()}
        return v

    out_files = {}
    changed = []
    for n, data in files.items():
        d = ren(json.loads(data))
        if n.startswith("printer/"):
            for k, v in ov["keys"].items():
                if d.get(k) != v:
                    changed.append(k)
                d[k] = v
        else:
            for k, v in d.items():
                if "gcode" in k and v not in ("", [""], []):
                    print("check by hand: %s: %s = %r" % (n, k, v))
        out_files[ren(n)] = json.dumps(d, indent=4, ensure_ascii=False).encode("utf-8")
    files = out_files
    bs = ren(bs)
    bs["bundle_id"] = "_" + new_name
    files["bundle_structure.json"] = json.dumps(bs, ensure_ascii=False).encode("utf-8")

    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        ROOT, "build", "slicer", new_name + ".orca_printer")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for n in sorted(files):
            z.writestr(n, files[n])
    print("printer preset: %s" % new_name)
    print("changed keys: %s" % ", ".join(changed))
    print("filament presets: %d, process presets: %d" % (
        len(bs.get("filament_config", [])), len(bs.get("process_config", []))))
    print("wrote %s" % out)


if __name__ == "__main__":
    main()

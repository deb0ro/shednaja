#!/usr/bin/env python3
"""Extract the Klipper data dictionary from an MCU firmware image.

The dictionary is a zlib stream inside the image (Klipper's compiled-in
"identify" data). Used for the Anycubic firmware from the official update, so
klippy can be checked offline against the commands the printer's MCUs speak.

    python3 -I tools/mcu_dict.py firmware_v1.4.3_20260303.bin out.dict
"""
import json
import sys
import zlib


def find_dict(data):
    for i in range(len(data) - 1):
        if data[i] != 0x78 or data[i + 1] not in (0x01, 0x5e, 0x9c, 0xda):
            continue
        try:
            raw = zlib.decompressobj().decompress(data[i:])
            d = json.loads(raw)
        except (zlib.error, ValueError):
            continue
        if isinstance(d, dict) and "commands" in d and "version" in d:
            return i, d
    return None, None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    off, d = find_dict(data)
    if d is None:
        sys.exit("no data dictionary found in " + sys.argv[1])
    with open(sys.argv[2], "w") as f:
        json.dump(d, f, indent=1, sort_keys=True)
        f.write("\n")
    print("dictionary at 0x%x: %s, %d commands" % (off, d["version"], len(d["commands"])))


if __name__ == "__main__":
    main()

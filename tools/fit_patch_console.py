"""Rebuild the Kobra S1 kernel FIT (boot_a/boot_b) with a serial console on UART2 (J1).

  .venv\\Scripts\\python.exe -I tools\\fit_patch_console.py <in boot.img> <out boot.img> [--mode ttys2|fiq] [--baud 115200]

Changes only the kernel DTB (both the FIT `fdt` image and `rk-kernel.dtb` inside the
RSCE `resource` image – Rockchip U-Boot boots with the latter):
  --mode ttys2 : /serial@ff4c0000 status -> "okay", console=ttyS2,<baud>n8
                 (the stock kernel has no 8250 console, so this only gives a tty)
  --mode fiq   : adds /fiq-debugger as in the RV1106 SDK (rv1106.dtsi + rv1106-evb.dtsi:
                 serial-id 2, irq-mode, GIC_SPI 125), UART2 stays disabled, console=ttyFIQ0
In both modes the blanked `earlycon=` is dropped. Kernel image is copied byte-for-byte.
Both FIT header and DTB are edited with tools/fdtpatch.py (keeps reserve map/strings).
Layout follows the stock image: external data, 512-byte aligned, header region 2048 B,
totalsize aligned to 4 KiB. The stock FIT is unsigned, so no signing is needed.
"""
import argparse
import hashlib
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdtpatch import add_node, cstr, read_props, set_props, u32s  # noqa: E402

ALIGN = 512
HEADER_ROOM = 2048
ORDER = ["fdt", "kernel", "resource"]
NUL = bytes(1)


def align(v, a):
    return (v + a - 1) // a * a


def u32(b):
    return struct.unpack(">I", b)[0]


def patch_dtb(dtb, baud, mode):
    props = read_props(dtb)
    args = props["/chosen"]["bootargs"].rstrip(NUL).decode()
    new = re.sub(r"\bearlycon=\S*\s*", "", args)
    console = f"console=ttyS2,{baud}n8" if mode == "ttys2" else "console=ttyFIQ0"
    new, n = re.subn(r"\bconsole=\S*", console, new)
    if n != 1:
        sys.exit(f"expected exactly one console= in bootargs, found {n}: {args!r}")
    print(f"bootargs: {args!r}\n      -> {new!r}")
    if mode == "ttys2":
        return set_props(dtb, {
            ("/serial@ff4c0000", "status"): cstr("okay"),
            ("/chosen", "bootargs"): cstr(new),
        })
    if "/fiq-debugger" in props:
        sys.exit("DTB already has /fiq-debugger")
    if props["/serial@ff4c0000"]["status"].rstrip(NUL) != b"disabled":
        sys.exit("expected UART2 disabled in the stock DTB")
    pin = props["/pinctrl/uart2/uart2m1-xfer"]["phandle"]
    dtb = set_props(dtb, {("/chosen", "bootargs"): cstr(new)})
    return add_node(dtb, "/", "fiq-debugger", [
        ("compatible", cstr("rockchip,fiq-debugger")),
        ("rockchip,serial-id", u32s(2)),
        ("rockchip,wake-irq", u32s(0)),
        ("rockchip,irq-mode-enable", u32s(1)),
        ("rockchip,baudrate", u32s(baud)),
        ("interrupts", u32s(0, 125, 4)),          # GIC_SPI 125 IRQ_TYPE_LEVEL_HIGH
        ("pinctrl-names", cstr("default")),
        ("pinctrl-0", pin),                       # &uart2m1_xfer (GPIO1_B2/B3 = J1)
        ("status", cstr("okay")),
    ])


def patch_rsce_dtb(res, old_dtb, new_dtb):
    """Replace rk-kernel.dtb inside a Rockchip RSCE resource image (512-byte blocks,
    'ENTR' index entries: name[256], u32le block offset, u32le size, no hash)."""
    if res[:4] != b"RSCE":
        sys.exit("resource image is not RSCE")
    entries = []
    off = 512
    while res[off:off + 4] == b"ENTR":
        name = res[off + 4:off + 260].split(NUL)[0].decode()
        blk, size = struct.unpack_from("<II", res, off + 260)
        entries.append((off, name, blk, size))
        off += 512
    for off, name, blk, size in entries:
        if name != "rk-kernel.dtb":
            continue
        start = blk * 512
        if res[start:start + size] != old_dtb:
            sys.exit("rk-kernel.dtb in resource differs from the FIT fdt - refusing")
        nxt = min([b for _, _, b, _ in entries if b > blk] or [len(res) // 512])
        room = (nxt - blk) * 512
        if len(new_dtb) > room:
            sys.exit(f"patched DTB {len(new_dtb)} B does not fit the {room} B resource slot")
        out = bytearray(res)
        out[start:start + room] = new_dtb + bytes(room - len(new_dtb))
        struct.pack_into("<I", out, off + 264, len(new_dtb))
        print(f"patched rk-kernel.dtb in resource (block {blk}, {size} -> {len(new_dtb)} B, room {room})")
        return bytes(out)
    sys.exit("rk-kernel.dtb not found in resource")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--mode", choices=["ttys2", "fiq"], default="ttys2")
    a = ap.parse_args()

    img = open(a.inp, "rb").read()
    hdr = img[:u32(img[4:8])]
    props = read_props(hdr)

    blobs = {}
    for name in ORDER:
        pr = props[f"/images/{name}"]
        pos, size = u32(pr["data-position"]), u32(pr["data-size"])
        blob = img[pos:pos + size]
        if hashlib.sha256(blob).digest() != props[f"/images/{name}/hash"]["value"]:
            sys.exit(f"input hash mismatch for {name}")
        blobs[name] = blob

    orig_fdt = blobs["fdt"]
    blobs["fdt"] = patch_dtb(orig_fdt, a.baud, a.mode)
    blobs["resource"] = patch_rsce_dtb(blobs["resource"], orig_fdt, blobs["fdt"])

    changes, pos, layout = {}, HEADER_ROOM, {}
    for name in ORDER:
        layout[name] = pos
        changes[(f"/images/{name}", "data-position")] = u32s(pos)
        changes[(f"/images/{name}", "data-size")] = u32s(len(blobs[name]))
        changes[(f"/images/{name}/hash", "value")] = hashlib.sha256(blobs[name]).digest()
        end = pos + len(blobs[name])
        pos = align(end, ALIGN)
    total = align(end, 4096)
    changes[("/", "totalsize")] = u32s(total)
    new_hdr = bytearray(set_props(hdr, changes))
    # Rockchip mkimage leaves a small record in the FIT header's free space
    # (stock: u32le 0x14, 0x04, <fdt data-size> at 0x500). Keep it and update the size.
    o_strings, o_size = u32(hdr[12:16]), u32(hdr[32:36])
    used = o_strings + o_size
    if len(new_hdr) == len(hdr) and u32(new_hdr[12:16]) == o_strings:
        new_hdr[used:] = hdr[used:]
        old_fdt = struct.pack("<I", u32(props["/images/fdt"]["data-size"]))
        i = new_hdr.find(old_fdt, used)
        if i >= 0:
            new_hdr[i:i + 4] = struct.pack("<I", len(blobs["fdt"]))
            print(f"updated Rockchip header record at {i:#x}: fdt size {len(blobs['fdt'])}")
    new_hdr = bytes(new_hdr)
    if len(new_hdr) > HEADER_ROOM:
        sys.exit(f"FIT header grew to {len(new_hdr)} B, more than {HEADER_ROOM}")

    out = bytearray(total)
    out[:len(new_hdr)] = new_hdr
    for name in ORDER:
        out[layout[name]:layout[name] + len(blobs[name])] = blobs[name]
    open(a.out, "wb").write(out)
    print(f"wrote {a.out}: {len(out)} B, header {len(new_hdr)} B (stock {len(hdr)} B), "
          f"sha256 {hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()

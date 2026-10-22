"""Build a Kobra S1 kernel FIT (boot_a/boot_b) from our own zImage + DTB.

  python -I tools/mkboot_kernel.py [--logo boot_logo.bmp] <stock boot.img> <zImage> <dtb> <out boot.img>

Uses the stock FIT as a template (same nodes, load/entry addresses, unsigned
`signature` stub, Rockchip header record) and replaces:
  - /images/kernel   -> our zImage (compression "none", self-decompressing, like stock)
  - /images/fdt      -> our DTB
  - /images/resource -> stock RSCE rebuilt with our DTB as rk-kernel.dtb; with --logo,
                        logo.bmp and logo_kernel.bmp (U-Boot and kernel boot logo) are
                        replaced by that BMP (same format as stock: 800x480, 8 bit with a
                        palette, stored upside down); other entries are copied unchanged.
Rockchip U-Boot boots with rk-kernel.dtb from the resource, not the FIT fdt, so both
copies must be the same. Layout = stock: external data, 512-byte aligned, header room
2048 B, totalsize aligned to 4 KiB. sha256 hashes are recomputed (stock FIT is unsigned).
"""
import argparse
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdtpatch import read_props, set_props, u32s  # noqa: E402

ALIGN = 512
HEADER_ROOM = 2048
ORDER = ["fdt", "kernel", "resource"]
BLK = 512
NUL = bytes(1)


def align(v, a):
    return (v + a - 1) // a * a


def u32(b):
    return struct.unpack(">I", b)[0]


def rsce_entries(res):
    """[(name, data)] from a Rockchip RSCE resource image."""
    if res[:4] != b"RSCE":
        sys.exit("resource image is not RSCE")
    hdr_blks, tbl_off, ent_blks = res[8], res[9], res[10]
    n = struct.unpack_from("<I", res, 12)[0]
    if (hdr_blks, tbl_off, ent_blks) != (1, 1, 1):
        sys.exit(f"unexpected RSCE header layout {hdr_blks, tbl_off, ent_blks}")
    out = []
    for i in range(n):
        off = (tbl_off + i) * BLK
        if res[off:off + 4] != b"ENTR":
            sys.exit(f"RSCE entry {i} has no ENTR tag")
        name = res[off + 4:off + 260].split(NUL)[0].decode()
        blk, size = struct.unpack_from("<II", res, off + 260)
        out.append((name, res[blk * BLK:blk * BLK + size]))
    return res[:BLK], out


def rsce_build(header, entries):
    """Tightly packed RSCE as made by Rockchip resource_tool: header block, one block per
    index entry, then each file padded to 512 B (no per-file hash, like stock)."""
    hdr = bytearray(header)
    struct.pack_into("<I", hdr, 12, len(entries))
    tbl, data = bytearray(), bytearray()
    blk = 1 + len(entries)
    for name, blob in entries:
        e = bytearray(BLK)
        e[0:4] = b"ENTR"
        nb = name.encode()
        e[4:4 + len(nb)] = nb
        struct.pack_into("<II", e, 260, blk + len(data) // BLK, len(blob))
        tbl += e
        data += blob + bytes(-len(blob) % BLK)
    return bytes(hdr) + bytes(tbl) + bytes(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("template", help="stock boot.img (boot_a/boot_b dump)")
    ap.add_argument("zimage")
    ap.add_argument("dtb")
    ap.add_argument("out")
    ap.add_argument("--logo", help="BMP for logo.bmp and logo_kernel.bmp")
    a = ap.parse_args()

    img = open(a.template, "rb").read()
    hdr = img[:u32(img[4:8])]
    props = read_props(hdr)

    blobs = {}
    for name in ORDER:
        pr = props[f"/images/{name}"]
        pos, size = u32(pr["data-position"]), u32(pr["data-size"])
        blob = img[pos:pos + size]
        if hashlib.sha256(blob).digest() != props[f"/images/{name}/hash"]["value"]:
            sys.exit(f"template hash mismatch for {name}")
        blobs[name] = blob
    if props["/images/kernel"]["compression"].rstrip(NUL) != b"none":
        sys.exit("template kernel is not compression=none")

    zimg = open(a.zimage, "rb").read()
    if struct.unpack_from("<I", zimg, 0x24)[0] != 0x016F2818:
        sys.exit("kernel is not an ARM zImage (magic at 0x24 missing)")
    dtb = open(a.dtb, "rb").read()
    if dtb[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("dtb has no FDT magic")

    rhdr, entries = rsce_entries(blobs["resource"])
    names = [n for n, _ in entries]
    if "rk-kernel.dtb" not in names:
        sys.exit("rk-kernel.dtb not in stock resource")
    entries = [(n, dtb if n == "rk-kernel.dtb" else b) for n, b in entries]
    if a.logo:
        logo = open(a.logo, "rb").read()
        if logo[:2] != b"BM" or struct.unpack_from("<iiHH", logo, 18) != (800, 480, 1, 8):
            sys.exit("logo is not an 800x480 8-bit BMP")
        entries = [(n, logo if n in ("logo.bmp", "logo_kernel.bmp") else b)
                   for n, b in entries]
    print("resource: " + ", ".join(f"{n} {len(b)} B" for n, b in entries))

    old_fdt_size = len(blobs["fdt"])
    blobs.update(fdt=dtb, kernel=zimg, resource=rsce_build(rhdr, entries))

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
    # Rockchip mkimage record in the header free space (stock: u32le 0x14, 0x04,
    # <fdt data-size>) - keep it and update the size, as tools/fit_patch_console.py does.
    used = u32(hdr[12:16]) + u32(hdr[32:36])
    if len(new_hdr) == len(hdr) and u32(new_hdr[12:16]) == u32(hdr[12:16]):
        new_hdr[used:] = hdr[used:]
        i = new_hdr.find(struct.pack("<I", old_fdt_size), used)
        if i >= 0:
            new_hdr[i:i + 4] = struct.pack("<I", len(dtb))
    if len(new_hdr) > HEADER_ROOM:
        sys.exit(f"FIT header grew to {len(new_hdr)} B, more than {HEADER_ROOM}")

    out = bytearray(total)
    out[:len(new_hdr)] = new_hdr
    for name in ORDER:
        out[layout[name]:layout[name] + len(blobs[name])] = blobs[name]
    open(a.out, "wb").write(out)
    for name in ORDER:
        print(f"  {name:8s} @ {layout[name]:#9x}  {len(blobs[name]):8d} B")
    print(f"wrote {a.out}: {len(out)} B, sha256 {hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()

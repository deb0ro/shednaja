"""Minimal, byte-faithful FDT property rewriter.

Walks the structure block and replaces the values of selected properties, keeping
everything else (reserve map, strings block, node order, other properties) identical.
Only properties whose names already exist in the strings block can be set.
"""
import struct

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def _pad4(b):
    return b + b"\0" * (-len(b) % 4)


def u32s(*vals):
    return b"".join(struct.pack(">I", v) for v in vals)


def cstr(s):
    return s.encode() + b"\0"


def read_props(dtb):
    """{path: {name: bytes}}"""
    out = {}
    for path, name, val in _walk(dtb):
        out.setdefault(path, {})[name] = val
    return out


def _walk(dtb):
    magic, total, off_struct, off_strings, _rsv, _ver, _lc, _cpu, size_strings, size_struct = struct.unpack(">10I", dtb[:40])
    assert magic == 0xD00DFEED
    strings = dtb[off_strings:off_strings + size_strings]
    p, stack = off_struct, []
    while True:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]; p += 4
        if tok == FDT_BEGIN_NODE:
            e = dtb.index(b"\0", p); name = dtb[p:e].decode(); p = e + 1; p += -p % 4
            stack.append(name)
        elif tok == FDT_END_NODE:
            stack.pop()
        elif tok == FDT_PROP:
            ln, noff = struct.unpack(">II", dtb[p:p + 8]); p += 8
            name = strings[noff:strings.index(b"\0", noff)].decode()
            yield "/" + "/".join(stack[1:]), name, dtb[p:p + ln]
            p += ln; p += -p % 4
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            return
        else:
            raise ValueError(f"bad token {tok} at {p - 4:#x}")


def add_node(dtb, parent, name, props):
    """Append a child node `name` with `props` [(propname, bytes)] at the end of `parent`.
    Missing property names are appended to the strings block. Reserve map is kept."""
    magic, total, off_struct, off_strings, off_rsv, ver, lc, cpu, size_strings, size_struct = struct.unpack(">10I", dtb[:40])
    strings = bytearray(dtb[off_strings:off_strings + size_strings])

    def name_off(n):
        key = n.encode() + b"\0"
        i = 0
        while True:
            j = strings.find(key, i)
            if j < 0:
                break
            if j == 0 or strings[j - 1] == 0:
                return j
            i = j + 1
        j = len(strings)
        strings.extend(key)
        return j

    node = bytearray(struct.pack(">I", FDT_BEGIN_NODE) + _pad4(name.encode() + b"\0"))
    for pn, val in props:
        node += struct.pack(">III", FDT_PROP, len(val), name_off(pn)) + _pad4(val)
    node += struct.pack(">I", FDT_END_NODE)

    out = bytearray()
    p, stack, inserted = off_struct, [], False
    while True:
        start = p
        tok = struct.unpack(">I", dtb[p:p + 4])[0]; p += 4
        if tok == FDT_BEGIN_NODE:
            e = dtb.index(b"\0", p); nm = dtb[p:e].decode(); p = e + 1; p += -p % 4
            stack.append(nm)
            want = (parent.rstrip("/") + "/" + name) if parent != "/" else "/" + name
            if "/" + "/".join(stack[1:]) == want:
                raise ValueError(f"node {want} already exists")
            out += dtb[start:p]
        elif tok == FDT_END_NODE:
            path = "/" + "/".join(stack[1:])
            if path == parent and not inserted:
                out += node; inserted = True
            stack.pop(); out += dtb[start:p]
        elif tok == FDT_PROP:
            ln = struct.unpack(">I", dtb[p:p + 4])[0]; p += 8 + ln; p += -p % 4
            out += dtb[start:p]
        elif tok == FDT_NOP:
            out += dtb[start:p]
        elif tok == FDT_END:
            out += dtb[start:p]; break
    if not inserted:
        raise KeyError(f"parent {parent} not found")
    rsv = dtb[off_rsv:off_struct]
    new_off_struct = 40 + len(rsv)
    new_off_strings = new_off_struct + len(out)
    used = new_off_strings + len(strings)
    hdr = struct.pack(">10I", magic, used, new_off_struct, new_off_strings, 40,
                      ver, lc, cpu, len(strings), len(out))
    return hdr + rsv + bytes(out) + bytes(strings)


def set_props(dtb, changes):
    """changes: {(path, propname): new_value_bytes}. Returns new dtb bytes."""
    magic, total, off_struct, off_strings, off_rsv, ver, lc, cpu, size_strings, size_struct = struct.unpack(">10I", dtb[:40])
    strings = dtb[off_strings:off_strings + size_strings]
    pending = dict(changes)
    out = bytearray()
    p, stack = off_struct, []
    while True:
        start = p
        tok = struct.unpack(">I", dtb[p:p + 4])[0]; p += 4
        if tok == FDT_BEGIN_NODE:
            e = dtb.index(b"\0", p); name = dtb[p:e].decode(); p = e + 1; p += -p % 4
            stack.append(name); out += dtb[start:p]
        elif tok == FDT_END_NODE:
            stack.pop(); out += dtb[start:p]
        elif tok == FDT_PROP:
            ln, noff = struct.unpack(">II", dtb[p:p + 8]); p += 8
            name = strings[noff:strings.index(b"\0", noff)].decode()
            path = "/" + "/".join(stack[1:])
            val = dtb[p:p + ln]; p += ln; p += -p % 4
            key = (path, name)
            if key in pending:
                val = pending.pop(key)
            out += struct.pack(">III", FDT_PROP, len(val), noff) + _pad4(val)
        elif tok == FDT_NOP:
            out += dtb[start:p]
        elif tok == FDT_END:
            out += dtb[start:p]
            break
    if pending:
        raise KeyError(f"properties not found: {list(pending)}")
    rsv = dtb[off_rsv:off_struct]          # keep reserve map verbatim
    new_off_rsv = 40
    new_off_struct = new_off_rsv + len(rsv)
    new_off_strings = new_off_struct + len(out)
    used = new_off_strings + len(strings)
    # keep the original free space at the end (e.g. FIT headers made with mkimage -E)
    new_total = max(used, total)
    hdr = struct.pack(">10I", magic, new_total, new_off_struct, new_off_strings, new_off_rsv,
                      ver, lc, cpu, len(strings), len(out))
    return hdr + rsv + bytes(out) + strings + b"\0" * (new_total - used)

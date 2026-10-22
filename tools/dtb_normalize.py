"""Print a DTB as sorted, phandle-free text so two DTBs built from different sources
(stock decompiled vs. our source DTS) can be diffed.

  python -I tools/dtb_normalize.py <file.dtb> > out.txt

Phandle cells are replaced by the target node path (&/path), using #*-cells of the
target for list properties (clocks, gpios, pwms, resets, ...). `phandle` properties
themselves are dropped. Output: one "path: prop = value" line per property, sorted.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdtpatch import _walk  # noqa: E402

# property -> cells property of the target ("" = plain phandle list)
LISTS = {
    "clocks": "#clock-cells", "assigned-clocks": "#clock-cells",
    "assigned-clock-parents": "#clock-cells", "resets": "#reset-cells",
    "pwms": "#pwm-cells", "dmas": "#dma-cells", "phys": "#phy-cells",
    "iommus": "#iommu-cells", "power-domains": "#power-domain-cells",
    "io-channels": "#io-channel-cells", "interrupts-extended": "#interrupt-cells",
    "nvmem-cells": "", "thermal-sensors": "#thermal-sensor-cells",
    "mboxes": "#mbox-cells", "sound-dai": "#sound-dai-cells",
}
SINGLE = ("interrupt-parent", "remote-endpoint", "backlight", "memory-region",
          "phy-handle", "operating-points-v2", "cpu-supply", "native-mode",
          "rockchip,grf", "rockchip,pmugrf", "rockchip,cru", "rockchip,ioc",
          "rockchip,sram", "rockchip,pmu", "rockchip,dvbm", "rockchip,mipi-grf",
          "rockchip,vop", "rockchip,hw", "rockchip,srv", "rockchip,taskqueue-node",
          "rockchip,resetgroup-node", "rockchip,rkvenc-pp", "rockchip,iommu",
          "rockchip,isp", "rockchip,cif", "cooling-device", "trip", "rockchip,dmc",
          "nvmem", "ports", "dvbm", "cpu", "sram", "syscon", "rockchip,camera-module",
          "rockchip,pmu-grf", "gpio-ranges", "rockchip,syscon", "rockchip,rga",
          "drm-logo", "logo-memory-region", "rockchip,pvtpll", "rockchip,regulator")


def gpio_like(name):
    return name.endswith("-gpios") or name.endswith("-gpio") or name in ("gpios", "gpio") \
        or name.endswith("_gpios") or name.endswith(",reset_gpio")


def main():
    dtb = open(sys.argv[1], "rb").read()
    props = {}
    for path, name, val in _walk(dtb):
        props.setdefault(path, {})[name] = val
    ph = {struct.unpack(">I", d["phandle"])[0]: p for p, d in props.items() if "phandle" in d}

    def cells(target, cname):
        if not cname:
            return 0
        v = props.get(target, {}).get(cname)
        return struct.unpack(">I", v)[0] if v else 0

    def fmt_list(u, cname):
        out, i = [], 0
        while i < len(u):
            t = ph.get(u[i])
            if t is None:
                return None
            n = cells(t, cname)
            out.append("&" + t + "".join(f" {x:#x}" for x in u[i + 1:i + 1 + n]))
            i += 1 + n
        return "<" + ", ".join(out) + ">"

    lines = []
    for path, d in props.items():
        for name, val in d.items():
            if name == "phandle":
                continue
            u = list(struct.unpack(f">{len(val) // 4}I", val)) if len(val) % 4 == 0 and val else None
            s = None
            if u is not None:
                if name in LISTS:
                    s = fmt_list(u, LISTS[name])
                elif gpio_like(name):
                    s = fmt_list(u, "#gpio-cells")
                elif name.endswith("-supply") or name.startswith("pinctrl-") or name in SINGLE:
                    if all(x in ph for x in u):
                        s = "<" + " ".join("&" + ph[x] for x in u) + ">"
                elif name == "rockchip,pins":
                    s = "<" + ", ".join(f"{u[i]:#x} {u[i+1]:#x} {u[i+2]:#x} &{ph.get(u[i+3], hex(u[i+3]))}"
                                        for i in range(0, len(u) - 3, 4)) + ">"
            if s is None:
                if val and val[-1:] == b"\0" and all(32 <= c < 127 or c == 0 for c in val) and b"\0\0" not in val:
                    s = '"' + '", "'.join(val[:-1].decode().split("\0")) + '"'
                elif u is not None:
                    s = "<" + " ".join(f"{x:#x}" for x in u) + ">"
                else:
                    s = "[" + val.hex() + "]"
            lines.append(f"{path}: {name} = {s}")
        if not d:
            lines.append(f"{path}:")
    print("\n".join(sorted(lines)))


if __name__ == "__main__":
    main()

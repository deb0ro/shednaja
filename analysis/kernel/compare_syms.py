"""Compare the stock kernel symbol table with a build's System.map and map the
missing symbols to the source files (and Makefile config symbols) that define them.

  python3 compare_syms.py <stock kallsyms.txt> <System.map> <kernel src> > report.txt

stock kallsyms.txt: output of vmlinux-to-elf's kallsyms_finder on analysis/vmlinux_Image.bin.
Only text symbols (t/T/W) are compared; compiler-generated suffixes are stripped.
"""
import collections
import os
import re
import subprocess
import sys


def syms(path):
    out = set()
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 3 and p[1] in "tTW":
            n = re.sub(r"\.(constprop|isra|part|cold|lto_priv)\.\d+.*$", "", p[2])
            if not n.startswith(("__ksymtab", "__kstrtab", "__func__", "$", ".L")):
                out.add(n)
    return out


def main():
    stock, ours, src = syms(sys.argv[1]), syms(sys.argv[2]), sys.argv[3]
    missing, extra = sorted(stock - ours), sorted(ours - stock)
    print(f"stock {len(stock)} text symbols, ours {len(ours)}; missing {len(missing)}, extra {len(extra)}\n")

    # map missing symbols to defining .c files with one git grep over all of them
    pat = "|".join(re.escape(s) for s in missing if re.fullmatch(r"[A-Za-z_]\w+", s))
    files = collections.defaultdict(list)
    if pat:
        r = subprocess.run(["git", "-C", src, "grep", "-n", "-E",
                            rf"^[A-Za-z].*[ \*]({pat})\(", "--", "*.c"],
                           capture_output=True, text=True)
        for line in r.stdout.splitlines():
            f, _, rest = line.split(":", 2)
            m = re.search(rf"[ \*]({pat})\(", rest)
            if m and not rest.rstrip().endswith(";"):
                files[f].append(m.group(1))
    by_dir = collections.defaultdict(list)
    for f, s in files.items():
        by_dir[f].extend(sorted(set(s)))

    def cfg(f):
        d, base = os.path.split(f)
        mk = os.path.join(src, d, "Makefile")
        obj = base[:-2] + ".o"
        try:
            for line in open(mk, errors="replace"):
                if re.search(rf"\b{re.escape(obj)}\b", line):
                    m = re.search(r"\$\((CONFIG_\w+)\)", line)
                    return m.group(1) if m else line.strip()[:60]
        except OSError:
            pass
        return "?"

    print("== missing symbols by source file (file  config  count  examples) ==")
    for f in sorted(by_dir, key=lambda f: -len(by_dir[f])):
        s = by_dir[f]
        print(f"{f}  {cfg(f)}  {len(s)}  {' '.join(s[:6])}")
    unmapped = sorted(set(missing) - {x for v in files.values() for x in v})
    print(f"\n== {len(unmapped)} missing symbols not mapped to a .c file ==")
    print(" ".join(unmapped))
    print(f"\n== {len(extra)} extra symbols (ours only) ==")
    print(" ".join(extra))


if __name__ == "__main__":
    main()

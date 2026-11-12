#!/usr/bin/env python3
"""Render the screens shown on the printer display: the boot logo and the update screens.

    python tools/make_update_splash.py [--test out.bgra.gz]

Writes {updating,done,failed}.fb.gz per variant: raw frames for /dev/fb0 (800x480, 32 bpp,
B,G,R,X byte order, gzip), shown with "zcat <file> > /dev/fb0".
  Lite:    rootfs/board/kobra_s1/overlay/usr/share/shednaja/splash/ (update-stage2 / update-writer)
  Armbian: armbian_build/stack/splash/ (kobra-update; install-stack.sh puts them into
           /usr/share/shednaja/splash)
Also writes the logo U-Boot and the kernel show from power-on until HelixScreen starts
(logo.bmp / logo_kernel.bmp in the boot.img resource, put there by tools/mkboot_kernel.py
--logo), one per variant: kernel/logo/boot_logo.bmp for Lite (tools/build_kernel.sh) and
kernel/logo/boot_logo_armbian.bmp for Armbian (armbian_build/scripts/pack_boot.sh). Same
format as the stock logo: 800x480, 8 bit with a palette, uncompressed BMP.
The panel is mounted upside down relative to fb0 (HelixScreen runs with --rotate=180, the
stock logo is stored upside down too), so everything is rotated by 180 degrees.
Needs Pillow and a TrueType font (DejaVu Sans or Segoe UI).
"""
import gzip
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPLASH_DIRS = {
    "lite": os.path.join(ROOT, "rootfs", "board", "kobra_s1", "overlay", "usr", "share",
                         "shednaja", "splash"),
    "armbian": os.path.join(ROOT, "armbian_build", "stack", "splash"),
}
LOGO_DIR = os.path.join(ROOT, "kernel", "logo")
# shown on every update screen and on the boot logo
NAMES = {"lite": "ShedNaja Lite", "armbian": "ShedNaja"}
# boot logo per variant
BOOT_LOGOS = {"lite": "boot_logo.bmp", "armbian": "boot_logo_armbian.bmp"}
W, H = 800, 480
BG = (16, 20, 26)
FG = (235, 238, 242)
DIM = (150, 158, 170)

SCREENS = {
    "updating": ((64, 156, 255), "Updating firmware",
                 "Writing ShedNaja to the printer.",
                 "Do not turn off the printer. It restarts by itself."),
    "done": ((60, 200, 120), "Update complete",
             "The new firmware has been written and verified.",
             "Restarting..."),
    "failed": ((235, 80, 70), "Update failed",
               "The new firmware could not be verified.",
               "Restarting into the stock firmware."),
    # Armbian installs next to the running system: a failed install changes nothing
    "failed-armbian": ((235, 80, 70), "Update failed",
                       "The new firmware could not be installed.",
                       "The printer keeps running the current system."),
    "test": ((255, 200, 0), "TOP LEFT  - test",
             "Red  Green  Blue squares below.",
             "If this reads upside down, the rotation is wrong."),
}


def font(size, bold=False):
    names = (["DejaVuSans-Bold.ttf", "segoeuib.ttf"] if bold else
             ["DejaVuSans.ttf", "segoeui.ttf"])
    dirs = ["/usr/share/fonts/truetype/dejavu", "C:/Windows/Fonts", "/usr/share/fonts/TTF"]
    for d in dirs:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    sys.exit("no TrueType font found (install DejaVu Sans)")


def render(name, variant="lite"):
    accent, title, line1, line2 = SCREENS.get(name + "-" + variant, SCREENS[name])
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 10], fill=accent)
    d.text((W // 2, 170), title, font=font(46, True), fill=FG, anchor="mm")
    d.text((W // 2, 245), line1, font=font(24), fill=DIM, anchor="mm")
    d.text((W // 2, 285), line2, font=font(24), fill=DIM, anchor="mm")
    d.text((W // 2, 440), NAMES[variant], font=font(18), fill=DIM, anchor="mm")
    if name == "test":
        d.text((10, 20), "TL", font=font(30, True), fill=FG)
        for i, c in enumerate([(255, 0, 0), (0, 255, 0), (0, 0, 255)]):
            d.rectangle([300 + i * 70, 340, 360 + i * 70, 400], fill=c)
    im = im.rotate(180)
    r, g, b = im.split()
    x = Image.new("L", (W, H), 255)
    return gzip.compress(Image.merge("RGBA", (b, g, r, x)).tobytes(), 9, mtime=0)


def render_boot_logo(variant):
    file, name = BOOT_LOGOS[variant], NAMES[variant]
    path = os.path.join(LOGO_DIR, file)
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    accent = (64, 156, 255)
    # a simple mark: three stacked layers, like a print growing
    for i, w in enumerate((150, 120, 90)):
        y = 150 - i * 22
        d.rounded_rectangle([W // 2 - w // 2, y, W // 2 + w // 2, y + 14], 5,
                            fill=accent if i == 2 else (40, 92, 160))
    d.text((W // 2, 250), name, font=font(56, True), fill=FG, anchor="mm")
    d.text((W // 2, 305), "Klipper firmware for the Anycubic Kobra S1", font=font(22),
           fill=DIM, anchor="mm")
    d.text((W // 2, 430), "Starting...", font=font(20), fill=DIM, anchor="mm")
    im = im.rotate(180).quantize(256, method=Image.Quantize.MEDIANCUT)
    os.makedirs(LOGO_DIR, exist_ok=True)
    im.save(path, "BMP")
    return file, os.path.getsize(path)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--test":
        open(sys.argv[2], "wb").write(render("test"))
        return
    for variant, out in SPLASH_DIRS.items():
        os.makedirs(out, exist_ok=True)
        for name in ("updating", "done", "failed"):
            data = render(name, variant)
            open(os.path.join(out, name + ".fb.gz"), "wb").write(data)
            print("%s %s.fb.gz %d B" % (variant, name, len(data)))
    for variant in BOOT_LOGOS:
        print("%s %d B" % render_boot_logo(variant))


if __name__ == "__main__":
    main()

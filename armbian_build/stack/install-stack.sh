#!/bin/bash
# Install ShedNaja's Klipper stack into the Armbian image. Runs in the image chroot (qemu) from
# customize-image.sh, with the staged files in $1 (/tmp/overlay/kobra-stack, scripts/stage_stack.sh).
# Same versions, paths and scripts as ShedNaja Lite (rootfs/package/*.mk, rootfs/board/kobra_s1):
#   /usr/lib/klipper, /usr/bin/klipper_mcu, /usr/lib/moonraker, /usr/share/mainsail,
#   /opt/helixscreen, /usr/bin/mjpg_streamer + /usr/lib/mjpg-streamer, /usr/share/shednaja,
#   /usr/libexec/kobra (+ init/ = Lite's init scripts, started by the units in systemd/).
# Python libraries from Debian; inotify-simple and streaming-form-data are not packaged there.
# Compilers are installed for the build and removed again: nothing is built on the printer.
set -euo pipefail
S=${1:-/tmp/overlay/kobra-stack}
. "$S/versions"
export DEBIAN_FRONTEND=noninteractive
B=$(mktemp -d)
log() { echo "== kobra-stack: $*"; }

RUNTIME="python3 python3-greenlet python3-cffi python3-serial python3-jinja2 python3-markupsafe
	python3-tornado python3-pil python3-numpy python3-distro python3-libnacl python3-dbus-fast
	python3-zipp python3-importlib-metadata libsodium23 lighttpd libjpeg62-turbo sudo iproute2"
BUILD="gcc libc6-dev make cmake libjpeg62-turbo-dev python3-dev cython3 python3-setuptools
	python3-pip python3-wheel patch"
log "packages"
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $RUNTIME
# build tools in their own step, so exactly what it added can be removed at the end
dpkg-query -W -f='${Package}\n' | sort > "$B/pkgs.before"
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $BUILD
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
SITE=/usr/local/lib/python$PYV/dist-packages
mkdir -p "$SITE"

log "Klipper $KLIPPER_DESCRIBE"
mkdir -p "$B/klipper"; tar -xzf "$S/src/klipper-$KLIPPER_VERSION-br1.tar.gz" -C "$B/klipper" --strip-components=1
for p in "$S"/patches/klipper/*.patch; do patch -d "$B/klipper" -p1 < "$p"; done   # all of them, as Buildroot
(cd "$B/klipper/klippy/chelper" && gcc -Wall -O2 -shared -fPIC -flto -fwhole-program -fno-use-linker-plugin -o c_helper.so \
	$(python3 -c 'import ast; t=ast.parse(open("__init__.py").read()); print(" ".join(next(ast.literal_eval(n.value) for n in t.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "SOURCE_FILES")))') -lm)
rm -rf /usr/lib/klipper; mkdir -p /usr/lib/klipper
cp -a "$B/klipper/klippy" "$B/klipper/COPYING" "$B/klipper/config" /usr/lib/klipper/
mkdir -p /usr/lib/klipper/docs; cp -a "$B"/klipper/docs/*.md /usr/lib/klipper/docs/
echo "$KLIPPER_DESCRIBE" > /usr/lib/klipper/klippy/.version
log "klipper_mcu (Linux host MCU)"
(cd "$B/klipper" && echo "CONFIG_MACH_LINUX=y" > .config && make -s olddefconfig PYTHON=python3 && make -s -j2 PYTHON=python3)
install -m 0755 "$B/klipper/out/klipper.elf" /usr/bin/klipper_mcu

log "Moonraker $MOONRAKER_RELEASE"
mkdir -p "$B/moonraker"; tar -xzf "$S"/src/moonraker-*-br1.tar.gz -C "$B/moonraker" --strip-components=1
rm -rf /usr/lib/moonraker; mkdir -p /usr/lib/moonraker
cp -a "$B/moonraker/moonraker" "$B/moonraker/LICENSE" /usr/lib/moonraker/
echo "$MOONRAKER_RELEASE" > /usr/lib/moonraker/moonraker/.version
log "python: inotify-simple (wheel), streaming-form-data (built)"
python3 -m zipfile -e "$S/src/inotify_simple-2.0.1-py3-none-any.whl" "$SITE"
mkdir -p "$B/sfd"; tar -xzf "$S"/src/streaming-form-data-*.tar.gz -C "$B/sfd" --strip-components=1
for p in "$S"/patches/sfd/*.patch; do patch -d "$B/sfd" -p1 < "$p"; done
pip3 install --no-deps --no-build-isolation --break-system-packages --no-cache-dir --root-user-action=ignore "$B/sfd"   # Debian pip: /usr/local/lib/python3.X/dist-packages
python3 -c 'import streaming_form_data, inotify_simple, libnacl, dbus_fast, tornado, PIL, numpy, greenlet, serial, jinja2'

log "Mainsail, mainsail.cfg"
rm -rf /usr/share/mainsail; mkdir -p /usr/share/mainsail
python3 -m zipfile -e "$S/src/mainsail.zip" /usr/share/mainsail
find /usr/share/mainsail -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
mkdir -p "$B/msc"; tar -xzf "$S"/src/mainsail-config-*-br1.tar.gz -C "$B/msc" --strip-components=1
install -D -m 0644 "$B/msc/mainsail.cfg" /usr/share/shednaja/klipper/mainsail.cfg

log "HelixScreen $HELIXSCREEN_VERSION"
H=$B/helix; mkdir -p "$H"; tar -xzf "$S/src/helixscreen-ad5m-v$HELIXSCREEN_VERSION.tar.gz" -C "$H" --strip-components=1
find "$H/assets/images/printers" -maxdepth 1 -type f ! -name 'anycubic-kobra-s1.png' ! -name 'README.md' -delete
find "$H/assets/images/printers/prerendered" -type f ! -name 'anycubic-kobra-s1-*.bin' -delete
rm -f "$H"/assets/images/prerendered/*-large.bin "$H"/assets/images/prerendered/*-ultrawide.bin
rm -f "$H/ui_xml/translations/zh.xml" "$H/ui_xml/translations/ja.xml"
rm -rf "$H/assets/fonts/cjk" "$H/assets/sounds" "$H/install.sh"
rm -rf /opt/helixscreen; mkdir -p /opt; cp -a "$H" /opt/helixscreen
find /opt/helixscreen -type d -exec chmod 755 {} + -o -type f -exec chmod go-w {} +
rm -rf /var/lib/helixscreen; ln -s /useremain/shednaja/helixscreen/backup /var/lib/helixscreen

log "ACEPRO (packaged, inactive as in Lite)"
mkdir -p "$B/ace"; tar -xzf "$S"/src/kobra-acepro-*.tar.gz -C "$B/ace" --strip-components=1
X=/usr/lib/klipper/klippy/extras
rm -rf "$X/ace"; cp -a "$B/ace/extras/ace" "$X/ace"
install -m 0644 "$B/ace/extras/temperature_ace.py" "$B/ace/extras/virtual_pins.py" "$X/"
install -D -m 0644 "$B/ace/config/ace_KS1.cfg" /usr/share/shednaja/printer_data/config/ace_KS1.cfg
install -D -m 0644 "$B/ace/config/ace_macros_generic.cfg" /usr/share/shednaja/printer_data/config/ace_macros_generic.cfg

log "mjpg-streamer (input_uvc + output_http, as kobra-webcam)"
mkdir -p "$B/mjpg"; tar -xzf "$S"/src/mjpg-streamer-*.tar.gz -C "$B/mjpg" --strip-components=1
(cd "$B/mjpg/mjpg-streamer-experimental" && mkdir -p _build && cd _build &&
	cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DENABLE_HTTP_MANAGEMENT=OFF .. >/dev/null &&
	make -s -j2 && make -s install)
(cd /usr/lib/mjpg-streamer && find . -name '*.so' ! -name input_uvc.so ! -name output_http.so -delete)
rm -rf /usr/share/mjpg-streamer

log "Lite's files"
L=$S/lite
install -m 0644 "$L"/extras/*.py "$X/"
install -d /usr/libexec/kobra /usr/libexec/kobra/init
install -m 0755 "$L"/libexec/* /usr/libexec/kobra/
install -m 0755 "$L"/init/* /usr/libexec/kobra/init/
install -m 0755 "$L"/sbin/kobra-config-migrate "$L"/sbin/kobra-update /usr/sbin/   # kobra-update: one script for Lite and Armbian
# root: Lite's default password instead of Armbian's 1234 (whose first-login change our installs
# skip); Lite's login prompt asks for a new one while root still has it
h=$(cat "$S/root.hash"); usermod -p "$h" root
install -d /usr/share/shednaja
grep '^root:' /etc/shadow > /usr/share/shednaja/shadow.default; chmod 600 /usr/share/shednaja/shadow.default
install -m 0644 "$L"/profile.d/shednaja-password.sh /etc/profile.d/
ln -sfn /usr/local/sbin/kobra-abctl /usr/sbin/kobra-abctl     # kobra_slot.py calls /usr/sbin/kobra-abctl
install -m 0644 "$L/etc/lighttpd.conf" /etc/lighttpd/lighttpd.conf
# printer_data defaults and the shipped Klipper config (rootfs/board/kobra_s1/post-build.sh)
mkdir -p /usr/share/shednaja/printer_data
cp -a "$L/printer_data_defaults/." /usr/share/shednaja/printer_data/
install -d /usr/share/shednaja/klipper
find /usr/share/shednaja/klipper -type f ! -name mainsail.cfg -delete
install -m 0644 "$L"/klipper_config/*.cfg "$L/klipper_config/README.txt" /usr/share/shednaja/klipper/
install -m 0644 "$L/klipper_config/known-versions.sha256" /usr/share/shednaja/klipper-known-versions.sha256
for f in /usr/share/shednaja/klipper/*.cfg; do
	s="$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
	grep -qxF "$s" "$L/klipper_config/known-versions.sha256" || { echo "unknown shipped config $s"; exit 1; }
done
ln -sfn /useremain/shednaja/printer_data /root/printer_data

log "precompile Python"
find /usr/lib/klipper /usr/lib/moonraker -name '__pycache__' -prune -exec rm -rf {} +
python3 -m compileall -q -j1 --invalidation-mode unchecked-hash -d /usr/lib/klipper/klippy /usr/lib/klipper/klippy
python3 -m compileall -q -j1 --invalidation-mode unchecked-hash -d /usr/lib/moonraker/moonraker /usr/lib/moonraker/moonraker

log "systemd units"
install -m 0644 "$S"/systemd/*.service /etc/systemd/system/
install -d /etc/systemd/system/lighttpd.service.d
install -m 0644 "$S"/systemd/lighttpd.service.d/*.conf /etc/systemd/system/lighttpd.service.d/
install -m 0755 "$S/kobra-data-seed" /usr/libexec/kobra/kobra-data-seed
systemctl enable kobra-data-seed.service kobra-usb.service klipper-mcu.service klipper.service \
	moonraker.service lighttpd.service kobra-webcam.service helixscreen.service kobra-usbupdate.service

log "remove build tools (only the packages the build step added)"
dpkg-query -W -f='${Package}\n' | sort | comm -13 "$B/pkgs.before" - > "$B/pkgs.added"
# shellcheck disable=SC2046
apt-get purge -y -qq $(cat "$B/pkgs.added")
apt-get clean
rm -rf "$B" /root/.cache
python3 -c 'import streaming_form_data, tornado, serial, greenlet, cffi, numpy' && log "done"

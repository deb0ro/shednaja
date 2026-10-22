#!/usr/bin/env bash
# Buildroot post-fakeroot for the Kobra S1 rootfs. $1 = the image's copy of TARGET_DIR,
# after the device table: that table insists on /etc/shadow being a regular file, so the
# link can only be made here.
set -euo pipefail
T=$1

# /etc/shadow -> /run/shadow -> /userdata/shednaja/shadow (S00kobra-mounts seeds it from
# this default), so passwd works on the read-only rootfs and the password survives updates.
# busybox passwd follows the links and writes its temporary file next to the real one.
install -D -m 0600 "$T/etc/shadow" "$T/usr/share/shednaja/shadow.default"
rm -f "$T/etc/shadow"
ln -s /run/shadow "$T/etc/shadow"
# After the shadow entry, passwd also rewrites /etc/passwd (password field "x", unchanged):
# /etc/passwd -> /run/passwd, a fresh copy of the image's file every boot (S00kobra-mounts).
install -D -m 0644 "$T/etc/passwd" "$T/usr/share/shednaja/passwd"
rm -f "$T/etc/passwd"
ln -s /run/passwd "$T/etc/passwd"

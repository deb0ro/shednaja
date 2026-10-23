#!/usr/bin/env bash
# kobra-config-migrate on printer_data trees of older installs (CI, no printer):
#   bash rootfs/tests/test_config_migrate.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MIG=$ROOT/rootfs/board/kobra_s1/overlay/usr/sbin/kobra-config-migrate
KC=$ROOT/rootfs/board/kobra_s1/klipper_config
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SH=$(command -v dash || command -v sh)
fail=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }

# the image: shipped files, mainsail.cfg as a stand-in whose sum is listed for the test
SHIP=$W/ship; mkdir -p "$SHIP"
cp "$KC"/*.cfg "$SHIP/"; echo "# mainsail stand-in" > "$SHIP/mainsail.cfg"
KNOWN=$W/known; cp "$KC/known-versions.sha256" "$KNOWN"
echo "$(sha256sum "$SHIP/mainsail.cfg" | cut -d' ' -f1)  mainsail.cfg" >> "$KNOWN"
export KOBRA_SHIP=$SHIP KOBRA_KNOWN=$KNOWN

old_install() {	# old_install <dir>: printer_data as the first images left it
	mkdir -p "$1/config"
	cat > "$1/config/printer.cfg" <<'CFG'
[include mainsail.cfg]
[include kobra_s1.cfg]
[include  kobra_macros.cfg ]
[include kobra_peripherals.cfg]

[mcu]
serial: /dev/ttyS3
#*# <---------------------- SAVE_CONFIG ---------------------->
#*# [probe_ks1]
#*# z_offset = 0.120
CFG
	cp "$SHIP/mainsail.cfg" "$1/config/"
	cp "$SHIP/kobra_s1.cfg" "$SHIP/kobra_peripherals.cfg" "$1/config/"
	# an older shipped kobra_macros.cfg (its sum is in the list), if git history has one
	if git -C "$ROOT" cat-file -e 36052ae:rootfs/board/kobra_s1/printer_data_defaults/config/kobra_macros.cfg 2>/dev/null; then
		git -C "$ROOT" show 36052ae:rootfs/board/kobra_s1/printer_data_defaults/config/kobra_macros.cfg > "$1/config/kobra_macros.cfg"
	else
		cp "$SHIP/kobra_macros.cfg" "$1/config/"
	fi
}
includes() { grep '^\[include' "$1/config/printer.cfg" | tr '\n' ' '; }
want_all="[include $SHIP/mainsail.cfg] [include $SHIP/kobra_s1.cfg] [include $SHIP/kobra_macros.cfg] [include $SHIP/kobra_peripherals.cfg] "

# 1. unmodified copies (current and older shipped versions): all switch, backups kept
PD=$W/a; old_install "$PD"
KOBRA_PD=$PD $SH "$MIG" > "$W/out"
[ "$(includes "$PD")" = "$want_all" ] && ok "unmodified copies switched" || bad "unmodified: $(includes "$PD")"
bk=$(ls -d "$PD"/config/backup-* | head -n 1)
[ -f "$bk/printer.cfg" ] && [ -f "$bk/kobra_macros.cfg" ] && ok "backup made" || bad "backup missing"
ls "$PD"/config/kobra_*.cfg > /dev/null 2>&1 && bad "copies left in config/" || ok "copies moved out of config/"
grep -q 'z_offset = 0.120' "$PD/config/printer.cfg" && ok "rest of printer.cfg kept" || bad "printer.cfg body changed"
# 2. second run: nothing to do, nothing changed
cp "$PD/config/printer.cfg" "$W/before"
KOBRA_PD=$PD $SH "$MIG" --auto > "$W/out"
cmp -s "$W/before" "$PD/config/printer.cfg" && [ "$(ls -d "$PD"/config/backup-* | wc -l)" = 1 ] &&
	ok "second run changes nothing" || bad "second run changed something"

# 3. an edited copy stays (and is still included); --force switches it
PD=$W/b; old_install "$PD"; echo "# my change" >> "$PD/config/kobra_macros.cfg"
KOBRA_PD=$PD $SH "$MIG" > "$W/out"
grep -q '^\[include  kobra_macros.cfg \]' "$PD/config/printer.cfg" && [ -f "$PD/config/kobra_macros.cfg" ] &&
	grep -q "^\[include $SHIP/kobra_s1.cfg\]" "$PD/config/printer.cfg" &&
	ok "edited copy kept, the others switched" || bad "edited: $(includes "$PD")"
grep -q "kept, edited by you: kobra_macros.cfg" "$W/out" && ok "edited copy reported" || bad "no report: $(cat "$W/out")"
KOBRA_PD=$PD $SH "$MIG" --force > "$W/out"
[ "$(includes "$PD")" = "$want_all" ] && ok "--force switches the edited copy" || bad "--force: $(includes "$PD")"
grep -q "my change" "$PD"/config/backup-*/kobra_macros.cfg && ok "edited copy in the backup" || bad "edited copy lost"

# 4. new install (includes from the image already) and no printer.cfg: nothing happens
PD=$W/c; mkdir -p "$PD/config"
cp "$ROOT/rootfs/board/kobra_s1/printer_data_defaults/config/printer.cfg" "$PD/config/"
cp "$PD/config/printer.cfg" "$W/before"
KOBRA_PD=$PD KOBRA_SHIP=/usr/share/shednaja/klipper $SH "$MIG" --auto > "$W/out"
cmp -s "$W/before" "$PD/config/printer.cfg" && [ ! -s "$W/out" ] && ! ls -d "$PD"/config/backup-* > /dev/null 2>&1 &&
	ok "new layout untouched, quiet with --auto" || bad "new layout changed: $(cat "$W/out")"
KOBRA_PD=$W/none $SH "$MIG" --auto && ok "no printer.cfg: nothing to do" || bad "no printer.cfg failed"

# 5. a missing copy (include broken already) is switched
PD=$W/d; old_install "$PD"; rm "$PD/config/mainsail.cfg"
KOBRA_PD=$PD $SH "$MIG" > "$W/out"
grep -q "^\[include $SHIP/mainsail.cfg\]" "$PD/config/printer.cfg" && ok "missing copy switched" || bad "missing copy: $(includes "$PD")"

# every shipped file's current sum is listed (add it when the file changes)
for f in "$KC"/*.cfg; do
	n=$(basename "$f")
	grep -qxF "$(sha256sum "$f" | cut -d' ' -f1)  $n" "$KC/known-versions.sha256" &&
		ok "$n: current sum listed" || bad "$n: add '$(sha256sum "$f" | cut -d' ' -f1)  $n' to klipper_config/known-versions.sha256"
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }

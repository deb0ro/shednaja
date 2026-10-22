#!/usr/bin/env bash
# Export the committed tree (HEAD) into the public repository, without the development
# history and without the paths below. The first run creates the repository with a single
# "Initial commit"; later runs replace its tree with HEAD's and commit on top.
#
#   bash tools/export_public.sh [dir] [message]      (default dir: build/publish/shednaja)
#
# Not published: reverse-engineering material of the Anycubic MCU firmware (and the
# Klipper patch derived from it) and a board picture of unknown origin.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${1:-build/publish/shednaja}
MSG=${2:-}
EXCLUDE=(analysis/re_cs1237 patches reference/boards_overview.webp docs/cs1237-calibration-re.md)

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit your changes first (only HEAD is exported)"; exit 1; }

# The target's tracked files are deleted below, so make sure it is the public repository:
# not this repository or anything around it, and either new/empty or a clean ShedNaja
# export (its own git top level, README.md starting with "# ShedNaja", nothing uncommitted).
die() { echo "export_public.sh: $*"; exit 1; }
SRC=$(pwd -P)
mkdir -p "$DIR"
TGT=$(cd "$DIR" && pwd -P)
case "$TGT/" in "$SRC/") die "target is this repository" ;; esac
case "$SRC/" in "$TGT/"*) die "target $TGT contains this repository" ;; esac
case "$TGT/" in "$SRC/"*) case "$TGT/" in "$SRC/build/"*) ;; *) die "target inside this repository must be under build/" ;; esac ;; esac
if [ -d "$TGT/.git" ]; then
	[ "$(cd "$(git -C "$TGT" rev-parse --show-toplevel)" && pwd -P)" = "$TGT" ] || die "$TGT is not the top level of its repository"
	head -n 1 "$TGT/README.md" 2>/dev/null | grep -qx "# ShedNaja" || die "$TGT is not a ShedNaja export (README.md)"
	[ -z "$(git -C "$TGT" status --porcelain)" ] || die "$TGT has uncommitted changes"
elif [ -n "$(ls -A "$TGT")" ]; then
	die "$TGT exists, is not empty and not a git repository"
fi
DIR=$TGT

new=0
if [ ! -d "$DIR/.git" ]; then
	git init -q -b main "$DIR"
	git -C "$DIR" config user.name "$(git config user.name)"
	# public commits carry the GitHub noreply address, not a private e-mail
	git -C "$DIR" config user.email "${PUBLIC_EMAIL:-7002975+deb0ro@users.noreply.github.com}"
	new=1
fi
git -C "$DIR" ls-files -z | (cd "$DIR" && xargs -0 -r rm -f)
git archive HEAD | tar -x -C "$DIR"
for p in "${EXCLUDE[@]}"; do rm -rf "${DIR:?}/$p"; done
git -C "$DIR" add -A
# executable bits as in this repository (core.fileMode is off on Windows checkouts)
git ls-files -s | awk '$1 == "100755" { print $4 }' | while read -r f; do
	[ -f "$DIR/$f" ] && git -C "$DIR" update-index --chmod=+x "$f"
done
if [ $new = 1 ]; then
	MSG=${MSG:-"Initial commit

ShedNaja: an open operating system for the Anycubic Kobra S1 (kernel 5.10.160, Buildroot,
Klipper, Moonraker, Mainsail, HelixScreen), installed next to the stock firmware in the
other A/B slot. See README.md."}
fi
if git -C "$DIR" diff --cached --quiet; then echo "no changes"; exit 0; fi
git -C "$DIR" commit -q -m "${MSG:-Update from $(git rev-parse --short HEAD)}"
git -C "$DIR" log --oneline -3
echo "$(git -C "$DIR" ls-files | wc -l) files, $(git -C "$DIR" ls-files -s | awk '$1 == "100755"' | wc -l) executable"

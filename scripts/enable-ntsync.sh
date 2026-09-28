#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Add NTSYNC (NT synchronization primitives) to the kernel tree.
#
# OPTIONAL. Only needed to run Windows software (Wine / Proton) inside a
# Droidspaces container. See patches/optional/ntsync/README.md.
#
# usage: enable-ntsync.sh [kernel-dir]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${1:-${KERNEL_DIR:-$PROJECT_DIR/work/src}}"
BUNDLE="$PROJECT_DIR/patches/optional/ntsync"

[ -d "$KERNEL_DIR" ] || { echo "[x] kernel dir not found: $KERNEL_DIR" >&2; exit 1; }
[ -d "$BUNDLE/files" ] || { echo "[x] bundle missing: $BUNDLE/files" >&2; exit 1; }

cd "$KERNEL_DIR"

echo "[*] installing NTSYNC sources"
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest="$KERNEL_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$BUNDLE/files/$rel" "$dest"
    echo "    + $rel"
done < <(cd "$BUNDLE/files" && find . -type f -printf '%P\n' | sort)

if grep -q '^config NTSYNC$' drivers/misc/Kconfig 2>/dev/null; then
    echo "[i] drivers/misc/Kconfig already declares CONFIG_NTSYNC, skipping hooks patch"
else
    echo "[*] applying Kconfig/Makefile hooks"
    patch -p1 --batch -f < "$BUNDLE/0001-ntsync-hooks.patch"
fi

grep -q '^config NTSYNC$' drivers/misc/Kconfig
grep -q 'obj-\$(CONFIG_NTSYNC)' drivers/misc/Makefile
echo "[+] NTSYNC enabled in $KERNEL_DIR"

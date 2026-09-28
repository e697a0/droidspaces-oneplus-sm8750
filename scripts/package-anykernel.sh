#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Package a built Image into an AnyKernel3 flashable zip.
#
# usage: package-anykernel.sh <Image> <output.zip> [kernel_name]
#
# Environment:
#   AK3_REPO         AnyKernel3 repository (default osm0sis/AnyKernel3)
#   AK3_REF          AnyKernel3 branch/tag   (default master)
#   AK3_DEVICECHECK  0 = disable the installer device whitelist
set -euo pipefail

IMAGE="${1:?usage: package-anykernel.sh <Image> <output.zip> [kernel_name]}"
OUT_ZIP="${2:?usage: package-anykernel.sh <Image> <output.zip> [kernel_name]}"
KERNEL_NAME="${3:-Droidspaces Kernel (SM8750 / sun)}"

AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}"
AK3_REF="${AK3_REF:-master}"
AK3_DEVICECHECK="${AK3_DEVICECHECK:-1}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -s "$IMAGE" ] || { echo "[x] Image not found: $IMAGE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[*] fetching AnyKernel3 ($AK3_REPO @ $AK3_REF)"
git clone --depth=1 --branch "$AK3_REF" "$AK3_REPO" "$WORK/ak3"
rm -rf "$WORK/ak3/.git" "$WORK/ak3/.github" "$WORK/ak3/README.md"

cp -f "$IMAGE" "$WORK/ak3/Image"
cp -f "$PROJECT_DIR/anykernel/anykernel.sh" "$WORK/ak3/anykernel.sh"
chmod +x "$WORK/ak3/anykernel.sh"

# --- kernel.string ----------------------------------------------------------
# Strip newlines and escape sed replacement metacharacters so an exotic
# kernel name cannot corrupt anykernel.sh or inject sed syntax.
KERNEL_NAME="$(printf '%s' "$KERNEL_NAME" | tr -d '\n\r')"
escape_repl() { printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'; }
ESCAPED_NAME="$(escape_repl "$KERNEL_NAME")"
sed -i "s|^kernel.string=.*|kernel.string=${ESCAPED_NAME}|" "$WORK/ak3/anykernel.sh"

# --- optional: relax the installer device whitelist -------------------------
if [ "$AK3_DEVICECHECK" = "0" ]; then
    echo "[i] AK3_DEVICECHECK=0 - disabling the installer device check"
    sed -i 's|^do\.devicecheck=.*|do.devicecheck=0|' "$WORK/ak3/anykernel.sh"
fi

# --- sanity: the injected values must actually be there ---------------------
grep -q "^kernel.string=${ESCAPED_NAME}$" "$WORK/ak3/anykernel.sh" || {
    echo "[x] kernel.string injection failed" >&2
    exit 1
}
grep -q "do.devicecheck=" "$WORK/ak3/anykernel.sh" || {
    echo "[x] do.devicecheck is missing from anykernel.sh" >&2
    exit 1
}

mkdir -p "$(dirname "$OUT_ZIP")"
rm -f "$OUT_ZIP"
( cd "$WORK/ak3" && zip -r9 "$OUT_ZIP" . -x '*.git*' >/dev/null )

echo "[+] wrote $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
unzip -l "$OUT_ZIP" | grep -E 'Image|anykernel.sh|META-INF' || true

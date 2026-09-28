#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Configure and build the Droidspaces kernel Image.
#
# Environment:
#   KERNEL_DIR    kernel source (default: ../work/src relative to this repo)
#   OUT_DIR       build output     (default: $KERNEL_DIR/out)
#   PROFILE       core | full      (default: full)
#   LOCALVERSION  override kernel release suffix (e.g. -4k-gdeadbeef1234)
#   JOBS          parallelism      (default: nproc)
#   EXTRA_MAKE    extra make args  (optional)
#   CONFIGURE_ONLY 1 = merge config, run olddefconfig and verify, then stop
#                  (used by CI so a config regression fails in minutes)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KERNEL_DIR="${KERNEL_DIR:-$PROJECT_DIR/work/src}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
PROFILE="${PROFILE:-full}"
LOCALVERSION="${LOCALVERSION:-}"
JOBS="${JOBS:-$(nproc --all)}"
EXTRA_MAKE="${EXTRA_MAKE:-}"
CONFIGURE_ONLY="${CONFIGURE_ONLY:-0}"

[ -d "$KERNEL_DIR" ] || { echo "[x] KERNEL_DIR not found: $KERNEL_DIR" >&2; exit 1; }

frags=(
    arch/arm64/configs/gki_defconfig
    arch/arm64/configs/vendor/sun_perf.config
    arch/arm64/configs/vendor/oplus/sun_perf.config
    "$PROJECT_DIR/configs/droidspaces-core.config"
)
case "$PROFILE" in
    core) ;;
    full)
        frags+=("$PROJECT_DIR/configs/droidspaces-containers.config"
                "$PROJECT_DIR/configs/droidspaces-network.config")
        ;;
    *) echo "[x] unknown PROFILE '$PROFILE' (use core|full)" >&2; exit 1 ;;
esac

cd "$KERNEL_DIR"
mkdir -p "$OUT_DIR"

echo "[*] merging defconfig fragments (profile=$PROFILE)"
# merge_config.sh reads the fragments and writes the merged fragment file to
# $OUT_DIR/.config; 'make olddefconfig' then materialises every default.
KCONFIG_CONFIG="$OUT_DIR/.config" \
    scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "${frags[@]}"

if [ -n "$LOCALVERSION" ]; then
    echo "[*] pinning CONFIG_LOCALVERSION='$LOCALVERSION' (AUTO off)"
    ./scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_LOCALVERSION "$LOCALVERSION"
    ./scripts/config --file "$OUT_DIR/.config" -d CONFIG_LOCALVERSION_AUTO
fi

export LLVM=1 LLVM_IAS=1

echo "[*] olddefconfig"
# shellcheck disable=SC2086
make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 $EXTRA_MAKE olddefconfig

bash "$PROJECT_DIR/scripts/verify-config.sh" "$OUT_DIR/.config" "$PROFILE"

if [ "$CONFIGURE_ONLY" = "1" ]; then
    echo "[+] CONFIGURE_ONLY=1 - configuration verified, skipping compile"
    exit 0
fi

echo "[*] building Image (-j$JOBS)"
# shellcheck disable=SC2086
make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 \
     CC=clang LD=ld.lld HOSTLD=ld.lld \
     KCFLAGS+=-Wno-error $EXTRA_MAKE Image

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -s "$IMAGE" ] || { echo "[x] Image was not produced" >&2; exit 1; }
echo "[+] built $IMAGE ($(stat -c%s "$IMAGE") bytes)"
echo "[+] release string: $(strings "$IMAGE" | grep -m1 -oE '^6\.[0-9]+\.[0-9]+[^ ]*' || echo '(unknown)')"

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
#   CC            compiler command  (default: clang, e.g. 'ccache clang')
#   LD            linker           (default: ld.lld; both are required even in
#                  CONFIGURE_ONLY mode because LLVM=1 makes kconfig use them)
#   CONFIGURE_ONLY 1 = merge config, run olddefconfig and verify, then stop
#                  (used by CI so a config regression fails in minutes)
#   SMOKE_ONLY    1 = compile a handful of representative objects and stop
#                  (catches toolchain problems in ~5 min instead of ~1 h)
#   ENABLE_NTSYNC 1 = also apply the optional NTSYNC bundle to the config,
#                  the verification list and the smoke-test objects
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KERNEL_DIR="${KERNEL_DIR:-$PROJECT_DIR/work/src}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
PROFILE="${PROFILE:-full}"
LOCALVERSION="${LOCALVERSION:-}"
JOBS="${JOBS:-$(nproc --all)}"
EXTRA_MAKE="${EXTRA_MAKE:-}"
CONFIGURE_ONLY="${CONFIGURE_ONLY:-0}"
SMOKE_ONLY="${SMOKE_ONLY:-0}"
ENABLE_NTSYNC="${ENABLE_NTSYNC:-0}"
CC="${CC:-clang}"
LD="${LD:-ld.lld}"

[ -d "$KERNEL_DIR" ] || { echo "[x] KERNEL_DIR not found: $KERNEL_DIR" >&2; exit 1; }

# --- preflight --------------------------------------------------------------
# LLVM=1 makes the kernel use $(CC) and $(LD)=ld.lld even for the kconfig
# stage, where a missing one surfaces as a cryptic
#   scripts/Kconfig.include:41: linker 'ld.lld' not found
# Check here instead so the failure names the missing tool.
check_tool() {
    local cmd="${1%% *}"        # CC may be "ccache clang"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[x] required tool not found: $cmd" >&2
        echo "    Debian/Ubuntu: sudo apt-get install -y clang lld" >&2
        echo "    or override with CC=/path/to/clang LD=/path/to/ld.lld" >&2
        exit 1
    fi
}
check_tool "$CC"
check_tool "$LD"

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

EXTRA_REQUIRED=""
if [ "$ENABLE_NTSYNC" = "1" ]; then
    # Optional add-on; scripts/enable-ntsync.sh must already have installed the
    # driver and the Kconfig/Makefile hooks, otherwise merge_config.sh silently
    # drops CONFIG_NTSYNC and verify-config.sh fails.
    frags+=("$PROJECT_DIR/configs/optional/droidspaces-ntsync.config")
    EXTRA_REQUIRED="NTSYNC"
    echo "[i] NTSYNC add-on enabled"
fi
export EXTRA_REQUIRED

cd "$KERNEL_DIR"
mkdir -p "$OUT_DIR"

echo "[*] merging defconfig fragments (profile=$PROFILE)"
# merge_config.sh reads the fragments and writes the merged fragment file to
# $OUT_DIR/.config; 'make olddefconfig' then materialises every default.
KCONFIG_CONFIG="$OUT_DIR/.config" \
    scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "${frags[@]}"

if [ -n "$LOCALVERSION" ]; then
    echo "[*] pinning CONFIG_LOCALVERSION='$LOCALVERSION' (AUTO off)"
    # Invoke through sh explicitly: scripts/config relies on its shebang, which
    # needs /usr/bin/env (absent on some hosts).
    sh ./scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_LOCALVERSION "$LOCALVERSION"
    sh ./scripts/config --file "$OUT_DIR/.config" -d CONFIG_LOCALVERSION_AUTO
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

if [ "$SMOKE_ONLY" = "1" ]; then
    # Representative objects:
    #   kernel/fork.o                    - uses struct task_struct (our kABI change)
    #   net/netfilter/nf_tables_api.o    - CONFIG_NF_TABLES, enabled by this project
    #   net/netfilter/ipset/ip_set_core.o- CONFIG_IP_SET, enabled by this project
    smoke_objs=(
        kernel/fork.o
        net/netfilter/nf_tables_api.o
        net/netfilter/ipset/ip_set_core.o
    )
    if [ "$ENABLE_NTSYNC" = "1" ]; then
        # Validates the vendored NTSYNC driver on CI before the long build.
        smoke_objs+=(drivers/misc/ntsync.o)
    fi
    echo "[*] SMOKE_ONLY=1 - compiling ${#smoke_objs[@]} representative objects"
    # shellcheck disable=SC2086
    make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 \
         CC="$CC" LD="$LD" HOSTLD="$LD" \
         KCFLAGS+=-Wno-error $EXTRA_MAKE "${smoke_objs[@]}"
    echo "[+] smoke test passed - toolchain and config can compile this tree"
    exit 0
fi

echo "[*] building Image (-j$JOBS)"
# shellcheck disable=SC2086
make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 \
     CC="$CC" LD="$LD" HOSTLD="$LD" \
     KCFLAGS+=-Wno-error $EXTRA_MAKE Image

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[ -s "$IMAGE" ] || { echo "[x] Image was not produced" >&2; exit 1; }
echo "[+] built $IMAGE ($(stat -c%s "$IMAGE") bytes)"
echo "[+] release string: $(strings "$IMAGE" | grep -m1 -oE '^6\.[0-9]+\.[0-9]+[^ ]*' || echo '(unknown)')"

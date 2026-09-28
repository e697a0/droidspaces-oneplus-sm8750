#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Configure and build the Droidspaces kernel Image.
#
# Environment:
#   KERNEL_DIR    kernel source (default: ../work/src relative to this repo)
#   OUT_DIR       build output     (default: $KERNEL_DIR/out)
#   PROFILE       core | full      (default: full)
#   KERNEL_LOCALVERSION
#                  override the kernel release suffix (e.g. -4k-gdeadbeef1234).
#                  Leave unset to let CONFIG_LOCALVERSION_AUTO derive
#                  "-g<git sha>" from the clone, which is what the stock ROM
#                  does.  NOTE: do NOT name this variable LOCALVERSION --
#                  scripts/setlocalversion appends the *environment* variable
#                  LOCALVERSION on top of CONFIG_LOCALVERSION when
#                  LOCALVERSION_AUTO is off, which duplicates the suffix.
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
KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-}"
# Never let a stray LOCALVERSION from the caller leak into scripts/setlocalversion.
unset LOCALVERSION
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

if [ -n "$KERNEL_LOCALVERSION" ]; then
    echo "[*] pinning CONFIG_LOCALVERSION='$KERNEL_LOCALVERSION' (AUTO off)"
    # scripts/config is a BASH script (shebang "#!/usr/bin/env bash", and it
    # uses bash arrays).  Never call it as "sh scripts/config": on Debian and
    # Ubuntu /bin/sh is dash, which dies with
    #   scripts/config: 129: Syntax error: "(" unexpected
    # (That is exactly how the first clang-r563880c build failed.)  Call bash
    # explicitly so it works on every host, including ones where /usr/bin/env
    # or the exec bit are unavailable.
    bash ./scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_LOCALVERSION "$KERNEL_LOCALVERSION"
    bash ./scripts/config --file "$OUT_DIR/.config" -d CONFIG_LOCALVERSION_AUTO
    # scripts/setlocalversion ends with:
    #   echo "${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}"
    # so with LOCALVERSION_AUTO off it appends the ENVIRONMENT variable
    # LOCALVERSION on top of CONFIG_LOCALVERSION.  Export it as empty (set but
    # empty) so it contributes nothing; leaving it *unset* would instead make
    # setlocalversion append a "+".
    export LOCALVERSION=""
else
    echo "[*] no KERNEL_LOCALVERSION override: CONFIG_LOCALVERSION_AUTO=y will"
    echo "    append -g<12-char git sha> to CONFIG_LOCALVERSION (default '-4k')"
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

RELEASE="$(strings "$IMAGE" | grep -m1 -oE '^6\.[0-9]+\.[0-9]+[^ ]*' || echo '(unknown)')"
echo "[+] release string: $RELEASE"

# Guard against a duplicated suffix.  A real bug we hit: scripts/setlocalversion
# appends both CONFIG_LOCALVERSION and the LOCALVERSION environment variable, so
# the suffix showed up twice and the vermagic no longer matched the ROM modules.
DUP=$(printf '%s' "$RELEASE" | grep -o -- '-4k' | wc -l)
if [ "$DUP" -gt 1 ]; then
    echo "[x] release string contains '-4k' $DUP times: $RELEASE" >&2
    echo "    CONFIG_LOCALVERSION and the LOCALVERSION env var were both appended." >&2
    exit 1
fi

# The stock ROM reports 6.6.142-4k-gedc821586bcb with no "-dirty".
# CONFIG_LOCALVERSION_AUTO=y adds "-dirty" whenever the git tree has local
# changes, and this project always patches include/linux/sched.h, so the clone
# is always dirty.  KERNEL_LOCALVERSION pins the suffix instead.
case "$RELEASE" in
    *-dirty*)
        echo "[x] release string is marked dirty: $RELEASE" >&2
        echo "    pin it with KERNEL_LOCALVERSION (see the workflow step)." >&2
        exit 1
        ;;
esac

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Verify that every CONFIG_ symbol used by configs/*.config is actually
# declared in the kernel's Kconfig files.
#
# This catches a subtle failure mode: merge_config.sh silently drops symbols it
# does not know, and `make olddefconfig` then simply never sets them — the build
# succeeds but Droidspaces support is missing.  (The upstream Droidspaces guide
# already contains two such stale names for 6.6: NETFILTER_XT_TARGET_REJECT and
# NF_CONNTRACK_NETLINK.)
#
# usage: check-kconfig-symbols.sh <kernel-dir>
set -euo pipefail

KERNEL_DIR="${1:-}"
[ -n "$KERNEL_DIR" ] && [ -d "$KERNEL_DIR" ] || {
    echo "usage: check-kconfig-symbols.sh <kernel-dir>" >&2
    exit 2
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

total=0
missing=0
while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    total=$((total + 1))
    if ! grep -rqE "^(menu)?config ${opt}\$" --include='Kconfig*' "$KERNEL_DIR" 2>/dev/null; then
        echo "[x] CONFIG_${opt} is not declared in any Kconfig" >&2
        missing=$((missing + 1))
    fi
done < <(cat "$PROJECT_DIR"/configs/*.config \
         | grep -oE '^CONFIG_[A-Z0-9_]+' \
         | sed 's/^CONFIG_//' \
         | sort -u)

if [ "$missing" -ne 0 ]; then
    echo "[x] $missing of $total symbols are unknown — fix configs/*.config" >&2
    exit 1
fi
echo "[+] all $total config symbols are declared in Kconfig"

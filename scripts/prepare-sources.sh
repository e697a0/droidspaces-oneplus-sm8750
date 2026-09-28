#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Clone the three LineageOS trees needed by android_kernel_oneplus_sm8750.
#
# WHY THREE TREES?
# The kernel tree contains many *relative* symbolic links that escape the tree,
# for example:
#     drivers/base/kernelFwUpdate -> ../../../sm8750-modules/oplus/kernel/touchpanel/kernelFwUpdate
#     arch/arm64/boot/dts/vendor  -> ../../../../../sm8750-devicetrees
# They resolve to siblings of the kernel root, so the directory layout must be
#     <work>/src  <work>/sm8750-modules  <work>/sm8750-devicetrees
# If the modules tree is missing, Kconfig cannot source
# "drivers/base/kernelFwUpdate/Kconfig" and the build dies before compiling
# anything.
set -euo pipefail

REPO_BASE="${REPO_BASE:-https://github.com}"
KERNEL_REPO="${KERNEL_REPO:-LineageOS/android_kernel_oneplus_sm8750}"
MODULES_REPO="${MODULES_REPO:-LineageOS/android_kernel_oneplus_sm8750-modules}"
DEVICETREES_REPO="${DEVICETREES_REPO:-LineageOS/android_kernel_oneplus_sm8750-devicetrees}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-23.2}"
WORK_DIR="${WORK_DIR:-$PWD/work}"
GIT_DEPTH="${GIT_DEPTH:-1}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

clone() {
    local repo="$1" dir="$2"
    if [ -d "$dir/.git" ]; then
        echo "[*] $dir already present, skipping"
        return 0
    fi
    echo "[*] cloning $repo @ $KERNEL_BRANCH -> $dir"
    for attempt in 1 2 3; do
        if git clone --depth="$GIT_DEPTH" --single-branch --branch "$KERNEL_BRANCH" \
                "$REPO_BASE/$repo.git" "$dir"; then
            return 0
        fi
        echo "[!] clone failed (attempt $attempt/3), retrying in 5s..."
        rm -rf "$dir"
        sleep 5
    done
    echo "[x] could not clone $repo" >&2
    return 1
}

clone "$KERNEL_REPO"      src
clone "$MODULES_REPO"     sm8750-modules
clone "$DEVICETREES_REPO" sm8750-devicetrees

# --- sanity: every symlink that points outside the kernel tree must resolve ---
echo "[*] checking external symlinks..."
bad=0
while IFS= read -r link; do
    if [ ! -e "$link" ]; then
        echo "[x] dangling symlink: $link -> $(readlink "$link")" >&2
        bad=1
    fi
done < <(find src -xtype l 2>/dev/null | grep -E 'sm8750-(modules|devicetrees)' || true)

if [ "$bad" -ne 0 ]; then
    echo "[x] companion trees are incomplete" >&2
    exit 1
fi
echo "[+] sources ready in $WORK_DIR"

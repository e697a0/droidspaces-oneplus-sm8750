#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Download and install the AOSP clang used by this kernel tree.
#
# The tree's build.config.constants says:  CLANG_VERSION=r510928
# We therefore default to clang-r510928 but accept any version and any mirror.
#
# Environment:
#   CLANG_VERSION  e.g. clang-r510928
#   CLANG_URL      explicit archive URL (.zip or .tar.gz) — highest priority
#   CLANG_DEST     install directory (default: $PWD/clang)
set -euo pipefail

CLANG_VERSION="${CLANG_VERSION:-clang-r510928}"
CLANG_URL="${CLANG_URL:-}"
CLANG_DEST="${CLANG_DEST:-$PWD/clang}"

command -v curl >/dev/null || { echo "[x] curl is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

try_url() {
    local url="$1" out="$2"
    echo "[*] trying: $url"
    rm -f "$out"
    if ! curl -fsSL --retry 2 --retry-delay 3 --connect-timeout 30 -o "$out" "$url"; then
        echo "[!] download failed"
        return 1
    fi
    local size
    size="$(stat -c%s "$out" 2>/dev/null || echo 0)"
    # AOSP googlesource answers a wrong branch with a *valid* but empty archive.
    if [ "$size" -lt 1000000 ]; then
        echo "[!] archive is only ${size} bytes — wrong branch/version, skipping"
        return 1
    fi
    echo "[+] downloaded $(awk -v s="$size" 'BEGIN{printf "%.1f", s/1048576}') MiB"
    return 0
}

# ---------------------------------------------------------------- candidates
cands=()
[ -n "$CLANG_URL" ] && cands+=("$CLANG_URL")

# GitHub-hosted mirror (fast, no googlesource dependency) — only r510928 exists
if [ "$CLANG_VERSION" = "clang-r510928" ]; then
    cands+=("https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang18-r510928/clang-r510928.zip")
fi

# Canonical AOSP source.  The branch/version pairs are not guessable, so try all.
for branch in main-kernel-build-2024 main-kernel-2025 main-kernel-2026 main-kernel; do
    cands+=("https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${branch}/${CLANG_VERSION}.tar.gz")
done

ok=0
for url in "${cands[@]}"; do
    case "$url" in
        *.zip)    ext=zip ;;
        *.tar.gz) ext=tar.gz ;;
        *)        ext=tar.gz ;;
    esac
    file="$WORK/clang.$ext"

    rm -rf "$CLANG_DEST"; mkdir -p "$CLANG_DEST"
    try_url "$url" "$file" || continue

    case "$ext" in
        zip)    unzip -q -o "$file" -d "$CLANG_DEST" || continue ;;
        tar.gz) tar -xzf "$file" -C "$CLANG_DEST"  || continue ;;
    esac

    # Some archives nest everything under a single top-level directory.
    if [ ! -x "$CLANG_DEST/bin/clang" ]; then
        inner="$(find "$CLANG_DEST" -maxdepth 3 -type f -name clang -perm -u+x 2>/dev/null | head -1)"
        if [ -n "$inner" ]; then
            root="$(dirname "$(dirname "$inner")")"
            shopt -s dotglob
            mv "$root"/* "$CLANG_DEST"/ 2>/dev/null || true
            shopt -u dotglob
            rmdir "$root" 2>/dev/null || true
        fi
    fi

    if [ -x "$CLANG_DEST/bin/clang" ] && [ -x "$CLANG_DEST/bin/ld.lld" ]; then
        ok=1
        break
    fi
    echo "[!] $url extracted but clang/ld.lld not found, trying next candidate"
done

if [ "$ok" -ne 1 ]; then
    echo "[x] could not obtain a usable $CLANG_VERSION" >&2
    echo "    Set the repository variable CLANG_URL to a direct .zip/.tar.gz of an AOSP clang." >&2
    exit 1
fi

chmod -R u+rwX "$CLANG_DEST"
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$CLANG_DEST/bin" >> "$GITHUB_PATH"
fi
export PATH="$CLANG_DEST/bin:$PATH"
echo "[+] installed to $CLANG_DEST"
clang --version
ld.lld --version

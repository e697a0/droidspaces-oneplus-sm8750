#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Fail fast if the generated .config does not contain the Droidspaces options.
# Runs before the (long) compile so a config regression costs seconds, not an hour.
#
# usage: verify-config.sh <.config> [core|full]
#
# Environment:
#   EXTRA_REQUIRED  space separated symbols that must additionally be =y
#                   (used for optional add-ons such as NTSYNC)
set -euo pipefail

CONFIG="${1:?usage: verify-config.sh <.config> [core|full]}"
PROFILE="${2:-full}"
EXTRA_REQUIRED="${EXTRA_REQUIRED:-}"

[ -f "$CONFIG" ] || { echo "[x] no such config: $CONFIG" >&2; exit 1; }

core_opts=(
    SYSVIPC
    POSIX_MQUEUE
    IPC_NS
    PID_NS
    DEVTMPFS
    NETFILTER_XT_MATCH_ADDRTYPE
    USER_NS
    IP_NF_TARGET_REJECT
    NETFILTER_XT_TARGET_LOG
    NETFILTER_XT_MATCH_RECENT
    IP_SET
    IP_SET_HASH_IP
    IP_SET_HASH_NET
    NETFILTER_XT_SET
    TMPFS_POSIX_ACL
    TMPFS_XATTR
)
full_opts=(
    NAMESPACES
    UTS_NS
    NET_NS
    TIME_NS
    SECCOMP
    SECCOMP_FILTER
    CGROUPS
    CGROUP_DEVICE
    CGROUP_PIDS
    CGROUP_FREEZER
    CGROUP_NET_PRIO
    OVERLAY_FS
    VETH
    BRIDGE
    NETFILTER
    NF_CONNTRACK
    NF_NAT
    NF_NAT_REDIRECT
    NF_TABLES
    IP_NF_IPTABLES
    IP_NF_FILTER
    IP_NF_TARGET_MASQUERADE
    NETFILTER_XT_TARGET_MASQUERADE
    NETFILTER_XT_TARGET_TCPMSS
    NF_CT_NETLINK
    IP_ADVANCED_ROUTER
    IP_MULTIPLE_TABLES
    NETFILTER_NETLINK_QUEUE
    NETFILTER_NETLINK_LOG
    NETFILTER_XT_TARGET_NFLOG
)

opts=("${core_opts[@]}")
if [ "$PROFILE" = "full" ]; then
    opts+=("${full_opts[@]}")
fi
if [ -n "$EXTRA_REQUIRED" ]; then
    # shellcheck disable=SC2206
    extra=(${EXTRA_REQUIRED})
    opts+=("${extra[@]}")
fi

fail=0
for o in "${opts[@]}"; do
    line="$(grep -E "^(# )?CONFIG_${o}( |$|=)" "$CONFIG" | head -1 || true)"
    case "$line" in
        "CONFIG_${o}=y") ;;
        "")               echo "[x] CONFIG_${o} missing from .config" >&2; fail=1 ;;
        *)                echo "[x] CONFIG_${o} is not 'y': $line" >&2; fail=1 ;;
    esac
done

# kABI guard: the patch must have moved sysv_sem/sysv_shm into the reserves.
# (Checked by the caller against the source tree; here we only sanity check the
#  resulting configuration.)
if [ "$fail" -ne 0 ]; then
    echo "[x] config verification FAILED (profile=$PROFILE)" >&2
    exit 1
fi
echo "[+] config verification passed (${#opts[@]} options, profile=$PROFILE)"

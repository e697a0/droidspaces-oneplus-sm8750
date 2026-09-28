# 调研记录（Task 1）

记录本项目的所有关键事实、来源和判断依据。所有结论都基于**实际下载并阅读**的源码/配置/补丁，
不是猜测。用于日后内核升级时快速复核。

---

## 1. 目标内核

| 项 | 值 | 依据 |
|---|---|---|
| 仓库 | `LineageOS/android_kernel_oneplus_sm8750` | 目标仓库 |
| 默认分支 | `lineage-23.2` | 上游 branch HEAD `edc82158…`，与本机 `uname -r` 的 `gedc821586bcb` 一致 |
| 内核版本 | 6.6.142（`lineage-23.2`）/ 6.6.126（`lineage-23.0`、`23.1`）/ 6.6.104（`22.2`） | 仓库根 `Makefile` |
| 平台代号 | `sun` = SM8750（Snapdragon 8 Elite） | `build.config.msm.sun`、`BoardConfigCommon.mk` |
| 内核类型 | **GKI**（`KMI_ENFORCED=1`、`android/abi_gki_aarch64_qcom`） | `build.config.msm.perf` |
| 内核编译工具链 | AOSP clang **r510928**、LLVM=1 | `build.config.constants` |

---

## 2. Droidspaces 的官方要求

来源：`ravindu644/Droidspaces-OSS` → `Documentation/Kernel-Configuration.md`（已存档到
`docs/upstream-Droidspaces-Kernel-Configuration.md`）。

- **非 GKI（3.18–4.19）**：直接把一大堆 `CONFIG_*` 写进 defconfig 即可。
- **GKI（5.4 / 5.10 / 5.15 / 6.1 / 6.6 / 6.12+）**：
  1. **必须**先打 kABI 补丁（按内核版本选）；
  2. **只能**启用文档里列出的那组配置；
  3. 不要用 fragment，官方建议直接改 `gki_defconfig`。

> 官方原文：*“Without them, the device bootloops as soon as you enable
> `CONFIG_SYSVIPC`, `CONFIG_IPC_NS` or `CONFIG_POSIX_MQUEUE`.”*

---

## 3. 本内核的实际配置组成

来自 `LineageOS/android_device_oneplus_sm8750-common` 的 `BoardConfigCommon.mk`：

```make
TARGET_KERNEL_SOURCE := kernel/oneplus/sm8750
TARGET_KERNEL_ADDITIONAL_FLAGS := CONFIG_OPLUS_DEVICE_DTBS=y
TARGET_KERNEL_CONFIG := \
    gki_defconfig \
    vendor/sun_perf.config \
    vendor/oplus/sun_perf.config
```

也就是说最终配置 = **`gki_defconfig` ⊕ `vendor/sun_perf.config` ⊕ `vendor/oplus/sun_perf.config`**。
`build-kernel.sh` 用 `scripts/kconfig/merge_config.sh` 复刻同样的合并顺序，再追加本项目的 fragment。

### 审计结果（`lineage-23.2`，三份配置里 Droidspaces 相关选项的现状）

| 选项 | gki_defconfig | 结论 |
|---|---|---|
| `SYSVIPC` / `POSIX_MQUEUE` | 缺失 | Kconfig 默认 **n** → 必须显式开 |
| `PID_NS` | **显式 `is not set`** | 必须显式开 |
| `USER_NS` | 缺失 | Kconfig 默认 **n** → 必须显式开 |
| `IPC_NS` / `UTS_NS` / `NET_NS` | 缺失 | 默认 y（且 `IPC_NS` 依赖 `SYSVIPC||POSIX_MQUEUE`），显式写更稳妥 |
| `DEVTMPFS` / `TMPFS_XATTR` / `TMPFS_POSIX_ACL` | 缺失 | 默认 y，显式写更稳妥 |
| `CGROUP_DEVICE` / `CGROUP_PIDS` | 缺失 | Kconfig 默认 **n** → 属于扩展项 |
| `OVERLAY_FS` / `VETH` / `BRIDGE` / `CGROUP_FREEZER` / `CGROUP_NET_PRIO` | 已 `=y` | 无需再开 |
| `NETFILTER_XT_MATCH_ADDRTYPE` | 缺失 | 默认 **m** → 改成 `=y` 才能内建生效（本项目不刷模块） |
| `NF_TABLES` | 缺失 | 默认 **n** |
| `CONFIG_MODULE_SIG_FORCE` | 未设置 | 模块签名失败只 taint，不拒载 |
| `CONFIG_CFI_CLANG` | `=y`，`LTO_NONE` | clang 21 的 kCFI 不需要 LTO |

---

## 4. kABI 补丁：为什么是 `6_7_8` 变体

`include/linux/sched.h` 中 `struct task_struct` 尾部（`lineage-23.2` 第 1529–1535 行）：

```c
ANDROID_KABI_USE(1, struct task_dma_buf_info *dmabuf_info);
ANDROID_KABI_USE(2, struct {
        /* Save user-dumpable when mm goes away */
        unsigned        user_dumpable:1;
        });

ANDROID_KABI_RESERVE(3);
ANDROID_KABI_RESERVE(4);
ANDROID_KABI_RESERVE(5);
ANDROID_KABI_RESERVE(6);
ANDROID_KABI_RESERVE(7);
ANDROID_KABI_RESERVE(8);
```

- **槽位 1、2 已被 `ANDROID_KABI_USE` 占用**；
- 三份候选补丁的上下文要求分别是：
  - `1_2_3`：要求 `ANDROID_KABI_RESERVE(1)`、`(2)` → **打不上**
  - `3_4_5`：要求 `ANDROID_KABI_RESERVE(1)`、`(2)`、`(3)`… → **打不上**
  - `6_7_8`：要求 `RESERVE(3)(4)(5)` 与 `RESERVE(6)(7)(8)` → **✅ 匹配**

实测（`patch -p1 --dry-run`，`lineage-23.2`）：

```
Hunk #1 succeeded at 1076 (offset 2 lines).
Hunk #2 succeeded at 1530 with fuzz 2 (offset 17 lines).
PATCH APPLIES CLEANLY
```

补丁做的事：

```c
#ifdef CONFIG_SYSVIPC
-       struct sysv_sem                  sysvsem;
-       struct sysv_shm                  sysvshm;
+       // struct sysv_sem              sysvsem;
+       // struct sysv_shm              sysvshm;
#endif
...
+#ifdef CONFIG_SYSVIPC
+       ANDROID_KABI_USE(6, struct sysv_sem sysvsem);
+       _ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);
+#else
        ANDROID_KABI_RESERVE(6);
        ANDROID_KABI_RESERVE(7);
        ANDROID_KABI_RESERVE(8);
+#endif
```

`sysv_sem` = 8 字节 → 占 1 个槽位（6）；`sysv_shm` = 16 字节（`struct list_head`）→ 占 2 个槽位（7、8）。
**总量不变**，所以 `sizeof(struct task_struct)` 和后续偏移全都不变。

### 交叉验证

同平台项目 `Draklyfg/oneplus-sm8750-kernel-pro-build`（LineageOS 23.2 / SM8750 / 6.6.142）
的 `patches/split/05_droidspaces.patch` 里 **完全相同的两段 hunk**，证实这是这棵树上的正确做法。

---

## 5. 构建方式

### 5.1 为什么用裸 `make`

内核树里**没有** `build/build.sh`，只有 Qualcomm 的 `build.config.*` + Bazel（`build_with_bazel.py`）。
Qualcomm 的 `build.config.msm.common` 依赖 AOSP 树布局（`${ROOT_DIR}/msm-kernel/...`、
`${ROOT_DIR}/external/dtc`），在一棵独立 clone 的树里跑不起来。

实际可用的是裸 `make`：

```bash
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image
```

这棵树的 `scripts/Makefile.clang` **硬编码**了目标三元组：

```make
CLANG_TARGET_FLAGS_arm64 := aarch64-linux-gnu
...
CLANG_FLAGS += --target=$(CLANG_TARGET_FLAGS)
```

所以**不需要设置 `CROSS_COMPILE`**（已经验证：`arch/arm64/Makefile` 里没有 `CROSS_COMPILE` 逻辑）。

### 5.2 三棵源码树

内核树里大量软链接指向**兄弟目录**：

```
drivers/base/kernelFwUpdate  -> ../../../sm8750-modules/oplus/kernel/touchpanel/kernelFwUpdate
drivers/soc/oplus/boot       -> ../../../../sm8750-modules/oplus/kernel/boot
arch/arm64/boot/dts/vendor   -> ../../../../../sm8750-devicetrees
```

因为 `drivers/base/Kconfig` 里有 `source "drivers/base/kernelFwUpdate/Kconfig"`，
**缺 modules 树会在配置阶段直接失败**。所以 `prepare-sources.sh` 必须把三棵树放成：

```
work/src  work/sm8750-modules  work/sm8750-devicetrees
```

### 5.3 release 字符串 / vermagic

ROM 里 `vendor_dlkm` 的模块是按 `6.6.142-4k-g<commit>` 编译的。vermagic 包含完整 release 字符串，
不一致会导致模块拒载。LineageOS 用 `CONFIG_LOCALVERSION_AUTO` 自动加 `-g<sha12>`，
所以构建时显式合成同样的字符串：

```
CONFIG_LOCALVERSION="-4k-g$(git rev-parse HEAD | cut -c1-12)"
# CONFIG_LOCALVERSION_AUTO is not set
```

> 参考项目的 README 声称“版本串不一致也没事”，但那依赖具体 ROM 行为，**不可靠**。
> 本项目选择严格匹配。

### 5.4 只编译 `Image`

- `BoardConfigCommon.mk`：`BOARD_KERNEL_IMAGE_NAME := Image`、`BOARD_BOOT_HEADER_VERSION := 4`
- `BOARD_INCLUDE_DTB_IN_BOOTIMG := true` → DTB 在 boot.img 里，AnyKernel3 会保留原 DTB
- `init_boot` 单独存在（8 MiB）→ generic ramdisk 不在 boot.img 里
- 因此 AnyKernel3 走 `split_boot` + `flash_boot`（不重打包 ramdisk）即可

不需要编译 modules，因为 Droidspaces 需要的选项全部是内建（`=y`）。

---

## 6. Droidspaces “扩展”能力（本项目默认不启用）

| 能力 | 需要的配置/补丁 | 说明 |
|---|---|---|
| NAT 网络 | `VETH` `BRIDGE` `NF_NAT` `NF_NAT_REDIRECT` `NETFILTER_XT_MATCH_ADDRTYPE` | ✅ 本项目 `full` 档已包含 |
| UFW / Fail2ban | `IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG` `NETFILTER_XT_MATCH_RECENT` `IP_SET` `NETFILTER_XT_SET` | ✅ 本项目 `full` 档已包含 |
| Docker/Podman/LXC 嵌套 | `NF_TABLES` | ✅ 本项目 `full` 档已包含 |
| NixOS | `TMPFS_POSIX_ACL` `TMPFS_XATTR` | ✅ 已包含 |
| **NTSYNC**（Wine/Proton 同步原语） | `drivers/misc/ntsync.c`（约 1700 行新源码）+ `CONFIG_NTSYNC` | ❌ 需要引入新源码 |
| **Lindroid / EVDI 虚拟显示** | `drivers/gpu/drm/evdi/`（新源码）+ `CONFIG_DRM_LINDROID_EVDI` | ❌ 需要引入新源码 |

参考项目把这两项打包成 `05_droidspaces.patch`（含 `patches/extra/` 里的新源码）。
本项目聚焦“容器本体”，只应用官方文档定义的完整支持；如果之后需要，可以再单独加。

---

## 7. 已知风险点

1. **`CONFIG_CGROUP_DEVICE` / `CONFIG_CGROUP_PIDS`**：官方文档说是必须，但同平台参考项目的
   可用配置里这两项是 `not set`。本项目放在 `full` 档；若 `full` 档异常，用 `core` 档定位。
2. **`CONFIG_BRIDGE_NETFILTER`**：官方非 GKI 清单里有，但可能改变厂商 WLAN 模块用到的结构，
   本项目**故意不开**（Droidspaces NAT 模式在 6.6 上不需要它）。
3. **`oplus_bsp_midas` ghost-task hack**：参考项目在 `find_task_by_vpid()` 里加了一个
   “幽灵 task” 兜底，用来绕过某厂商模块的空指针。本项目**没有**采用（属于掩盖厂商模块 bug 的
   hack，且无法确认是否必要）。如果开启命名空间后出现 `oplus_bsp_midas` 相关崩溃，可参考该做法。
4. **上游漂移**：`lineage-23.2` 更新后，`sched.h` 行号/上下文可能变化。构建流程里的
   `grep -q 'ANDROID_KABI_USE(6, ...)'` 会在补丁失效时**立刻失败**，而不是产出一个坏内核。

---

## 8. 资料来源

- [ravindu644/Droidspaces-OSS — Kernel-Configuration.md](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md)
- [LineageOS/android_device_oneplus_sm8750-common — BoardConfigCommon.mk](https://github.com/LineageOS/android_device_oneplus_sm8750-common/blob/lineage-23.2/BoardConfigCommon.mk)
- [LineageOS/android_kernel_oneplus_sm8750](https://github.com/LineageOS/android_kernel_oneplus_sm8750)
- [Draklyfg/oneplus-sm8750-kernel-pro-build](https://github.com/Draklyfg/oneplus-sm8750-kernel-pro-build)（LineageOS 23.2 / SM8750 实战项目）
- [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750)（GKI 构建范式）
- [cctv18/oneplus_sm8650_toolchain](https://github.com/cctv18/oneplus_sm8650_toolchain)（clang r510928 镜像）
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)

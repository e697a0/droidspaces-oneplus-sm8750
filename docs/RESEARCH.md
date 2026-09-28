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

## 6. Droidspaces “扩展”能力

| 能力 | 需要的配置/补丁 | 说明 |
|---|---|---|
| NAT 网络 | `VETH` `BRIDGE` `NF_NAT` `NF_NAT_REDIRECT` `NETFILTER_XT_MATCH_ADDRTYPE` | ✅ 本项目 `full` 档已包含 |
| UFW / Fail2ban | `IP_NF_TARGET_REJECT NETFILTER_XT_TARGET_LOG` `NETFILTER_XT_MATCH_RECENT` `IP_SET` `NETFILTER_XT_SET` | ✅ 本项目 `full` 档已包含 |
| Docker/Podman/LXC 嵌套 | `NF_TABLES` | ✅ 本项目 `full` 档已包含 |
| NixOS | `TMPFS_POSIX_ACL` `TMPFS_XATTR` | ✅ 已包含 |
| **NTSYNC**（Wine/Proton 同步原语） | `patches/optional/ntsync/`（约 1000 行新源码）+ `CONFIG_NTSYNC=y` | ✅ **已提供，默认关闭**；工作流 `ntsync=true` 启用 |
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
4. **上游漂移**：`lineage-23.2` 更新后，`sched.h` 行号/上下文可能变化。三道防线：构建流程里
   `patch --dry-run` + `grep -q 'ANDROID_KABI_USE(6, ...)'` 会在补丁失效时**立刻失败**；
   `.github/workflows/validate.yml` 还会**每周**对 5 个分支 dry-run 补丁并复跑配置校验，
   提前发现问题而不是等你自己撞上。

---

## 8. 资料来源

- [ravindu644/Droidspaces-OSS — Kernel-Configuration.md](https://github.com/ravindu644/Droidspaces-OSS/blob/main/Documentation/Kernel-Configuration.md)
- [LineageOS/android_device_oneplus_sm8750-common — BoardConfigCommon.mk](https://github.com/LineageOS/android_device_oneplus_sm8750-common/blob/lineage-23.2/BoardConfigCommon.mk)
- [LineageOS/android_kernel_oneplus_sm8750](https://github.com/LineageOS/android_kernel_oneplus_sm8750)
- [Draklyfg/oneplus-sm8750-kernel-pro-build](https://github.com/Draklyfg/oneplus-sm8750-kernel-pro-build)（LineageOS 23.2 / SM8750 实战项目）
- [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750)（GKI 构建范式）
- [cctv18/oneplus_sm8650_toolchain](https://github.com/cctv18/oneplus_sm8650_toolchain)（clang r510928 镜像）
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)

---

## 9. 编译期注意事项（实测确认）

### 9.1 `CONFIG_WERROR` 默认开启 → 必须 `-Wno-error`

`init/Kconfig`：

```kconfig
config WERROR
	bool "Compile the kernel with warnings as errors"
	default y
```

`gki_defconfig` 里**没有** `CONFIG_WERROR`，所以取默认值 **y**。
`scripts/Makefile.extrawarn` 会把 `-Werror` 加进 `KBUILD_CPPFLAGS`。
因为我们新增了一批之前只以模块形态存在的代码路径，为避免新警告直接变成编译错误，
`build-kernel.sh` 传了 `KCFLAGS+=-Wno-error`。
`KBUILD_CFLAGS += $(KCFLAGS)` 位于 `Makefile:1083`，排在 `KBUILD_CPPFLAGS` 之后，
因此能覆盖 `-Werror`（`make -n` 输出中确认 `-Wno-error` 出现 142 次）。

### 9.2 不需要 `certs/extract-cert.c` 编译修复补丁

参考项目无条件应用了一个修补 `certs/extract-cert.c` 的 `07_compile_fixes.patch`。
本树（`lineage-23.2`）**已经有正确的保护**：

```c
 80: #ifdef USE_PKCS11_ENGINE
 81: static const char *key_pass;
...
152: #ifdef USE_PKCS11_ENGINE
153: 	if (key_pass)
154: 		ERR(!ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0), "Set PKCS#11 PIN");
```

所以本项目**不引入**该补丁。另外该文件是 host 程序，走 `HOSTCFLAGS`，`CONFIG_WERROR` 对它无效。

### 9.3 目标三元组由内核树自己决定

`scripts/Makefile.clang` 硬编码了目标三元组：

```make
CLANG_TARGET_FLAGS_arm64 := aarch64-linux-gnu
...
CLANG_FLAGS += --target=$(CLANG_TARGET_FLAGS)
```

`arch/arm64/Makefile` 里**没有任何** `CROSS_COMPILE` 逻辑，
`make -n ... Image` 也确认实际命令是 `clang ... --target=aarch64-linux-gnu`，
因此**不需要**设置 `CROSS_COMPILE`。
### 9.4 厂商模块不会被 `MODULE_SIG_PROTECT` 拒载

`gki_defconfig` 里有：

```
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_PROTECT=y
```

看起来吓人（符号访问不合法时会返回 `-EACCES`），但实际走的是宽松路径：

- `kernel/module/internal.h` 中，`gki_is_module_unprotected_symbol()` 在
  `NR_UNPROTECTED_SYMBOLS == 0` 时**直接返回 true**（等于“所有符号都可访问”）；
  `gki_is_module_protected_export()` 同样返回 false（不做导出保护）。
- `NR_UNPROTECTED_SYMBOLS` 来自 `include/generated/gki_module_unprotected.h`，
  其输入是 `ALL_KMI_SYMBOLS`：

```make
kernel/module/Makefile:38: ALL_KMI_SYMBOLS := include/config/abi_gki_kmi_symbols
```

- 全树搜索 `abi_gki_kmi_symbols` **只有这一处引用**，没有任何规则去填充它；
  因此裸 `make` 下它由 `: > $@` 创建成**空文件** → 未保护符号数为 0 → 走宽松分支。
  （AOSP 的 `build/build.sh` 才会通过 `KMI_SYMBOL_LIST` 填充它。）

实测生成的头文件是合法 C：

```c
#define NR_UNPROTECTED_SYMBOLS (ARRAY_SIZE(gki_unprotected_symbols))
#define MAX_UNPROTECTED_NAME_LEN (1)
static const char gki_unprotected_symbols[][MAX_UNPROTECTED_NAME_LEN] = {
};
```

另外 `CONFIG_MODULE_SIG_FORCE` **没有**开启，即使签名校验不通过也只是 taint，不会拒载。
结论：ROM 里 500+ 个厂商 `.ko` 不会因为符号保护或签名被拦下。
### 9.5 可选的 NTSYNC 扩展

NTSYNC 是官方 Droidspaces 要求清单**之外**的能力，只有要在容器里跑 Windows 软件
（Wine / Proton / Steam）时才需要。它无法只靠配置片段实现 —— 驱动是**新文件**，还要往
`drivers/misc/{Kconfig,Makefile}` 加 hook。所以做成一个独立 bundle：

```
patches/optional/ntsync/
├── 0001-ntsync-hooks.patch          # 从参考项目的 05_droidspaces.patch 中精确提取
└── files/
    ├── drivers/misc/ntsync.c        # 28812 字节
    └── include/uapi/linux/ntsync.h  # 1614 字节
```

由 `scripts/enable-ntsync.sh` 安装（具备幂等性：第二次运行会跳过 hook）。

### 为什么必须 `=y` 而不是 `=m`

本项目只刷 `boot` 分区里的内核 Image，**不动 `vendor_dlkm` / `system_dlkm`**。
如果 `CONFIG_NTSYNC=m`，新驱动会被编进模块分区，而那个分区根本没被替换
→ 容器里 `/dev/ntsync` 不会出现。所以 `configs/optional/droidspaces-ntsync.config` 写死 `CONFIG_NTSYNC=y`。
（参考项目同样用 `=y`。）

### 版本兼容

`ntsync.c` 内建了内核版本分支：

```c
 30: #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
1218: #if LINUX_VERSION_CODE < KERNEL_VERSION(5,12,0)
1220: #elif LINUX_VERSION_CODE < KERNEL_VERSION(6,3,0)
```

适配版本来自同平台参考项目（同一棵 LineageOS 23.2 / SM8750 树，实机验证过）。
本项目额外把 `drivers/misc/ntsync.o` 加入 CI 冒烟测试目标 —— 一旦它编译不过，
5 分钟内就会失败，而不是等完整构建跑完。
### 9.6 `scripts/setlocalversion` 会额外拼接环境变量 `LOCALVERSION`

这是我实际踩到的坑，记录下来以免重犯。`scripts/setlocalversion` 最后一行是：

```sh
echo "${KERNELVERSION}${file_localversion}${config_localversion}${LOCALVERSION}${scm_version}"
```

而它前面是这样决定 `scm_version` 的：

```sh
if grep -q "^CONFIG_LOCALVERSION_AUTO=y$" include/config/auto.conf; then
    scm_version="$(scm_version)"
elif [ "${LOCALVERSION+set}" != "set" ]; then
    scm_version="$(scm_version --short)"   # 未设置时会被追加一个 "+"
fi
```

也就是说：**当 `CONFIG_LOCALVERSION_AUTO` 不是 `y` 时，环境变量 `LOCALVERSION` 会被直接拼到版本串上**，
与 `CONFIG_LOCALVERSION` 叠加。

本项目的 CI 最初用 `LOCALVERSION` 作为环境变量名传递后缀，于是产物变成：

```
6.6.142-4k-gedc821586bcb-4k-gedc821586bcb
```

（实测复现：`CONFIG_LOCALVERSION` 与环境变量取同值时，`setlocalversion` 的输出与线上内核逐字节一致。）

**正确做法**（已实现）：

1. 变量改名为 `KERNEL_LOCALVERSION`，并 `unset LOCALVERSION`；
2. **默认不覆盖**：保留 `CONFIG_LOCALVERSION_AUTO=y` + `CONFIG_LOCALVERSION="-4k"`，
   由 git 自动产生 `-4k-g<sha12>`，与 ROM 一致；
3. 需要强制指定时，写 `CONFIG_LOCALVERSION`、关掉 `AUTO`，并 `export LOCALVERSION=""`
   （置空但**必须存在**，否则会被追加 `+`）；
4. 构建结束时断言 release 字符串里 `-4k` 只出现一次，否则直接让构建失败。
### 9.7 目标平台是纯 64 位，AnyKernel3 上游工具是 32 位（打包必须自备 AArch64 工具）

**现象**：TWRP / 管理器刷入只报一行 `Busybox setup failed. Aborting...`。

**证据链**（全部实测）：

```
$ getprop ro.product.cpu.abilist      → arm64-v8a
$ getprop ro.product.cpu.abilist32    → （空）

$ ./tools/busybox                     → cannot execute binary file: Exec format error

$ 读 ELF 头 tools/*                    → busybox / fec / httools_static / lptools_static /
                                        magiskboot / magiskpolicy / snapshotupdater_static
                                        全部 ELF32 ARM
```

SM8750 的 **Oryon 核心是纯 64 位设计，不实现 AArch32**，因此该平台 Android 只有 `arm64-v8a`
（`abilist32` 为空），任何 32 位 ELF 都会以 `ENOEXEC` 失败。

`update-binary` 里：

```sh
setup_bb() {
  ...
  bb=$AKHOME/tools/busybox;
  chmod 755 $bb;
  $bb chmod -R 755 tools bin;   # 失败
  $bb --install -s bin;         # 失败 → setup_bb 返回非 0
}

setup_bb;
if [ $? != 0 -o -z "$(ls bin)" ]; then
  abort "Busybox setup failed. Aborting...";
fi;
```

**关键结论**：这与「用什么前端刷」无关 —— TWRP、KernelSU/SukiSU 管理器、Magisk 都调用同一份
`update-binary`，所以 32 位工具在任何前端下都会失败，**换个 App 不解决问题**。

**修复**：本项目在 `anykernel/tools/` 内置一整套 **AArch64** 工具（7 个二进制，全部实测可运行），
`package-anykernel.sh` 打包时覆盖上游那套，并断言每个都是 64 位 ELF（`7f 45 4c 46 02`）。
来源与许可证见 `anykernel/tools/NOTICE.md`。

**顺带发现**：设备实际报 `ro.product.device = OP615EL1`、`ro.product.vendor.device = OP6190L1`
（即 `erhai`，OnePlus Pad 2 Pro），而不是 LineageOS 代号。安装器白名单因此补上了
`OP615EL1`、`OP6190L1` 等 OPLUS OTA 名称。

---

## 10. 验证记录

所有验证都在**未编译内核**的前提下完成（`make -n` 只打印命令，不执行）。

| # | 检查 | 方法 | 结果 |
|---|---|---|---|
| 1 | 补丁对 5 个分支可用 | `patch -p1 --dry-run` | **5/5 干净**（23.2 上有 offset/fuzz，属正常） |
| 2 | 补丁真实应用 | `patch -p1` + `grep` | 落地，`ANDROID_KABI_USE(6, ...)` 命中 |
| 3 | 配置项存在于 Kconfig | `check-kconfig-symbols.sh` | **64/64**（期间发现并修正上游文档里 2 个 6.6 已不存在的名字） |
| 4 | 配置合并 | `merge_config.sh -m` | 1414 行合并片段 |
| 5 | 配置落地 | `make olddefconfig` | 8798 行、2698 个 `CONFIG_*` |
| 6 | Droidspaces 选项为 `=y` | `verify-config.sh` | **full 47/47，core 16/16** |
| 7 | `BRIDGE_NETFILTER` 未被误开 | `grep` | `# CONFIG_BRIDGE_NETFILTER is not set` |
| 8 | release 字符串逻辑 | `scripts/config` + `olddefconfig` | `CONFIG_LOCALVERSION="-4k-gedc821586bcb"` |
| 9 | 编译命令 | `make -n Image` | 1781 条命令；`--target=aarch64-linux-gnu`、`-Wno-error` ×142、`ld.lld` |
| 10 | AnyKernel3 打包 | 假 Image 跑 `package-anykernel.sh` | zip 内含 `Image` / `anykernel.sh` / `META-INF`，变量正确 |
| 11 | 脚本语法 | `bash -n scripts/*.sh` | 全部通过 |
| 12 | 工作流 YAML | `js-yaml` 解析 | 通过（build 19 步；validate 2 个 job） |
| 13 | 冒烟测试目标 | `make -n kernel/fork.o` 等 3 个 | 3/3 被识别，各 1 条编译命令 |
| 14 | GKI 模块保护 | 生成 `gki_module_{unprotected,protected_exports}.h` | 合法 C；未保护列表为空 → 宽松路径 |
| 15 | 冒烟 + 配置 CI 流程 | `build-kernel.sh` 的 `CONFIGURE_ONLY` / `SMOKE_ONLY` | 两种模式语法与目标均验证 |
| 16 | NTSYNC hook | `patch --dry-run drivers/misc/{Kconfig,Makefile}` | 干净应用 |
| 17 | NTSYNC 配置生效 | `CONFIGURE_ONLY=1 ENABLE_NTSYNC=1` | 校验 **48/48**，`.config` 中 `CONFIG_NTSYNC=y` |
| 18 | NTSYNC 可编译目标 | `make -n drivers/misc/ntsync.o` | 目标存在，1 条编译命令 |
| 19 | `enable-ntsync.sh` 幂等 | 连续两次 | 第二次跳过 hook，Kconfig/Makefile 各 1 处 |
| 20 | 打包注入安全 | 内核名用 `A&B\|C\D` | 原样注入，`unzip -t` 通过 |
| 21 | 安装器白名单可关闭 | `AK3_DEVICECHECK=0` | `anykernel.sh` 中 `do.devicecheck=0` |
| 22 | shell 反引号审计 | 全仓库扫描未转义的反引号 | 修复 1 处会触发命令替换的位置 |
| 23 | 符号检查性能 | 全树扫描次数 | **64 → 1 次**（20241 符号 / 1778 Kconfig，0.6s） |
| 24 | release 重复后缀复现 | 手动跑 `scripts/setlocalversion` | 设 `LOCALVERSION` 环境变量 → **逐字节复现**线上内核的重复后缀 |
| 25 | 修复后行为 | 同上三组场景 | 默认 `6.6.142-4k`（本机无 git）；覆盖时 `6.6.142-4k-gedc821586bcb`，均正确 |
| 26 | 产物就是真实 arm64 内核 | Image 偏移 56..59 魔数 | `41524d64` = `ARMd` ✅ |
| 27 | 平台 32 位能力 | `ro.product.cpu.abilist32` | **空** → 纯 64 位 |
| 28 | 上游 AK3 工具架构 | 7 个二进制的 ELF 头 | 全部 **ELF32/ARM** |
| 29 | 内置 AArch64 工具可用性 | 逐个在本机执行 | **7/7 通过**；`--install -s` 建出 358 个 applet |
| 30 | 修复后模拟安装 | 复刻 `setup_bb()` 三步 | 全部成功 → 不再触发 abort |

**未验证**：真实编译（需要 GitHub Actions 的 x86_64 环境，约 1 小时）与真机刷入。

# Droidspaces Kernel for OnePlus SM8750 ("sun")

给 **LineageOS/类 LineageOS (Android 15/16)** 的 **一加 SM8750 (Snapdragon 8 Elite)** 设备构建一个**完整支持 Droidspaces 容器**的内核，并用 **GitHub Actions** 编译、打包成 **AnyKernel3** 卡刷包。

> 本项目**只做增量**：不 fork 内核源码树，每次构建都从上游 `LineageOS/android_kernel_oneplus_sm8750` 取最新代码，只应用必要的 kABI 补丁 + 配置片段。
> **不需要在本地编译**，所有编译都在 GitHub Actions 上完成。

---

## 目录

- [它到底改了什么](#它到底改了什么)
- [支持范围](#支持范围)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [工作流参数](#工作流参数)
- [分支 / 内核版本对照](#分支--内核版本对照)
- [原理：为什么必须打 kABI 补丁](#原理为什么必须打-kabi-补丁)
- [为什么要匹配内核 release 字符串](#为什么要匹配内核-release-字符串)
- [在本地复现（可选）](#在本地复现可选)
- [常见问题](#常见问题)
- [参考](#参考)

---

## 它到底改了什么

只有两件事：

1. **一个补丁** —— `patches/001.droidspaces-sysvipc-kabi.patch`
   把 `struct task_struct` 里的 `sysvsem` / `sysvshm` 从原来的位置搬进 **未使用的 `ANDROID_KABI_RESERVE()` 保留槽位**，这样开启 `CONFIG_SYSVIPC` 后 `task_struct` 的**大小和后续所有字段偏移完全不变** → 厂商预编译模块（vendor_dlkm 里的 500+ 个 `.ko`）依旧能加载。

2. **三个配置片段** —— `configs/*.config`
   在 LineageOS 原本的配置（`gki_defconfig` + `vendor/sun_perf.config` + `vendor/oplus/sun_perf.config`）之上，打开 Droidspaces 需要的内核选项。

编译产物只有 **`Image`**，通过 AnyKernel3 替换 `boot` 分区里的内核，**不动 vendor_dlkm / system_dlkm / dtbo**。

---

## 支持范围

### `full` 档（默认，推荐）

| 能力 | 相关配置 |
|---|---|
| 容器基本运行（PID/UTS/IPC/NET/USER 命名空间） | `PID_NS` `UTS_NS` `IPC_NS` `NET_NS` `USER_NS` `NAMESPACES` |
| SysV IPC / POSIX 消息队列 | `SYSVIPC` `POSIX_MQUEUE`（**需要 kABI 补丁**） |
| cgroup 限制 | `CGROUPS` `CGROUP_DEVICE` `CGROUP_PIDS` `CGROUP_FREEZER` `CGROUP_NET_PRIO` `MEMCG` |
| `/dev` 与 devtmpfs 自动挂载 | `DEVTMPFS` `DEVTMPFS_MOUNT` |
| volatile 模式（OverlayFS） | `OVERLAY_FS` |
| seccomp 防护 | `SECCOMP` `SECCOMP_FILTER` |
| **NAT / none 网络隔离** | `VETH` `BRIDGE` `NF_NAT` `NF_NAT_REDIRECT` `NETFILTER_XT_MATCH_ADDRTYPE` `IP_NF_TARGET_MASQUERADE` … |
| 容器内使用 **Docker / Podman / LXC** | `NF_TABLES` |
| 容器内使用 **UFW / Fail2ban** | `IP_NF_TARGET_REJECT` `NETFILTER_XT_MATCH_RECENT` `IP_SET` `NETFILTER_XT_SET` … |
| **NixOS**（tmpfs ACL/xattr） | `TMPFS_POSIX_ACL` `TMPFS_XATTR` |

### `core` 档

只启用 [Droidspaces 官方 GKI 指南](docs/upstream-Droidspaces-Kernel-Configuration.md) 列出的最小集合。如果 `full` 档在你的机器上异常，可以先用 `core` 档定位问题。

### 不包含（有意为之）

- **NTSYNC**（Wine/Proton 的 Windows 同步原语）—— **已提供，但默认关闭**。它是官方要求清单之外的能力，需要引入约 1000 行新驱动源码；把工作流的 `ntsync` 输入设为 `true` 即可启用（见 [patches/optional/ntsync](patches/optional/ntsync/README.md)）。
- **Lindroid / EVDI 虚拟显示** —— 需要引入整个 `drivers/gpu/drm/evdi/` 目录，本项目**未包含**。若你需要把 Android 界面投到 Linux 容器里，可以再单独加。
- **内核本身的功能**（KernelSU / SUSFS / zram 算法 / BBR …）—— 本项目的目标只有一个：Droidspaces。这也正是它比动辄 3 万行补丁的“全能内核”项目更容易维护的原因。

---

## 仓库结构

```
.
├── .github/workflows/build.yml      # GitHub Actions 构建流程
├── .github/workflows/validate.yml   # 上游漂移检测（每周 + 手动）
├── anykernel/
│   ├── anykernel.sh                 # AnyKernel3 安装脚本模板（GKI v4 boot）
│   └── tools/                       # AArch64 版 AnyKernel3 工具（见其中 NOTICE.md）
│       #   ↑ 上游自带的 7 个工具都是 32 位 ARM，在 SM8750 上无法运行
├── configs/
│   ├── droidspaces-core.config      # 必选（官方 GKI 清单）
│   ├── droidspaces-containers.config# cgroup / devtmpfs / overlayfs / seccomp
│   ├── droidspaces-network.config   # NAT 模式 + UFW / Fail2ban + nftables
│   └── optional/
│       └── droidspaces-ntsync.config # 可选：只配 ntsync=true 时才使用
├── docs/
│   ├── FLASHING.md                  # 刷机与排错指南（先看这个）
│   ├── RESEARCH.md                  # 完整调研记录（配置/补丁/构建方式）
│   └── upstream-Droidspaces-Kernel-Configuration.md   # 上游官方文档存档
├── patches/
│   ├── 001.droidspaces-sysvipc-kabi.patch   # 唯一必打补丁
│   ├── alternatives/                # 其他内核版本 / 槽位变体备用
│   ├── optional/ntsync/             # 可选的 NTSYNC（Wine/Proton）补丁 + 源码
│   └── README.md                    # 为什么选这个变体
└── scripts/
    ├── install-clang.sh             # 下载 AOSP clang（多镜像 + 校验）
    ├── prepare-sources.sh           # 拉取 kernel + modules + devicetrees 三棵树
    ├── build-kernel.sh              # 合并配置 → olddefconfig → 编译 Image
    ├── verify-config.sh             # 编译前校验配置（秒级失败）
    ├── check-kconfig-symbols.sh     # 校验每个配置项在 Kconfig 中真实存在
    ├── enable-ntsync.sh             # 可选：把 NTSYNC 驱动装进内核树
    └── package-anykernel.sh         # 打成 AnyKernel3 zip
```

---

## 已验证的内容（构建前）

下面这些检查都在**没有编译内核**的前提下完成，目的是让首次 Actions 运行尽量一次通过：

| 检查 | 方法 | 结果 |
|---|---|---|
| kABI 补丁可用 | `patch -p1 --dry-run`，分别对 lineage-22.2 / 23.0 / 23.1 / 23.2 / 24.0 | **5/5 干净应用** |
| 补丁真的落地 | 实际应用后 grep `ANDROID_KABI_USE(6, ...)` | 命中 |
| 配置项真实存在 | `scripts/check-kconfig-symbols.sh` 扫描整棵树的 Kconfig | **64/64** |
| 配置能合并并落地 | `merge_config.sh` + `make olddefconfig` | `.config` 含 2698 个配置项 |
| Droidspaces 选项最终为 `=y` | `scripts/verify-config.sh` | **full 47/47，core 16/16** |
| 编译命令正确 | `make -n Image`（只打印不执行） | `--target=aarch64-linux-gnu`、`-Wno-error`、`ld.lld` 全部正确 |
| AnyKernel3 打包 | 用假 Image 跑 `package-anykernel.sh` | zip 结构 / `kernel.string` 注入 / slot 变量正确 |
| 冒烟测试目标有效 | `make -n kernel/fork.o` 等 3 个目标 | 3/3 被识别，各产生 1 条编译命令 |
| 厂商模块不会被拒载 | `abi_gki_kmi_symbols` 生成路径分析 | 裸 `make` 下为空 → 走**宽松**路径，模块可访问全部符号 |
| NTSYNC hook 可应用 | `patch --dry-run` 打 `drivers/misc/{Kconfig,Makefile}` | 干净应用 |
| NTSYNC 配置生效 | `CONFIGURE_ONLY=1 ENABLE_NTSYNC=1` | 校验 48/48 通过，`.config` 中 `CONFIG_NTSYNC=y` |
| NTSYNC 目标可编译 | `make -n drivers/misc/ntsync.o` | 目标存在，1 条编译命令 |
| `enable-ntsync.sh` 幂等 | 连续执行两次 | 第二次跳过 hook，符号不重复 |
| 打包注入安全 | 用 `A&B\|C\D` 作为内核名打包 | 原样注入，无 sed 语法破坏 |
| `AK3_DEVICECHECK=0` | 打包后检查 `anykernel.sh` | `do.devicecheck=0`，zip 完整性 OK |
| shell 反引号审计 | 扫描全部脚本与工作流 | 修掉 1 处会触发命令替换的反引号 |
| 符号检查性能 | 全树扫描次数 | 从 64 次降到 **1 次**（20241 个符号 / 1778 个 Kconfig） |
| 平台是纯 64 位 | 设备上读 `ro.product.cpu.abilist32` | **空**（Oryon 核心无 AArch32） |
| 上游 AK3 工具架构 | 读 7 个二进制的 ELF 头 | **全部 ELF32/ARM** → 必然 `Exec format error` |
| 内置的 AArch64 工具 | 逐个在 SM8750 上运行 | **7/7 可运行**；模拟 `setup_bb()` 三步全过 |

> ⚠️ **尚未验证**：真正的编译和刷机。这两步必须在 GitHub Actions 和真机上完成。

### 构建流水线的“快失败”设计

一次完整构建要 40~90 分钟，所以流程被刻意排成**先便宜后昂贵**：

1. 拉源码 → 打补丁（`--dry-run` 先跑一遍）
2. **配置合并 + `olddefconfig` + 校验**（用 `out-validate` 临时目录，约 5 分钟）
3. 下载 AOSP clang（约 1 GB）
4. **冒烟测试**：只编译 3 个代表性目标文件（约 5 分钟）
   - `kernel/fork.o`（用到 `struct task_struct`，覆盖 kABI 改动）
   - `net/netfilter/nf_tables_api.o`（本项目新启用的 `CONFIG_NF_TABLES`）
   - `net/netfilter/ipset/ip_set_core.o`（本项目新启用的 `CONFIG_IP_SET`）
5. 完整编译 `Image`
6. AnyKernel3 打包 + 上传

任何一步失败都会停在原地，而不是让你等一小时才看到配置写错了。

---

## 快速开始

### 1. 建仓库

把本项目推到你的 GitHub 仓库（公开/私有都可以）：

```bash
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### 2. 打开 Actions

`Settings → Actions → General → Workflow permissions` 选择 **Read and write**（tag 构建时创建 Release 需要）。

### 3. 运行工作流

`Actions → Build Droidspaces Kernel (OnePlus SM8750) → Run workflow`

一般**保持默认**即可：

- `kernel_branch` = `lineage-23.2`（与你 ROM 对应的分支）
- `profile` = `full`
- `localversion` = 留空（自动使用分支 commit，如 `-4k-gedc821586bcb`）
- `clang_version` = `clang-r510928`（与内核树 `build.config.constants` 一致）

**运行前请先在你的手机上执行 `uname -r`**，确认：

```
6.6.142-4k-gedc821586bcb
        └──┬──┘ └────┬────┘
       LOCALVERSION  分支 commit（12 位）
```

如果最后那段 12 位 commit 和你 ROM 的不一样，把它填进 `localversion`（写成 `-4k-g<你的12位commit>`）。

### 4. 下载并刷入

构建完成后有**两条下载路径**，别下错：

| 路径 | 拿到的是什么 | 能不能直接刷 |
|---|---|---|
| **Releases → `latest`**（推荐） | **原始卡刷包** `Droidspaces-SM8750-lineage-23.2-full.zip` | ✅ 直接刷，且支持断点续传 |
| **Artifacts** | `Droidspaces-SM8750-lineage-23.2-full-artifact.zip` —— **外层容器** | ❌ 必须先解一层，里面那个同名 `.zip` 才是卡刷包 |

> GitHub 的 **Artifacts 一定是嵌套的** —— `upload-artifact` 没有「不打包」的选项，
> 平台会自动再压一层。所以推荐用 **Releases**：release asset 是原始文件，不多套壳。

拿到卡刷包后，在 **KernelSU / Magisk 管理器**或 **TWRP/OrangeFox** 里刷入，然后重启。

刷之前建议先校验（手机上用 Termux 就行）：

```bash
cd /sdcard/Download          # 或你放 zip 的目录
# 1) 校验整包是不是下载完整
sha256sum -c Droidspaces-SM8750-lineage-23.2-full.zip.sha256
# 2) 校验 zip 内部有没有损坏
unzip -t Droidspaces-SM8750-lineage-23.2-full.zip
```

详细步骤和排错见 **[docs/FLASHING.md](docs/FLASHING.md)**。

---

## 工作流参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `kernel_branch` | `lineage-23.2` | 上游内核分支，决定内核版本（6.6.x） |
| `profile` | `full` | `full` = 完整支持；`core` = 仅官方 GKI 最小集 |
| `localversion` | 自动 | 内核 release 后缀。**留空即可** —— 让内核自己从 git 取 `-4k-g<commit>`；只有需要强制指定时才填 |
| `kernel_name` | Droidspaces Kernel (SM8750 / sun) | 安装器里显示的名字 |
| `clang_version` | `clang-r510928` | AOSP clang 版本 |
| `upload_config` | `true` | 是否额外上传 `Image` 与 `.config` 便于排查 |
| `use_ccache` | `true` | 用 ccache 缓存目标文件，重复构建会快很多（首次构建基本无收益） |
| `ntsync` | `false` | **可选**：加入 NTSYNC（跑 Wine / Proton 才需要），详见 [patches/optional/ntsync](patches/optional/ntsync/README.md) |
| `device_check` | `true` | 安装器机型白名单；代号不在 `dodge/erhai/hummer/ktm` 时设为 `false` |

仓库变量（可选，`Settings → Secrets and variables → Actions → Variables`）：

| 变量 | 用途 |
|---|---|
| `CLANG_URL` | 自定义 clang 压缩包直链（`.zip`/`.tar.gz`），优先级最高 |
| `REPO_BASE` | 源码镜像前缀，例如 `https://gh-proxy.com/https://github.com`（默认 `https://github.com`） |

---

## 分支 / 内核版本对照

| 分支 | LineageOS / Android | 内核 |
|---|---|---|
| `lineage-24.0` | LOS 24.0 / Android 17 | 6.6.142 |
| `lineage-23.2` | LOS 23.2 / Android 16 QPR2 | **6.6.142**（默认） |
| `lineage-23.1` | LOS 23.1 / Android 16 QPR1 | 6.6.126 |
| `lineage-23.0` | LOS 23.0 / Android 16 | 6.6.126 |
| `lineage-22.2` | LOS 22.2 / Android 15 | 6.6.104 |

同一分支覆盖的设备（都使用这套 kernel/modules/devicetrees）：

| 代号 | 机型 |
|---|---|
| `dodge` | OnePlus 13 |
| `erhai` | OnePlus Pad 2 Pro (13.2") |
| `hummer` | 未确认的 SM8750 一加设备 |
| `ktm` | OnePlus Ace 6 (PLQ110) |

> ⚠️ 只针对 **LineageOS 系 ROM**。ColorOS / OxygenOS 的 vendor 集成不同，**不要刷**。

---

## 原理：为什么必须打 kABI 补丁

GKI 内核和厂商预编译模块之间有一个**冻结的 ABI**（kABI）。`CONFIG_SYSVIPC` 会在 `struct task_struct` 中间插入两个字段：

```c
#ifdef CONFIG_SYSVIPC
    struct sysv_sem  sysvsem;   /* +8 字节 */
    struct sysv_shm  sysvshm;   /* +16 字节 */
#endif
```

这会让后面**所有字段偏移 +24 字节**，厂商模块按旧偏移读写内存 → 崩溃 / bootloop。

本项目的补丁把它们改成放在 `task_struct` 尾部预留的 `ANDROID_KABI_RESERVE(6/7/8)` 槽位里：

```c
ANDROID_KABI_USE(1, struct task_dma_buf_info *dmabuf_info);
ANDROID_KABI_USE(2, struct { unsigned user_dumpable:1; });
ANDROID_KABI_RESERVE(3);
ANDROID_KABI_RESERVE(4);
ANDROID_KABI_RESERVE(5);

#ifdef CONFIG_SYSVIPC
    ANDROID_KABI_USE(6, struct sysv_sem sysvsem);
    _ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);
#else
    ANDROID_KABI_RESERVE(6);
    ANDROID_KABI_RESERVE(7);
    ANDROID_KABI_RESERVE(8);
#endif
```

这些槽位本来就是**占位填充**，所以整体布局 **零变化**，厂商模块继续能用。

> 本项目选择的 `6_7_8` 变体是针对这棵树的：`task_struct` 里槽位 **1、2 已被 `ANDROID_KABI_USE` 占用**，只剩 3–8 可用。
> 另外两个变体（`1_2_3` / `3_4_5`）在这棵树上会打不上，已放在 `patches/alternatives/` 供其他内核使用。

---

## 为什么要匹配内核 release 字符串

Android 通过 vermagic（包含 `uname -r` 完整字符串）检查模块。如果新内核的 release 变成
`6.6.142-4k-g**deadbeef**` 而 ROM 的模块是给 `6.6.142-4k-g**edc821586bcb**` 编译的，模块可能**拒绝加载** → 没 WiFi、没触摸、摄像头失效。

所以 `build-kernel.sh` 会：

1. 读取你所选分支的 HEAD commit（`git rev-parse HEAD`，取前 12 位）
2. 设置 `CONFIG_LOCALVERSION="-4k-g<commit>"`，并关闭 `CONFIG_LOCALVERSION_AUTO`

这样生成的内核 release 与上游 ROM 的**完全一致**。

---

## 在本地复现（可选）

本项目要求“不本地编译”也能用，但脚本是纯 bash，可以在任何 x86_64 Linux 上复现：

```bash
export REPO_BASE=https://github.com          # 国内可换成 gh-proxy 前缀
export KERNEL_BRANCH=lineage-23.2
export WORK_DIR=$PWD/work

./scripts/install-clang.sh
./scripts/prepare-sources.sh
( cd work/src && patch -p1 < ../../patches/001.droidspaces-sysvipc-kabi.patch )

export KERNEL_DIR=$PWD/work/src OUT_DIR=$PWD/out PROFILE=full
export LOCALVERSION="-4k-g$(git -C work/src rev-parse HEAD | cut -c1-12)"
./scripts/build-kernel.sh
./scripts/package-anykernel.sh out/arch/arm64/boot/Image dist/kernel.zip
```

---

## 常见问题

<details>
<summary><b>构建失败在 <code>drivers/base/kernelFwUpdate/Kconfig: No such file or directory</code></b></summary>

内核树里有大量指向**兄弟目录**的相对软链接（`sm8750-modules`、`sm8750-devicetrees`）。`scripts/prepare-sources.sh` 会把三棵树按正确布局放好：

```
work/src                ← 内核
work/sm8750-modules     ← 兄弟目录，软链接指向它
work/sm8750-devicetrees ← 兄弟目录
```

如果你手动操作，请保持这个目录名不变。
</details>

<details>
<summary><b>刷入后没 WiFi / 摄像头 / 触摸</b></summary>

release 字符串不匹配，厂商模块没加载。对照你的 `uname -r`，用 `localversion` 参数手动指定。
</details>

<details>
<summary><b>开机卡在 logo / bootloop</b></summary>

先刷回你自己的 `boot.img` 备份（**刷之前一定要备份！**）。然后用 `profile = core` 重新构建再试。
</details>

<details>
<summary><b>Droidspaces 提示缺 PID/MNT/UTS/IPC namespace 或 devtmpfs</b></summary>

说明配置没生效。下载构建时附带的 `kernel-image-and-config` artifact，检查里面的 `.config`。
</details>

---

## 参考

- [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — Droidspaces 本体与官方内核配置文档
- [LineageOS/android_kernel_oneplus_sm8750](https://github.com/LineageOS/android_kernel_oneplus_sm8750) — 内核源码
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) — 卡刷打包工具
- [Draklyfg/oneplus-sm8750-kernel-pro-build](https://github.com/Draklyfg/oneplus-sm8750-kernel-pro-build) — 同平台（LineageOS 23.2 / SM8750）的实战参考
- [cctv18/oppo_oplus_realme_sm8750](https://github.com/cctv18/oppo_oplus_realme_sm8750) — GKI 构建与工具链参考

## 许可

脚本与配置：GPL-2.0（与 Linux 内核一致）。补丁来自上游 Droidspaces 项目，版权归原作者。

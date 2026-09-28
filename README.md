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

- **Lindroid / EVDI 虚拟显示**、**NTSYNC**（Wine/Proton 同步原语）—— 属于 Droidspaces 的“扩展”能力，需要额外源码，本项目默认不引入。见 `docs/RESEARCH.md` 中的说明。
- **内核本身的功能**（KernelSU / SUSFS / zram 算法 / BBR …）—— 本项目的目标只有一个：Droidspaces。这也正是它比动辄 3 万行补丁的“全能内核”项目更容易维护的原因。

---

## 仓库结构

```
.
├── .github/workflows/build.yml      # GitHub Actions 构建流程
├── anykernel/anykernel.sh           # AnyKernel3 安装脚本模板（GKI v4 boot）
├── configs/
│   ├── droidspaces-core.config      # 必选（官方 GKI 清单）
│   ├── droidspaces-containers.config# cgroup / devtmpfs / overlayfs / seccomp
│   └── droidspaces-network.config   # NAT 模式 + UFW / Fail2ban + nftables
├── docs/
│   ├── FLASHING.md                  # 刷机与排错指南（先看这个）
│   ├── RESEARCH.md                  # 完整调研记录（配置/补丁/构建方式）
│   └── upstream-Droidspaces-Kernel-Configuration.md   # 上游官方文档存档
├── patches/
│   ├── 001.droidspaces-sysvipc-kabi.patch   # 唯一必打补丁
│   ├── alternatives/                # 其他内核版本 / 槽位变体备用
│   └── README.md                    # 为什么选这个变体
└── scripts/
    ├── install-clang.sh             # 下载 AOSP clang（多镜像 + 校验）
    ├── prepare-sources.sh           # 拉取 kernel + modules + devicetrees 三棵树
    ├── build-kernel.sh              # 合并配置 → olddefconfig → 编译 Image
    ├── verify-config.sh             # 编译前校验配置（秒级失败）
    └── package-anykernel.sh         # 打成 AnyKernel3 zip
```

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

构建完成后在 Artifacts 里下载 `Droidspaces-SM8750-lineage-23.2-full.zip`，
在 **KernelSU / Magisk 管理器**或 **TWRP/OrangeFox** 里刷入，然后重启。

详细步骤和排错见 **[docs/FLASHING.md](docs/FLASHING.md)**。

---

## 工作流参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `kernel_branch` | `lineage-23.2` | 上游内核分支，决定内核版本（6.6.x） |
| `profile` | `full` | `full` = 完整支持；`core` = 仅官方 GKI 最小集 |
| `localversion` | 自动 | 内核 release 后缀；必须与 ROM 一致，否则厂商模块不加载 |
| `kernel_name` | Droidspaces Kernel (SM8750 / sun) | 安装器里显示的名字 |
| `clang_version` | `clang-r510928` | AOSP clang 版本 |
| `upload_config` | `true` | 是否额外上传 `Image` 与 `.config` 便于排查 |

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

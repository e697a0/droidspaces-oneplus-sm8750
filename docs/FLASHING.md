# 刷机与排错指南

> 本内核**只替换 `boot` 分区里的内核 Image**，不动 `vendor_dlkm` / `system_dlkm` / `dtbo` / `init_boot`。
> 用 AnyKernel3 打包，安装时会**读取你机器上现有的 boot 分区**、把内核换掉再写回去，所以不会破坏你的 ramdisk / cmdline / AVB 配置。

---

## 0. 先备份（最重要）

刷之前，把当前的 boot 分区导出：

```bash
su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot-backup.img'
```

或者直接从你正在用的 ROM 的 `payload.bin` 里提取 `boot.img`。

> 备份是你唯一的后悔药。**没有备份就不要刷。**

---

## 1. 确认 ROM 与内核版本

```bash
uname -r
# 例如：6.6.142-4k-gedc821586bcb
```

- `6.6.142` → 对应 `lineage-23.2` / `lineage-24.0` 分支
- `-4k` → 内核树自带的 `CONFIG_LOCALVERSION`
- `gedc821586bcb` → 上游 commit

**如果这段 commit 与你的构建产物不一致，请在运行工作流时用 `localversion` 参数指定成你的值**，
否则 ROM 里预编译的 500+ 个厂商模块可能无法加载（表现：无 WiFi / 无触摸 / 摄像头失效）。

---

## 2. 刷入

三种方式任选：

### A. KernelSU / APatch / Magisk 管理器（推荐）

KernelSU 管理器支持直接刷 AnyKernel3 zip：
```
KernelSU → 工具箱/安装 → 选择 "Droidspaces-SM8750-....zip" → 安装
```

### B. Recovery（TWRP / OrangeFox / AOSP Recovery）

```
adb push Droidspaces-SM8750-....zip /sdcard/
# recovery 里：Install → 选择 zip → 滑动刷入
```

### C. fastboot（仅在你另外生成了 boot.img 时）

```bash
fastboot flash boot boot.img
```

> ⚠️ 这些设备是 **A/B 分区**，AnyKernel3 会自动识别当前 slot。不要手动 `fastboot flash boot_a` 去猜。

> ⚠️ 安装器带**机型白名单**（`dodge` / `erhai` / `hummer` / `ktm`）。如果安装时提示机型不匹配，说明你的设备代号不在列表里 ——
> 把工作流的 **`device_check` 设为 `false`** 重新构建，或直接在 `anykernel/anykernel.sh` 里补一行 `device.name5=<你的代号>`。
> 请不要在非 SM8750 机型上强行安装。

刷完后**重启**。

---

## 3. 验证

```bash
# 1) 版本号应该和你设置的一致
uname -r

# 2) Droidspaces 自检
su -c droidspaces check
```

也可以打开 Droidspaces App → **Settings（齿轮）→ Requirements → Check Requirements**。

应该全部是 ✅（黄色 ⚠️ 表示可选项缺失）：

| 检查项 | 需要的配置 |
|---|---|
| PID namespace | `CONFIG_PID_NS=y` |
| MNT namespace | `CONFIG_NAMESPACES=y` |
| UTS namespace | `CONFIG_UTS_NS=y` |
| IPC namespace | `CONFIG_IPC_NS=y` |
| Cgroup device | `CONFIG_CGROUP_DEVICE=y` |
| devtmpfs | `CONFIG_DEVTMPFS=y` |
| OverlayFS | `CONFIG_OVERLAY_FS=y` |
| Network namespace | `CONFIG_NET_NS=y` |
| VETH / Bridge | `CONFIG_VETH=y` / `CONFIG_BRIDGE=y` |
| Seccomp | `CONFIG_SECCOMP=y` |

---

## 4. 排错

### 4.1 卡 logo / bootloop

1. 进 fastboot / recovery，把第 0 步的 `boot-backup.img` 刷回去：
   ```bash
   fastboot flash boot boot-backup.img
   ```
2. 重新构建时把 `profile` 改成 **`core`**，只启用官方最小集合。
3. 如果 `core` 能开机、`full` 不能，把结果反馈给我 —— 大概率是 `CONFIG_CGROUP_DEVICE` /
   `CONFIG_NF_TABLES` 这类扩展项与厂商模块冲突。

### 4.2 开机了但没有 WiFi / 触摸 / 摄像头

**release 字符串不匹配**导致 `vendor_dlkm` 的模块没加载。检查：

```bash
# 对比内核 release
uname -r
# 看 vendor 模块期望的版本
modinfo /vendor/lib/modules/wlan.ko 2>/dev/null | grep vermagic
# 或
dmesg | grep -i "version magic"
```

解决：用 `localversion` 参数填上正确的后缀（例如 `-4k-gedc821586bcb`）重新构建。

### 4.3 模块加载报 "disagrees about version of symbol"

kABI 补丁没生效（或者被别的东西覆盖了）。检查构建日志里这一段：

```
[+] kABI patch applied and verified
```

并且确认 `work/src/include/linux/sched.h` 里有：

```c
ANDROID_KABI_USE(6, struct sysv_sem sysvsem);
```

### 4.4 Droidspaces 自检说缺 namespace / devtmpfs

配置没合进去。下载构建产物里的 `kernel-image-and-config` artifact，检查 `.config`：

```bash
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|UTS_NS|NET_NS|USER_NS|DEVTMPFS)=' .config
```

### 4.5 容器能起但没网（NAT 模式）

需要 `full` 档。检查：
```bash
su -c 'ls /proc/sys/net/ipv4/ip_forward'
su -c 'iptables -t nat -L -n | head'
```

---

## 5. 卸载 / 回退

直接刷回备份的 boot 分区即可，本项目没有改动任何其他分区：

```bash
fastboot flash boot boot-backup.img
```

---

## 6. 关于 Magisk / 内核级 Root

本项目生成的 AnyKernel3 包设置了 `NO_MAGISK_CHECK=1`，即**不做 Magisk 重补丁**：

- 如果你用的是 **KernelSU / SukiSU / APatch**（LKM 或 GKI 方式），无影响。
- 如果你把 **Magisk 集成在 boot 分区**里，刷完本内核后需要**再刷一次 Magisk**。
- 之所以这样设置，是因为本内核只提供干净的 `Image`，与同平台已验证项目的做法一致。

如果你更希望 AnyKernel3 自动保留 Magisk，请在 `anykernel/anykernel.sh` 里删掉
`NO_MAGISK_CHECK=1` 这一行再构建。


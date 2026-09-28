# patches/optional/ntsync/

**可选**功能，默认关闭。用于在 Droidspaces 容器里跑 Windows 程序（Wine / Proton / Steam）。
Droidspaces 官方的内核要求清单里**没有**这一项 —— 它属于「扩展」能力。

## 内容

| 文件 | 说明 |
|---|---|
| `0001-ntsync-hooks.patch` | 向 `drivers/misc/Kconfig` 加入 `CONFIG_NTSYNC`，向 `drivers/misc/Makefile` 加入 `obj-$(CONFIG_NTSYNC) += ntsync.o` |
| `files/drivers/misc/ntsync.c` | NTSYNC 驱动本体（约 1000 行，含 5.12 / 6.3 的版本兼容分支） |
| `files/include/uapi/linux/ntsync.h` | 对应的 uapi 头文件 |

## 来源

- 上游：Linux 主线 `drivers/misc/ntsync.c`（作者 Elizabeth Figura，GPL-2.0-only）
- 这份做了 6.6 兼容适配的版本取自同平台参考项目
  [Draklyfg/oneplus-sm8750-kernel-pro-build](https://github.com/Draklyfg/oneplus-sm8750-kernel-pro-build)
  的 `patches/extra/drivers/misc/ntsync.c`，该项目在同一棵 LineageOS 23.2 / SM8750 树上
  以 `CONFIG_NTSYNC=y` 构建并实机验证过。

## 怎么启用

工作流里把 **`ntsync`** 输入设为 `true` 即可；本地则：

```bash
./scripts/enable-ntsync.sh work/src
ENABLE_NTSYNC=1 KERNEL_DIR=work/src ./scripts/build-kernel.sh
```

启用后会：
1. 把上面两个文件复制进内核树；
2. 应用 `0001-ntsync-hooks.patch`；
3. 追加 `configs/optional/droidspaces-ntsync.config`（`CONFIG_NTSYNC=y`）；
4. 把 `drivers/misc/ntsync.o` 加入 CI 冒烟测试的编译目标 —— 所以即使它编译不过，
   也只会浪费几分钟而不是一小时。

## 注意

- 必须 `=y`（内建）而不是 `=m`：本项目只刷 `boot` 分区的内核 Image，不改 `vendor_dlkm`，
  所以模块形式的新驱动根本不会被加载。
- `CONFIG_NTSYNC` 是新增的 Kconfig 符号，**必须先应用 hooks 补丁**，否则
  `merge_config.sh` 会静默丢弃这一行（`check-kconfig-symbols.sh` 会因此报错）。

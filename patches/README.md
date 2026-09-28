# patches/

## `001.droidspaces-sysvipc-kabi.patch` —— **唯一必打补丁**

作用：把 `struct task_struct` 里的 `sysvsem` / `sysvshm` 搬进尾部未使用的
`ANDROID_KABI_RESERVE(6/7/8)` 槽位，使 `CONFIG_SYSVIPC=y` 不再改变任何结构偏移。

来源：`ravindu644/Droidspaces-OSS` → `Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch`

适用：**本仓库目标树**（`LineageOS/android_kernel_oneplus_sm8750`，6.6.x，GKI）

实测（`lineage-23.2`）：

```
$ patch -p1 --dry-run < patches/001.droidspaces-sysvipc-kabi.patch
checking file include/linux/sched.h
Hunk #1 succeeded at 1076 (offset 2 lines).
Hunk #2 succeeded at 1530 with fuzz 2 (offset 17 lines).
```

---

## `alternatives/` —— 备用变体

上游为不同内核版本 / 不同 kABI 槽位占用情况提供了三个变体。它们的区别**只是把字段放进哪组保留槽位**。

| 文件 | 适用场景 | 能否用于本树 |
|---|---|---|
| `001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch` | 槽位 6/7/8 空闲 | ✅ **本项目的选择**（1、2 已被占用） |
| `001.GKI-below-6.12-fix_sysvipc_kabi_3_4_5.patch` | 槽位 3/4/5 空闲 | ❌ 上下文要求 `RESERVE(1)`、`(2)`，本树是 `KABI_USE` |
| `001.GKI-below-6.12-fix_sysvipc_kabi_1_2_3.patch` | 槽位 1/2/3 空闲 | ❌ 同上 |
| `001.GKI-6.12-or-above-fix_sysvipc_kabi.patch` | 6.12+ 内核 | ❌ 行号/上下文不同 |
| `002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch` | 5.10 及以下还需要额外补 `POSIX_MQUEUE` | ❌ 6.6 不需要 |

### 什么时候该换变体？

只看一件事：目标内核的 `include/linux/sched.h` 里 `struct task_struct` 尾部
**哪几个 `ANDROID_KABI_RESERVE(n)` 还是 `RESERVE` 状态**。

```bash
grep -n "ANDROID_KABI_USE(\|ANDROID_KABI_RESERVE(" include/linux/sched.h | tail -20
```

选一个“上下文里出现的槽位全是 `RESERVE`”的变体即可。三个变体都用 `patch -p1 --dry-run`
试一遍，能干净应用的那个就是对的。

> `patch` 允许行号偏移（`offset`）和小范围模糊匹配（`fuzz`），所以行号变了通常没事；
> 但 **上下文内容**（是 `RESERVE(1)` 还是 `KABI_USE(1, ...)`）必须匹配。

# 小米 Redmi K20 Pro / Mi 9T Pro (raphael) 自定义 4.14 内核

面向小米 Redmi K20 Pro / Mi 9T Pro（代号 `raphael` / `raphaelin`）的自定义
Linux 4.14 内核，基于 PixelExperience 13 内核源码，同一份内核树可集成三种 root 方案：

| 变体 | Root 方案 | 挂钩模式 |
|---|---|---|
| `ksunext` | [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | manual hook |
| `resukisu` | [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) | manual hook |
| `resukisu-susfs` | ReSukiSU + [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) v2.2.0 | SUSFS inline hook |

目标系统：Android 13（PE 13，`TQ3A.230901.001.B1`）。

## 为什么会有这个仓库

KernelSU-Next 与 ReSukiSU 官方自带的 `kernel/setup.sh` 集成路径在本设备上都不可用：
它们假定内核具备可用的 kprobe 支持（或为 GKI 内核），而本设备的 4.14 SM8150
代码树**并未**启用 `CONFIG_KPROBES`。因此两者都必须通过 **manual hook**（SUSFS
则是 inline hook）模式接入：在系统调用路径中显式插入 `ksu_handle_*()` 调用。
本仓库正是为了保存这些补丁以及一套可复现的 CI 流水线。

## 目录结构

```
.
├── .github/workflows/build.yml            # CI：构建全部变体 + AnyKernel3 刷机包
├── patches/
│   ├── common/                            # 所有变体共用
│   │   ├── 0001-gsi-genksyms-workaround.patch
│   │   └── 0002-nongki-backports.patch
│   ├── ksunext/0001-manual-hooks.patch
│   ├── resukisu/0001-manual-hooks.patch
│   └── susfs/0001-susfs-inline-hooks.patch
├── anykernel/anykernel.sh                 # 模板；CI 按变体替换 @KSU_NAME@
├── scripts/setup-toolchain.sh             # 获取与 PE 匹配的工具链
└── README.md
```

## 构建

### 本地构建

```bash
VARIANT=ksunext        # 或：resukisu | resukisu-susfs

# 1. 内核源码（必须是 thirteen 分支）
git clone --depth 1 -b thirteen \
  https://github.com/PixelExperience-Devices/kernel_xiaomi_raphael.git kernel

# 2. Root 方案（KernelSU-Next 非 GKI 内核必须用 legacy 分支）
case "$VARIANT" in
  ksunext)   git clone -b legacy https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next ;;
  resukisu*) git clone -b main   https://github.com/ReSukiSU/ReSukiSU.git ReSukiSU ;;
esac

# 3. 应用补丁：先 common/，再对应变体的钩子补丁
cd kernel
for p in ../patches/common/*.patch; do git apply "$p"; done
case "$VARIANT" in
  ksunext)         git apply ../patches/ksunext/0001-manual-hooks.patch ;;
  resukisu)        git apply ../patches/resukisu/0001-manual-hooks.patch ;;
  resukisu-susfs)  git apply ../patches/susfs/0001-susfs-inline-hooks.patch ;;
esac
case "$VARIANT" in
  ksunext)   ln -sfn ../../KernelSU-Next/kernel drivers/kernelsu ;;
  resukisu*) ln -sfn ../../ReSukiSU/kernel      drivers/kernelsu ;;
esac
cd ..

# 4. 获取工具链
./scripts/setup-toolchain.sh "$PWD/toolchain"

# 5. 构建
cd kernel
export PATH="$PWD/../toolchain/clang-r416183b/bin:$PWD/../toolchain/gnu/bin:$PATH"
MAKE_ARGS=(O=out ARCH=arm64 CC=clang LD=aarch64-linux-gnu-ld \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)
make "${MAKE_ARGS[@]}" raphael_defconfig
make "${MAKE_ARGS[@]}" -j"$(nproc)"
make "${MAKE_ARGS[@]}" Image.gz-dtb dtbo.img
```

产物：`out/arch/arm64/boot/Image.gz-dtb`（内核 + 追加的 DTB）以及
`out/arch/arm64/boot/dtbo.img`。

### 通过 GitHub Actions 构建

手动触发 **Build Kernel** 工作流并选择变体。它会获取工具链、应用补丁、执行构建，
随后将结果打包为 AnyKernel3 可刷写 zip 并作为构建产物上传。

| 触发方式 | 行为 |
|---|---|
| `workflow_dispatch` | 只构建所选的 `su` 变体 |
| `push`（到 `main`） | 构建**全部三个**变体，`fail-fast: false` |
| `schedule`（每周） | 构建全部三个变体，并抓取上游新提交 |

手动触发的输入项：

| 输入 | 含义 |
|---|---|
| `su` | `ksunext` / `resukisu` / `resukisu-susfs` |
| `su_ref` | 覆盖上游 ref（默认按变体取 `legacy` 或 `main`） |
| `kernel_branch` | 内核源码分支（默认 `thirteen`） |
| `release` | 发布 GitHub Release |
| `send_tg` | 将 zip 上传到 Telegram 频道 |
| `tg_caption` | Telegram 附言的补充行 |

## 刷入

1. 启动第三方 recovery（PE recovery / TWRP）。
2. 刷入 zip（`KernelSU-Next-raphael-*.zip` 或 `ReSukiSU[-SUSFS]-raphael-*.zip`）。
   安装脚本会将新内核拼接进现有的 `boot` 分区，且不改动 ramdisk。
3. 重启，然后安装与之匹配的 Manager APK。

**回滚：** 从 ROM 的 zip 中重新刷入原厂 `boot.img`（若曾改动过 `dtbo.img`
也一并刷回）。

## CI 缓存

两级缓存让重复构建变得廉价：

| 缓存 | Key | 说明 |
|---|---|---|
| `toolchain`（约 1.6 GB） | `hashFiles('scripts/setup-toolchain.sh')` | 仅当获取脚本变更时才重新下载 |
| `ccache`（每变体 ≤1.5 GB） | `变体` + 内核 commit + KSU commit | `CC="ccache clang"`；`restore-keys` 逐级放宽，最后一档为裸 `ccache-`，使冷启动的变体也能从其它变体继承 |

`CCACHE_COMPILERCHECK` 被固定为一个常量字符串，而非对 `clang` 取哈希，因此
稳定的工具链不会导致缓存失效。

在 GitHub 托管 runner 上的实测：三个变体冷启动约 23 分钟；命中 ccache 后约 6 分钟。

## Telegram 发布

在 *Settings → Secrets and variables → Actions* 中配置两个仓库密钥：

| 密钥 | 取值 |
|---|---|
| `TG_BOT_TOKEN` | 来自 [@BotFather](https://t.me/BotFather) 的 token |
| `TG_CHAT_ID` | 频道 ID，如 `-100xxxxxxxxxx`（需把 bot 拉进频道并授予发帖权限） |

之后在手动触发时勾选 `send_tg`，或让每周定时任务自动推送。若密钥缺失，该步骤会打
warning 并**跳过**，而不会让构建失败。上传使用原生 Bot API（`sendDocument`），
无需额外 runner 依赖。

## 各变体集成细节

### 钩子调用点

每个变体都由内核自身将系统调用派发进入 root 方案。

`ksunext` —— 七个调用点：

| 文件 | 函数 | 调用 |
|---|---|---|
| `fs/exec.c` | `do_execveat_common` | `ksu_handle_execveat` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat` |
| `fs/stat.c` | `vfs_statx` | `ksu_handle_stat` |
| `fs/read_write.c` | `SYSCALL_DEFINE3(read)` | `ksu_handle_sys_read` |
| `kernel/sys.c` | `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)` | `ksu_handle_sys_reboot` |
| `drivers/input/input.c` | `input_handle_event` | `ksu_handle_input_handle_event` |

`resukisu` —— 八个调用点：在上面七个的基础上**去掉**
`ksu_handle_sys_read`（ReSukiSU 改用其 LSM 的
`CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK`），**新增** `fs/stat.c` 中的
`ksu_handle_newfstat_ret` 与 `ksu_handle_fstat64_ret`（ReSukiSU 的 Manager
依赖这对 `init.rc` 长度修正的返回值钩子）。

`resukisu-susfs` —— 由 SUSFS inline-hook 补丁新增的一套十个处理器。相较 `resukisu`，
它去掉了 `fs/stat.c` 的两个返回值钩子、改用 `ksu_handle_vfs_fstat`，重新引入
`ksu_handle_sys_read`，并新增 `ksu_handle_execveat_sucompat` 与
`ksu_handle_post_execveat_sucompat`，全部以 `susfs_is_current_proc_no_su()`
和 static key 守卫。

### defconfig

```
# ksunext
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES_HOOK is not set

# resukisu
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y

# resukisu-susfs
CONFIG_KSU=y
# CONFIG_KSU_MANUAL_HOOK is not set
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SUS_MAP=y
```

### 版本号

两种方案都从各自的 git 历史推导版本号，CI 为 zip 文件名复刻了同样的算法：

| 变体 | 公式 | 示例 |
|---|---|---|
| `ksunext` | `30000 + commit_count + 289` | 33296 |
| `resukisu[-susfs]` | `30000 + commit_count + 700` | 35184 |

偏移量与各自项目的 `kernel/Kbuild` 保持一致。

### SUSFS

SUSFS 是内核侧的 root 隐藏层。本内核启用的特性包括：可疑路径隐藏、挂载隐藏、
kstat 伪装、`uname` 伪装、`/proc/kallsyms` 符号隐藏，以及 `mmap` 隐藏。
内核侧移植代码来自
[simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)（已适配 4.14），
外加 ReSukiSU 的 inline-hook 补丁。

### seccomp（`CONFIG_SECCOMP`）

在 5.10 以下的内核上，ReSukiSU 的 seccomp **缓存**会被整体编译掉，因此 Manager
会显示「seccomp 未启用」。该缓存的作用是仅白名单 root 所需的系统调用、同时保留
filter。这是预期行为：内核会退化为在授予 root 权限的进程上直接关闭 `seccomp`。
4.14 内核上无需修复 —— 该缓存依赖本内核尚不存在的内核 API。

## 公共补丁

### `common/0002-nongki-backports.patch`

较新的 KernelSU-Next / ReSukiSU `Kbuild` 会在**构建过程中**通过
`$(shell sed -i ...)` 注入 `can_umount` / `path_umount`（`fs/namespace.c`）、
`struct seccomp.filter_count`（`include/linux/seccomp.h`）以及 SELinux 的
`selinux_inode()` / `selinux_cred()` 辅助函数。

这来得太晚：`fs/` 先于 `drivers/kernelsu/` 编译，注入的代码无法被所有编译单元
看到，链接会失败：

```
drivers/kernelsu/feature/kernel_umount.c:53: undefined reference to `path_umount'
```

将同样的回移植代码作为普通补丁在构建**之前**应用，即可确定性地解决该问题。这正是
这些回移植保留在 `patches/` 中、而非交给上游 `Kbuild` 的原因。

### `common/0001-gsi-genksyms-workaround.patch`

由于启用了 `CONFIG_MODVERSIONS=y`，每个 `EXPORT_SYMBOL` 都需要由 `genksyms`
生成 CRC。`drivers/platform/msm/gsi/gsi.c` 中的十四个导出以值传递方式接收
`union __packed gsi_*_scratch`，而 genksyms 无法展开该类型 —— 它会输出
`union gsi_chan_scratch { UNKNOWN }`，导致无法生成 CRC，`vmlinux` 链接失败：

```
relocation R_AARCH64_ABS32 cannot be used against symbol __crc_gsi_*
```

这些符号仅被 IPA/GSI 驱动使用，而它们在同一镜像中都是内建的（`=y`）；可加载的
`.ko` 模块均未引用它们（已用 `llvm-nm --undefined-only` 验证）。因此该补丁选择
移除这些导出。这是一个构建修复，而非功能性改动。

## 工具链：为什么必须使用完全一致的 PE 工具链

这是整个构建过程中最重要、也最不显然的一点。

| | PixelExperience 官方构建 | 随便一个现代工具链 |
|---|---|---|
| 编译器 | Android clang **r416183b (12.0.5)** | 任意较新 clang |
| 链接器 | **GNU ld (binutils 2.27)** | LLD |
| 汇编器 | GNU as 2.27 | LLVM IAS |

Linux 4.14 的 Kbuild 基本没有 LLD 支持 —— `ld-name = lld` 只是切换了寥寥几个
标志，大量构建逻辑都是围绕 GNU binutils 的语义编写的。与此同时，本内核同时
启用了 `CONFIG_RELOCATABLE` 与 `CONFIG_RANDOMIZE_BASE`，要求内核在启动时完成
自重定位。

用 LLD 链接出来的内核，其镜像结构上是合法的（`magiskboot` 能解析，bootloader
也接受），但会在显示子系统初始化之前崩溃 —— 表现为卡在开机第一个画面无限重启。
使用与 PE 匹配的工具链，则能产出构建字符串与原厂内核一致的内核：

```
Linux version 4.14.190-englezos-c0ad285ece (...) (Android (7284624, based on r416183b)
clang version 12.0.5 (...), GNU ld (binutils-2.27-...) 2.27.0.20170315)
```

`scripts/setup-toolchain.sh` 会先尝试从 AOSP gitiles 下载各组件，失败时回退到
LineageOS 的 GitHub 镜像（两者 tar 布局不同，用 `--strip-components` 处理），
并反复重试直到压缩包能通过 `tar tzf` 校验。

### 工具链陷阱：gold 与 bfd

AOSP 的 GCC 4.9 中，`arm-linux-androideabi-ld` 是**指向 gold 的符号链接**。
gold 生成的 32 位 vDSO 段布局会导致 `objcopy` 失败：

```
aarch64-linux-gnu-objcopy: arch/arm64/kernel/vdso32/vdso.so:
  Not enough room for program headers, try linking with -N
```

因此 `scripts/setup-toolchain.sh` 显式地将 `arm-linux-gnueabi-ld` 链接到
`arm-linux-androideabi-ld.bfd`。

## 验证构建结果

```bash
# 钩子符号是否存在？
grep -E "ksu_handle_(execveat|setresuid|sys_reboot|stat|faccessat|sys_read|input_handle_event)" \
  out/System.map

# 公共回移植是否生效？
grep -E " path_umount$" out/System.map

# SUSFS（仅 resukisu-susfs）？
grep -E "susfs_add_sus_path" out/System.map

# 构建字符串是否与出厂内核的工具链一致？
strings out/vmlinux | grep -m1 "Linux version"
```

## 与上游保持同步

工作流会在构建时解析各 root 方案默认分支的最新提交，因此每周定时任务会自动纳入
新提交。`su_ref` 可用于一次性覆盖。

如果上游重构了钩子 API，对应变体的补丁将无法应用，工作流会在打补丁阶段失败 ——
这是刻意设计的，因为一次静默的错误集成，比一次红色的构建失败更糟糕。

## 致谢

- [PixelExperience](https://github.com/PixelExperience) /
  [PixelExperience-Devices](https://github.com/PixelExperience-Devices) ——
  内核源码、设备树
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) 与
  [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) —— root 方案以及 4.14/4.19
  回移植
- [simonpunk](https://gitlab.com/simonpunk/susfs4ksu) —— SUSFS
- [osm0sis](https://github.com/osm0sis/AnyKernel3) —— AnyKernel3
- AOSP / Proton Clang —— 工具链

## 许可证

GPL-2.0-only，与上游内核保持一致。

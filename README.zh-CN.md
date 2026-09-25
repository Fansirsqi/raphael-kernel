# 小米 Redmi K20 Pro / Mi 9T Pro (raphael) KernelSU-Next 内核

面向小米 Redmi K20 Pro / Mi 9T Pro（代号 `raphael` / `raphaelin`）的自定义
Linux 4.14 内核，基于 PixelExperience 13 内核源码，并以 **manual-hook**（手动
挂钩）模式集成 [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)。

目标系统：Android 13（PE 13，`TQ3A.230901.001.B1`）。

## 为什么会有这个仓库

KernelSU-Next 官方自带的 `kernel/setup.sh` 集成路径，假定内核具备可用的
kprobe 支持（或为 GKI 内核）。而本设备的 4.14 SM8150 代码树**并未**启用
`CONFIG_KPROBES`，因此必须通过 KernelSU-Next 的 **manual hook** 模式接入：在
系统调用路径中显式插入 `ksu_handle_*()` 调用。本仓库正是为了保存这些补丁以及
一套可复现的 CI 流水线。

## 目录结构

```
.
├── .github/workflows/build.yml      # CI：构建内核 + AnyKernel3 刷机包
├── patches/
│   ├── 0001-ksunext-manual-hooks.patch      # 手动挂钩集成
│   └── 0002-gsi-genksyms-workaround.patch   # genksyms/CRC 修复（详见下文）
├── anykernel/
│   └── anykernel.sh                 # 会被复制进上游 AnyKernel3 代码树
├── scripts/
│   └── setup-toolchain.sh           # 获取与 PE 匹配的工具链
└── README.md
```

## 构建

### 本地构建

```bash
# 1. 获取内核源码（必须是 thirteen 分支）
git clone --depth 1 -b thirteen \
  https://github.com/PixelExperience-Devices/kernel_xiaomi_raphael.git kernel

# 2. 获取 KernelSU-Next（非 GKI 内核必须使用 legacy 分支）
git clone --depth 1 -b legacy \
  https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next

# 3. 应用集成补丁
cd kernel
git apply ../patches/0001-ksunext-manual-hooks.patch
git apply ../patches/0002-gsi-genksyms-workaround.patch
ln -sfn ../../KernelSU-Next/kernel drivers/kernelsu
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

手动触发 **Build Kernel** 工作流（或让每周定时任务自动抓取 KernelSU-Next 的
新提交）。该工作流会下载工具链、应用补丁、执行构建，随后将结果打包为
AnyKernel3 可刷写 zip 并作为构建产物上传。参见下文《与上游保持同步》。

## 刷入

1. 启动第三方 recovery（PE recovery / TWRP）。
2. 刷入 `KernelSU-Next-raphael-*.zip`。
   安装脚本会将新内核拼接进现有的 `boot` 分区，且不改动 ramdisk。
3. 重启，然后安装与之匹配的 KernelSU-Next Manager APK。

**回滚：** 从 ROM 的 zip 中重新刷入原厂 `boot.img`（若曾改动过 `dtbo.img`
也一并刷回）。

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

### 工具链陷阱：gold 与 bfd

AOSP 的 GCC 4.9 中，`arm-linux-androideabi-ld` 是**指向 gold 的符号链接**。
gold 生成的 32 位 vDSO 段布局会导致 `objcopy` 失败：

```
aarch64-linux-gnu-objcopy: arch/arm64/kernel/vdso32/vdso.so:
  Not enough room for program headers, try linking with -N
```

因此 `scripts/setup-toolchain.sh` 显式地将 `arm-linux-gnueabi-ld` 链接到
`arm-linux-androideabi-ld.bfd`。

## 集成细节

### 手动挂钩

`CONFIG_KSU_MANUAL_HOOK=y` 表示由内核自身（而非 kprobe）派发进入
KernelSU-Next。共添加了七个调用点（见 `patches/0001`）：

| 文件 | 函数 | 调用 |
|---|---|---|
| `fs/exec.c` | `do_execveat_common` | `ksu_handle_execveat` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat` |
| `fs/stat.c` | `vfs_statx` | `ksu_handle_stat` |
| `fs/read_write.c` | `SYSCALL_DEFINE3(read)` | `ksu_handle_sys_read` |
| `kernel/sys.c` | `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)` | `ksu_handle_sys_reboot` |
| `drivers/input/input.c` | `input_handle_event` | `ksu_handle_input_handle_event` |

另外还涉及在 `drivers/Kconfig`、`drivers/Makefile` 中的注册（`drivers/kernelsu`
是指向 KernelSU-Next 代码树的符号链接），以及 defconfig：

```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES_HOOK is not set
```

此外，KernelSU-Next 的 `kernel/Kbuild` 会在**构建时**回移植 `path_umount` /
`can_umount`（`fs/namespace.c`）、`struct seccomp.filter_count` 以及 SELinux 的
`selinux_inode()` / `selinux_cred()` 辅助函数。这些文件刻意**不**纳入补丁 ——
手工修改它们会导致每次 KernelSU-Next 更新时补丁冲突。

### `patches/0002` —— `union __packed` 上的 genksyms

由于启用了 `CONFIG_MODVERSIONS=y`，每个 `EXPORT_SYMBOL` 都需要由 `genksyms`
生成 CRC。`drivers/platform/msm/gsi/gsi.c` 中的十四个导出以值传递方式接收
`union __packed gsi_*_scratch`，而 genksyms 无法展开该类型 —— 它会输出
`union gsi_chan_scratch { UNKNOWN }`，导致无法生成 CRC，`vmlinux` 链接失败：

```
relocation R_AARCH64_ABS32 cannot be used against symbol __crc_gsi_*
```

这些符号仅被 IPA/GSI 驱动使用，而它们在同一镜像中都是内建的（`=y`）；12 个可
加载的 `.ko` 模块均未引用它们（已用 `llvm-nm --undefined-only` 验证）。因此该
补丁选择移除这些导出。这是一个构建修复，而非功能性改动。

## 验证构建结果

```bash
# KernelSU-Next 符号是否存在？
grep -E "ksu_handle_(execveat|setresuid|sys_reboot|stat|faccessat|sys_read|input_handle_event)" \
  out/System.map

# 构建字符串是否与出厂内核的工具链一致？
strings out/vmlinux | grep -m1 "Linux version"
```

## 与 KernelSU-Next 保持同步

工作流的 `ksunext_ref` 输入接受分支、标签或提交号，默认值为 `legacy` —— 即支持
诸如本内核这类非 GKI 内核的分支。

为了自动跟进上游，工作流按每周定时运行；它在构建时解析 `legacy` 分支的最新提交，
因此任何新提交都会被纳入。版本号由 KernelSU-Next 的 git 历史推导
（`30000 + commit_count + 200`）并嵌入 zip 文件名中。你也可以随时手动重跑该工作流。

如果上游某天重构了 manual-hook API，`patches/0001` 将无法应用，工作流会在打补丁
阶段失败 —— 这是刻意设计的，因为一次静默的错误集成，比一次红色的构建失败更糟糕。

## 致谢

- [PixelExperience](https://github.com/PixelExperience) /
  [PixelExperience-Devices](https://github.com/PixelExperience-Devices) ——
  内核源码、设备树
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) ——
  root 方案以及 4.14/4.19 回移植
- [osm0sis](https://github.com/osm0sis/AnyKernel3) —— AnyKernel3
- Proton Clang / AOSP —— 工具链

## 许可证

GPL-2.0-only，与上游内核保持一致。

# KernelSU-Next kernel for Xiaomi Redmi K20 Pro / Mi 9T Pro (raphael)

Custom Linux 4.14 kernel for the Xiaomi Redmi K20 Pro / Mi 9T Pro (`raphael` /
`raphaelin`), based on the PixelExperience 13 kernel source with
[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) integrated in
**manual-hook** mode.

Target: Android 13 (PE 13, `TQ3A.230901.001.B1`).

## Why this repository exists

KernelSU-Next's own `kernel/setup.sh` integration path assumes the kernel has
functional kprobe support (or GKI). This device's 4.14 SM8150 tree does **not**
enable `CONFIG_KPROBES`, so KernelSU-Next must be wired in through its
**manual hook** mode: explicit `ksu_handle_*()` calls inserted into the syscall
paths. This repository stores exactly those patches plus a reproducible CI
pipeline.

## Layout

```
.
├── .github/workflows/build.yml      # CI: builds the kernel + AnyKernel3 zip
├── patches/
│   ├── 0001-ksunext-manual-hooks.patch      # manual hook integration
│   └── 0002-gsi-genksyms-workaround.patch   # genksyms/CRC fix (see below)
├── anykernel/
│   └── anykernel.sh                 # copied into an upstream AnyKernel3 tree
├── scripts/
│   └── setup-toolchain.sh           # fetches the PE-matching toolchain
└── README.md
```

## Building

### Locally

```bash
# 1. Fetch the kernel source (must be the thirteen branch)
git clone --depth 1 -b thirteen \
  https://github.com/PixelExperience-Devices/kernel_xiaomi_raphael.git kernel

# 2. Fetch KernelSU-Next (legacy branch — required for non-GKI)
git clone --depth 1 -b legacy \
  https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next

# 3. Apply the integration patches
cd kernel
git apply ../patches/0001-ksunext-manual-hooks.patch
git apply ../patches/0002-gsi-genksyms-workaround.patch
ln -sfn ../../KernelSU-Next/kernel drivers/kernelsu
cd ..

# 4. Get the toolchain
./scripts/setup-toolchain.sh "$PWD/toolchain"

# 5. Build
cd kernel
export PATH="$PWD/../toolchain/clang-r416183b/bin:$PWD/../toolchain/gnu/bin:$PATH"
MAKE_ARGS=(O=out ARCH=arm64 CC=clang LD=aarch64-linux-gnu-ld \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-)
make "${MAKE_ARGS[@]}" raphael_defconfig
make "${MAKE_ARGS[@]}" -j"$(nproc)"
make "${MAKE_ARGS[@]}" Image.gz-dtb dtbo.img
```

Result: `out/arch/arm64/boot/Image.gz-dtb` (kernel + appended DTB) and
`out/arch/arm64/boot/dtbo.img`.

### Via GitHub Actions

Trigger the **Build Kernel** workflow manually (or let the weekly schedule pick
up new KernelSU-Next commits). It downloads the toolchain, applies the patches,
builds, wraps the result in an AnyKernel3 flashable zip, and uploads it as a
build artifact. See *Staying in sync* below.

## Flashing

1. Boot a third-party recovery (PE recovery / TWRP).
2. Flash `KernelSU-Next-raphael-*.zip`.
   The installer splices the new kernel into the existing `boot` partition and
   leaves the ramdisk untouched.
3. Reboot, then install the matching KernelSU-Next Manager APK.

**Rollback:** reflash the stock `boot.img` (and `dtbo.img` if you ever changed
it) from the ROM zip.

## Toolchain: why the exact PE toolchain is required

This is the single most important build detail, and it is not obvious.

| | PixelExperience official build | Naive modern toolchain |
|---|---|---|
| Compiler | Android clang **r416183b (12.0.5)** | any recent clang |
| Linker | **GNU ld (binutils 2.27)** | LLD |
| Assembler | GNU as 2.27 | LLVM IAS |

Linux 4.14's Kbuild has essentially no LLD support — `ld-name = lld` only
toggles a couple of flags, and much of the build logic is written around GNU
binutils semantics. Meanwhile this kernel enables both `CONFIG_RELOCATABLE` and
`CONFIG_RANDOMIZE_BASE`, which require the kernel to self-relocate at boot.

Linking such a kernel with LLD yields a boot image that is structurally valid
(`magiskboot` parses it, the bootloader accepts it) but dies before the display
subsystem initialises — an endless reboot at the first splash screen. Using the
PE-matching toolchain produces a kernel whose build string matches the stock
kernel:

```
Linux version 4.14.190-englezos-c0ad285ece (...) (Android (7284624, based on r416183b)
clang version 12.0.5 (...), GNU ld (binutils-2.27-...) 2.27.0.20170315)
```

### Toolchain gotcha: gold vs bfd

AOSP's `arm-linux-androideabi-ld` in GCC 4.9 is a **symlink to gold**. Gold's
32-bit vDSO section layout makes `objcopy` fail:

```
aarch64-linux-gnu-objcopy: arch/arm64/kernel/vdso32/vdso.so:
  Not enough room for program headers, try linking with -N
```

`scripts/setup-toolchain.sh` therefore links `arm-linux-gnueabi-ld` to
`arm-linux-androideabi-ld.bfd` explicitly.

## Integration details

### Manual hooks

`CONFIG_KSU_MANUAL_HOOK=y` means the kernel, not a kprobe, dispatches into
KernelSU-Next. Seven call sites are added (`patches/0001`):

| File | Function | Call |
|---|---|---|
| `fs/exec.c` | `do_execveat_common` | `ksu_handle_execveat` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat` |
| `fs/stat.c` | `vfs_statx` | `ksu_handle_stat` |
| `fs/read_write.c` | `SYSCALL_DEFINE3(read)` | `ksu_handle_sys_read` |
| `kernel/sys.c` | `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)` | `ksu_handle_sys_reboot` |
| `drivers/input/input.c` | `input_handle_event` | `ksu_handle_input_handle_event` |

Plus registration in `drivers/Kconfig`, `drivers/Makefile` (a `drivers/kernelsu`
symlink to the KernelSU-Next tree) and the defconfig:

```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_KPROBES_HOOK is not set
```

KernelSU-Next's `kernel/Kbuild` additionally backports `path_umount` /
`can_umount` (`fs/namespace.c`), `struct seccomp.filter_count`, and SELinux
`selinux_inode()` / `selinux_cred()` helpers **at build time**. Those files are
deliberately *not* part of the patches — editing them by hand would make the
patches conflict on every KernelSU-Next update.

### `patches/0002` — genksyms on `union __packed`

`CONFIG_MODVERSIONS=y`, so every `EXPORT_SYMBOL` needs a CRC generated by
`genksyms`. Fourteen exports in `drivers/platform/msm/gsi/gsi.c` take a
`union __packed gsi_*_scratch` by value, and genksyms cannot expand that type —
it emits `union gsi_chan_scratch { UNKNOWN }`, no CRC is produced, and the
`vmlinux` link fails with:

```
relocation R_AARCH64_ABS32 cannot be used against symbol __crc_gsi_*
```

These symbols are consumed only by the IPA/GSI drivers, which are built-in
(`=y`) in the same image; none of the 12 loadable `.ko` modules reference them
(verified with `llvm-nm --undefined-only`). The patch therefore drops those
exports. It is a build fix, not a functional change.

## Verifying a build

```bash
# KernelSU-Next symbols present?
grep -E "ksu_handle_(execveat|setresuid|sys_reboot|stat|faccessat|sys_read|input_handle_event)" \
  out/System.map

# Build string matches the stock kernel's toolchain?
strings out/vmlinux | grep -m1 "Linux version"
```

## Staying in sync with KernelSU-Next

The workflow's `ksunext_ref` input accepts a branch, tag or commit. It defaults
to `legacy`, which is the branch that supports non-GKI kernels such as this one.

To follow upstream automatically, the workflow runs on a weekly schedule; it
resolves the tip of `legacy` at build time, so any new commit is picked up. The
version is derived from the KernelSU-Next git history (`30000 + commit_count +
200`) and embedded in the zip filename. You can also re-run the workflow
manually at any time.

If upstream ever restructures the manual-hook API, `patches/0001` will fail to
apply and the workflow fails at the patch step — that is intentional, since a
silent mis-integration is worse than a red build.

## Credits

- [PixelExperience](https://github.com/PixelExperience) /
  [PixelExperience-Devices](https://github.com/PixelExperience-Devices) —
  kernel source, device tree
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — the
  root solution and the 4.14/4.19 backports
- [osm0sis](https://github.com/osm0sis/AnyKernel3) — AnyKernel3
- Proton Clang / AOSP — toolchains

## License

GPL-2.0-only, matching the upstream kernel.

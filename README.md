# Custom 4.14 kernel for Xiaomi Redmi K20 Pro / Mi 9T Pro (raphael)

Custom Linux 4.14 kernel for the Xiaomi Redmi K20 Pro / Mi 9T Pro (`raphael` /
`raphaelin`), based on the PixelExperience 13 kernel source, with a choice of
three root-solution integrations built from the same kernel tree:

| Variant | Root solution | Hook mode |
|---|---|---|
| `ksunext` | [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | manual hook |
| `resukisu` | [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) | manual hook |
| `resukisu-susfs` | ReSukiSU + [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) v2.2.0 | SUSFS inline hook |

Target: Android 13 (PE 13, `TQ3A.230901.001.B1`).

## Why this repository exists

Neither KernelSU-Next's nor ReSukiSU's own `kernel/setup.sh` integration path
works here: both assume functional kprobe support (or a GKI kernel), and this
device's 4.14 SM8150 tree does **not** enable `CONFIG_KPROBES`. Both solutions
must therefore be wired in through their **manual hook** (or, for SUSFS, its
inline-hook) mode: explicit `ksu_handle_*()` calls inserted into the syscall
paths. This repository stores exactly those patches plus a reproducible CI
pipeline.

## Layout

```
.
├── .github/workflows/build.yml            # CI: builds every variant + AnyKernel3 zips
├── patches/
│   ├── common/                            # applied for every variant
│   │   ├── 0001-gsi-genksyms-workaround.patch
│   │   └── 0002-nongki-backports.patch
│   ├── ksunext/0001-manual-hooks.patch
│   ├── resukisu/0001-manual-hooks.patch
│   └── susfs/0001-susfs-inline-hooks.patch
├── anykernel/anykernel.sh                 # template; @KSU_NAME@ is substituted per variant
├── scripts/setup-toolchain.sh             # fetches the PE-matching toolchain
└── README.md
```

## Building

### Locally

```bash
VARIANT=ksunext        # or: resukisu | resukisu-susfs

# 1. Kernel source (must be the thirteen branch)
git clone --depth 1 -b thirteen \
  https://github.com/PixelExperience-Devices/kernel_xiaomi_raphael.git kernel

# 2. Root solution (KernelSU-Next needs the non-GKI `legacy` branch)
case "$VARIANT" in
  ksunext)   git clone -b legacy https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next ;;
  resukisu*) git clone -b main   https://github.com/ReSukiSU/ReSukiSU.git ReSukiSU ;;
esac

# 3. Apply the patches: common/ first, then the variant's hook patch
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

# 4. Toolchain
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

Trigger the **Build Kernel** workflow and pick a variant. It fetches the
toolchain, applies the patches, builds, wraps the result in an AnyKernel3
flashable zip, and uploads it as a build artifact.

| Trigger | Behaviour |
|---|---|
| `workflow_dispatch` | builds only the selected `su` variant |
| `push` (to `main`) | builds **all three** variants, `fail-fast: false` |
| `schedule` (weekly) | builds all three, picking up new upstream commits |

Dispatch inputs:

| Input | Meaning |
|---|---|
| `su` | `ksunext` / `resukisu` / `resukisu-susfs` |
| `su_ref` | upstream ref override (default: `legacy` or `main`, per variant) |
| `kernel_branch` | kernel source branch (default `thirteen`) |
| `release` | publish a GitHub Release |
| `send_tg` | upload the zip to the Telegram channel |
| `tg_caption` | extra caption line for the Telegram post |

## Flashing

1. Boot a third-party recovery (PE recovery / TWRP).
2. Flash the zip (`KernelSU-Next-raphael-*.zip` or `ReSukiSU[-SUSFS]-raphael-*.zip`).
   The installer splices the new kernel into the existing `boot` partition and
   leaves the ramdisk untouched.
3. Reboot, then install the matching Manager APK.

**Rollback:** reflash the stock `boot.img` (and `dtbo.img` if you ever changed
it) from the ROM zip.

## CI caching

Two caches keep repeat builds cheap:

| Cache | Key | Notes |
|---|---|---|
| `toolchain` (≈1.6 GB) | `hashFiles('scripts/setup-toolchain.sh')` | re-downloaded only when the fetch script changes |
| `ccache` (≤1.5 GB per variant) | `variant` + kernel commit + KSU commit | `CC="ccache clang"`; progressively looser `restore-keys`, ending in a bare `ccache-` so a cold variant can seed from any other |

`CCACHE_COMPILERCHECK` is pinned to a constant string rather than hashing
`clang`, so the stable pinned toolchain never invalidates the cache.

Measured on GitHub-hosted runners: a cold three-variant run takes ≈23 min; a
warm one (ccache hit) ≈6 min.

## Telegram publishing

Configure two repository secrets under *Settings → Secrets and variables →
Actions*:

| Secret | Value |
|---|---|
| `TG_BOT_TOKEN` | token from [@BotFather](https://t.me/BotFather) |
| `TG_CHAT_ID` | channel id, e.g. `-100xxxxxxxxxx` (add the bot to the channel and grant it post permission) |

Then enable `send_tg` on a manual run, or let the weekly schedule post
automatically. If the secrets are absent the step logs a warning and **skips**
rather than failing the build. The upload uses the plain Bot API
(`sendDocument`), so no extra runner dependency is needed.

## Per-variant integration details

### Hook call sites

Every variant routes syscalls into the root solution from the kernel itself.

`ksunext` — seven call sites:

| File | Function | Call |
|---|---|---|
| `fs/exec.c` | `do_execveat_common` | `ksu_handle_execveat` |
| `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` | `ksu_handle_faccessat` |
| `fs/stat.c` | `vfs_statx` | `ksu_handle_stat` |
| `fs/read_write.c` | `SYSCALL_DEFINE3(read)` | `ksu_handle_sys_read` |
| `kernel/sys.c` | `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid` |
| `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)` | `ksu_handle_sys_reboot` |
| `drivers/input/input.c` | `input_handle_event` | `ksu_handle_input_handle_event` |

`resukisu` — eight call sites: the same set **minus** `ksu_handle_sys_read`
(ReSukiSU uses its LSM `CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK` instead)
**plus** `ksu_handle_newfstat_ret` and `ksu_handle_fstat64_ret` in `fs/stat.c`
(ReSukiSU's manager requires the `init.rc` size-patching return hooks).
`resukisu-susfs` — its own set of ten handlers, added by the SUSFS inline-hook
patch. Versus `resukisu` it drops the two `fs/stat.c` return hooks in favour of
`ksu_handle_vfs_fstat`, re-adds `ksu_handle_sys_read`, and adds
`ksu_handle_execveat_sucompat` / `ksu_handle_post_execveat_sucompat`. All are
guarded with `susfs_is_current_proc_no_su()` and static keys.

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

### Version codes

Both solutions derive the version from their own git history; the CI mirrors
that arithmetic for the zip name:

| Variant | Formula | Example |
|---|---|---|
| `ksunext` | `30000 + commit_count + 289` | 33296 |
| `resukisu[-susfs]` | `30000 + commit_count + 700` | 35184 |

The offsets match each project's `kernel/Kbuild`.

### SUSFS

SUSFS is a kernel-side root-hiding layer. Enabled features here: suspicious
path hiding, mount hiding, kstat spoofing, `uname` spoofing, `/proc/kallsyms`
symbol hiding, and `mmap` hiding. The kernel-side port comes from
[simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (adapted for
4.14) plus ReSukiSU's inline-hook patch.

### seccomp (`CONFIG_SECCOMP`)

On kernels < 5.10 ReSukiSU's seccomp *cache* — which whitelists just the
syscalls root needs, leaving the filter intact — is compiled out, so the
Manager reports "seccomp not enabled". That is expected: the kernel falls back
to fully disabling `seccomp` for root-granted processes. Nothing to fix on a
4.14 kernel; the filter cache needs kernel APIs that do not exist here.

## The common patches

### `common/0002-nongki-backports.patch`

Newer KernelSU-Next/ReSukiSU `Kbuild` files inject `can_umount` /
`path_umount` (`fs/namespace.c`), `struct seccomp.filter_count`
(`include/linux/seccomp.h`), and the SELinux `selinux_inode()` /
`selinux_cred()` helpers **during the build**, via `$(shell sed -i ...)`.

That is too late: `fs/` is compiled before `drivers/kernelsu/`, so the injected
code is not visible to every translation unit and the link fails with:

```
drivers/kernelsu/feature/kernel_umount.c:53: undefined reference to `path_umount'
```

Applying the same backports as a normal patch *before* the build fixes this
deterministically. This is why the backports live in `patches/` instead of
being left to the upstream `Kbuild`.

### `common/0001-gsi-genksyms-workaround.patch`

`CONFIG_MODVERSIONS=y`, so every `EXPORT_SYMBOL` needs a CRC generated by
`genksyms`. Fourteen exports in `drivers/platform/msm/gsi/gsi.c` take a
`union __packed gsi_*_scratch` by value, and genksyms cannot expand that type —
it emits `union gsi_chan_scratch { UNKNOWN }`, no CRC is produced, and the
`vmlinux` link fails with:

```
relocation R_AARCH64_ABS32 cannot be used against symbol __crc_gsi_*
```

These symbols are consumed only by the IPA/GSI drivers, which are built-in
(`=y`) in the same image; none of the loadable `.ko` modules reference them
(verified with `llvm-nm --undefined-only`). The patch therefore drops those
exports. It is a build fix, not a functional change.

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

`scripts/setup-toolchain.sh` downloads each component from AOSP gitiles first
and falls back to the LineageOS GitHub mirror (the two have different tar
layouts, handled via `--strip-components`), retrying until the archive passes
`tar tzf`.

### Toolchain gotcha: gold vs bfd

AOSP's `arm-linux-androideabi-ld` in GCC 4.9 is a **symlink to gold**. Gold's
32-bit vDSO section layout makes `objcopy` fail:

```
aarch64-linux-gnu-objcopy: arch/arm64/kernel/vdso32/vdso.so:
  Not enough room for program headers, try linking with -N
```

`scripts/setup-toolchain.sh` therefore links `arm-linux-gnueabi-ld` to
`arm-linux-androideabi-ld.bfd` explicitly.

## Verifying a build

```bash
# Hook symbols present?
grep -E "ksu_handle_(execveat|setresuid|sys_reboot|stat|faccessat|sys_read|input_handle_event)" \
  out/System.map

# The common backport is in place?
grep -E " path_umount$" out/System.map

# SUSFS (resukisu-susfs only)?
grep -E "susfs_add_sus_path" out/System.map

# Build string matches the stock kernel's toolchain?
strings out/vmlinux | grep -m1 "Linux version"
```

## Staying in sync with upstream

The workflow resolves the tip of each root solution's default branch at build
time, so the weekly schedule picks up new commits automatically. `su_ref`
overrides it for a one-off build.

If upstream restructures its hook API, the variant's patch will fail to apply
and the workflow fails at the patch step — that is intentional, since a silent
mis-integration is worse than a red build.

## Credits

- [PixelExperience](https://github.com/PixelExperience) /
  [PixelExperience-Devices](https://github.com/PixelExperience-Devices) —
  kernel source, device tree
- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) and
  [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) — root solutions and the
  4.14/4.19 backports
- [simonpunk](https://gitlab.com/simonpunk/susfs4ksu) — SUSFS
- [osm0sis](https://github.com/osm0sis/AnyKernel3) — AnyKernel3
- AOSP / Proton Clang — toolchains

## License

GPL-2.0-only, matching the upstream kernel.

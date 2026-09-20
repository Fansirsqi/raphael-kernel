#!/usr/bin/env bash
#
# Downloads the exact toolchain that PixelExperience uses for raphael, so that
# the resulting kernel matches the stock build as closely as possible.
#
#   clang      : Android clang r416183b (12.0.5)   -> matches stock build string
#   binutils   : AOSP GCC 4.9 / binutils 2.27      -> matches stock "GNU ld 2.27"
#
# Why this matters on a 4.14 kernel:
#   The 4.14 Kbuild has essentially no LLD support ("ld-name=lld" only affects a
#   couple of flags), while CONFIG_RELOCATABLE + CONFIG_RANDOMIZE_BASE require the
#   kernel to self-relocate at boot. Linking such a kernel with LLD produces a
#   bootable-looking image that dies before the display subsystem comes up.
#
# Usage:  ./scripts/setup-toolchain.sh [dest_dir]
#
set -euo pipefail

DEST="${1:-$PWD/toolchain}"
mkdir -p "$DEST"
cd "$DEST"

CLANG_DIR="clang-r416183b"
GCC64_DIR="gcc-aarch64-4.9"
GCC32_DIR="gcc-arm-4.9"

AOSP_CLANG="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/${CLANG_DIR}.tar.gz"
AOSP_GCC64="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/android10-release.tar.gz"
AOSP_GCC32="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/android10-release.tar.gz"

fetch() { # <url> <tar> <destdir>
  local url="$1" tar="$2" out="$3"
  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    echo "==> $out already present, skipping"
    return 0
  fi
  echo "==> Downloading $out"
  rm -f "$tar"
  curl -fsSL --retry 3 --retry-delay 2 -o "$tar" "$url"
  # AOSP gitiles occasionally returns a truncated archive; verify before extracting.
  if ! tar tzf "$tar" >/dev/null 2>&1; then
    echo "!! corrupt archive: $tar" >&2
    return 1
  fi
  mkdir -p "$out"
  tar xzf "$tar" -C "$out"
  rm -f "$tar"
}

fetch "$AOSP_CLANG" "${CLANG_DIR}.tar.gz" "$CLANG_DIR"
fetch "$AOSP_GCC64" "${GCC64_DIR}.tar.gz" "$GCC64_DIR"
fetch "$AOSP_GCC32" "${GCC32_DIR}.tar.gz" "$GCC32_DIR"

# PE sets CROSS_COMPILE=aarch64-linux-gnu- / CROSS_COMPILE_ARM32=arm-linux-gnueabi-,
# so expose the AOSP binaries under those names.
#
# IMPORTANT: use ld.bfd, not ld.gold. AOSP GGC 4.9's arm-linux-androideabi-ld is a
# symlink to gold by default, and gold's 32-bit vDSO section layout makes objcopy
# fail with "Not enough room for program headers, try linking with -N".
mkdir -p gnu/bin
for t in ld as objcopy nm ar strip objdump readelf addr2line; do
  [ -x "$GCC64_DIR/bin/aarch64-linux-android-$t" ] \
    && ln -sf "$PWD/$GCC64_DIR/bin/aarch64-linux-android-$t" "gnu/bin/aarch64-linux-gnu-$t"
done
for t in ld as objcopy nm ar strip objdump; do
  src="$GCC32_DIR/bin/arm-linux-androideabi-$t"
  [ "$t" = "ld" ] && src="$GCC32_DIR/bin/arm-linux-androideabi-ld.bfd"
  [ -x "$src" ] && ln -sf "$PWD/$src" "gnu/bin/arm-linux-gnueabi-$t"
done

echo
echo "==> Toolchain ready in $DEST"
echo "    clang : $("$CLANG_DIR/bin/clang" --version | head -n1)"
echo "    ld64  : $("gnu/bin/aarch64-linux-gnu-ld" --version | head -n1)"
echo "    ld32  : $("gnu/bin/arm-linux-gnueabi-ld" --version | head -n1)"

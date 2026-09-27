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
# Each component is fetched from AOSP gitiles first, then from the LineageOS
# GitHub mirror if gitiles is unavailable (it throttles/flakes from CI runners).
# The two sources have different tar layouts, so extraction is source-aware.
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

# AOSP gitiles: the archive contains the directory *contents* (no top-level dir).
AOSP_CLANG="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android12-release/${CLANG_DIR}.tar.gz"
AOSP_GCC64="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/android10-release.tar.gz"
AOSP_GCC32="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/android10-release.tar.gz"

# LineageOS GitHub mirrors: the archive has a "<repo>-<branch>/" top-level dir.
GH_CLANG="https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b/archive/refs/heads/lineage-20.0.tar.gz"
GH_GCC64="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/archive/refs/heads/lineage-19.1.tar.gz"
GH_GCC32="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9/archive/refs/heads/lineage-19.1.tar.gz"

# download <url> <tar>: fetch with generous retries. gitiles occasionally
# returns a truncated archive, so retry until `tar tzf` succeeds.
download() {
  local url="$1" tar="$2" attempt
  for attempt in 1 2 3 4 5; do
    rm -f "$tar"
    if curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
         --retry-all-errors -o "$tar" "$url" && tar tzf "$tar" >/dev/null 2>&1; then
      return 0
    fi
    echo "    attempt $attempt failed for $(basename "$url"); retrying..."
    rm -f "$tar"
    sleep 5
  done
  return 1
}

# strip_components: gitiles archives have no top-level dir (0), GitHub
# tarballs are wrapped in "<repo>-<branch>/" (1).
fetch() { # <aosp_url> <gh_url> <destdir> <strip_components>
  local aosp="$1" gh="$2" out="$3" strip="$4"
  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    echo "==> $out already present, skipping"
    return 0
  fi

  local tar="${out}.tar.gz"
  echo "==> Downloading $out (strip=${strip})"
  if download "$aosp" "$tar"; then
    echo "    source: AOSP gitiles"
  elif download "$gh" "$tar"; then
    echo "    source: LineageOS GitHub mirror"
  else
    echo "!! could not download $out from any source" >&2
    return 1
  fi

  rm -rf "$out"
  mkdir -p "$out"
  tar xzf "$tar" -C "$out" --strip-components="$strip"
  rm -f "$tar"
}

fetch "$AOSP_CLANG" "$GH_CLANG" "$CLANG_DIR" 0
fetch "$AOSP_GCC64" "$GH_GCC64" "$GCC64_DIR" 0
fetch "$AOSP_GCC32" "$GH_GCC32" "$GCC32_DIR" 0

# PE sets CROSS_COMPILE=aarch64-linux-gnu- / CROSS_COMPILE_ARM32=arm-linux-gnueabi-,
# so expose the AOSP binaries under those names.
#
# IMPORTANT: use ld.bfd, not ld.gold. AOSP GCC 4.9's arm-linux-androideabi-ld is a
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

#!/usr/bin/env bash
# Builds a lean, LGPL, shared FFmpeg for Windows on ARM64 or x64.
#
# Runs in an MSYS2 CLANGARM64 shell for ARM64, or a CLANG64 shell for x64, locally or on
# GitHub's windows-11-arm and windows-latest runners.
# The DLLs link only Windows system libraries: dav1d and zlib are linked in statically,
# and every other external library (librsvg, cairo, fontconfig, ...) is left out.
# BtbN's winarm64 builds crash on load on some Snapdragon X machines inside their
# statically linked librsvg/cairo/DirectWrite code; this build avoids that code entirely.
# The x64 build is the same configuration, so both architectures get the same FFmpeg.
#
# Output: work/<name>.zip with bin/ (7 DLLs, ffmpeg.exe, ffprobe.exe) and licenses,
#         plus work/checksums.sha256 in GNU sha256sum format, listing this tag's zips
#         for every architecture built in work/.
#
# Environment:
#   FFMPEG_TAG   FFmpeg git tag to build (default n8.1.3, i.e. avcodec-62 for FFmpeg.AutoGen 8.1)
#   WORK         build directory (default ./work)
#   JOBS         make parallelism (default: nproc)
set -euo pipefail

FFMPEG_TAG=${FFMPEG_TAG:-n8.1.3}
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$ROOT/work}
JOBS=${JOBS:-$(nproc)}
SRC=$WORK/src/ffmpeg-$FFMPEG_TAG
BUILD=$WORK/build-$FFMPEG_TAG
PREFIX=$WORK/install-$FFMPEG_TAG

# -O3 -mtune=oryon-1 schedules for Snapdragon X cores without using any instruction older
# ARM64 Windows PCs lack (-mcpu would): HEVC decodes ~15% faster per core, bit-identically.
# x64 keeps the default tuning: FFmpeg picks its SIMD code at run time there, and needs
# nasm to assemble it.
case "${MSYSTEM:-}" in
	CLANGARM64) ARCH=arm64; FFARCH=aarch64; CFLAGS="-O3 -mtune=oryon-1"; ASM= ;;
	CLANG64)    ARCH=x64;   FFARCH=x86_64;  CFLAGS="-O3";                 ASM=nasm ;;
	*)
		echo "error: run this in an MSYS2 CLANGARM64 (ARM64) or CLANG64 (x64) shell (MSYSTEM=${MSYSTEM:-})" >&2
		exit 1 ;;
esac

NAME=ffmpeg-${FFMPEG_TAG#n}-lean-lgpl-shared-win-$ARCH
DIST=$WORK/$NAME

for tool in clang llvm-ar llvm-nm llvm-strip llvm-objdump pkgconf make git $ASM; do
	command -v "$tool" >/dev/null || { echo "error: $tool not found; install the packages listed in README.md" >&2; exit 1; }
done

mkdir -p "$WORK/src"
if [ ! -d "$SRC" ]; then
	git -c advice.detachedHead=false clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

# Out-of-tree build so reconfiguring never needs a clean source tree.
rm -rf "$BUILD" "$PREFIX" "$DIST"
mkdir -p "$BUILD"
cd "$BUILD"

# --disable-autodetect stops configure from picking up whatever happens to be installed
# in the MSYS2 prefix, so the result is the same on every machine. Threads, zlib and the
# Windows hardware decoders then have to be enabled explicitly.
# --pkg-config-flags=--static and -static make lld take libdav1d.a/libz.a instead of
# their import libraries; Windows system import libraries are .a files, so they still
# resolve to the system DLLs.
"$SRC/configure" \
	--prefix="$PREFIX" \
	--target-os=mingw32 --arch="$FFARCH" \
	--cc=clang --cxx=clang++ --ar=llvm-ar --nm=llvm-nm --ranlib=llvm-ranlib \
	--strip=llvm-strip --windres=llvm-windres \
	--pkg-config=pkgconf --pkg-config-flags=--static \
	--extra-ldflags=-static \
	--extra-cflags="$CFLAGS" \
	--extra-version=lean \
	--enable-shared --disable-static \
	--disable-autodetect \
	--enable-w32threads \
	--enable-zlib \
	--enable-libdav1d \
	--enable-d3d11va --enable-dxva2 --enable-d3d12va \
	--disable-network \
	--disable-devices --enable-indev=lavfi \
	--disable-ffplay \
	--disable-doc \
	--disable-debug \
	| tee "$WORK/configure-$FFMPEG_TAG.log"

make -j"$JOBS"
make install

mkdir -p "$DIST/bin" "$DIST/licenses"
cp "$PREFIX"/bin/*.dll "$PREFIX/bin/ffmpeg.exe" "$PREFIX/bin/ffprobe.exe" "$DIST/bin/"
cp "$SRC/COPYING.LGPLv2.1" "$DIST/licenses/FFmpeg-LGPL-2.1.txt"
cp "$SRC/LICENSE.md" "$DIST/licenses/FFmpeg-LICENSE.md"
cp "$MINGW_PREFIX/share/licenses/dav1d/COPYING" "$DIST/licenses/dav1d-BSD-2-Clause.txt"
cp "$MINGW_PREFIX/share/licenses/zlib/LICENSE" "$DIST/licenses/zlib.txt"
{
	echo "FFmpeg $FFMPEG_TAG, lean LGPL shared build for Windows $ARCH"
	echo "Source: https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_TAG"
	echo "Compiler: $(clang --version | head -1)"
	echo "dav1d: $(pkgconf --modversion dav1d)  zlib: $(pkgconf --modversion zlib)"
	echo
	"$DIST/bin/ffmpeg.exe" -hide_banner -buildconf
} > "$DIST/readme.txt"

# Fail the build if any binary imports a DLL that is neither ours nor part of Windows.
echo "Imported DLLs:"
imports=$(for f in "$DIST"/bin/*; do llvm-objdump -p "$f" | sed -n 's/^ *DLL Name: //p'; done | sort -u)
echo "$imports" | sed 's/^/  /'
unexpected=$(echo "$imports" | grep -viE '^(av(codec|device|filter|format|util)|sw(resample|scale))-[0-9]+\.dll$|^(kernel32|user32|advapi32|bcrypt|ole32|oleaut32|shell32|shlwapi|gdi32|psapi|secur32|ws2_32|d3d11|d3d12|dxgi|dxva2|mfplat|mfuuid|strmiids|vfw32|ntdll)\.dll$|^api-ms-win-.*\.dll$' || true)
if [ -n "$unexpected" ]; then
	echo "error: unexpected DLL dependencies:" >&2
	echo "$unexpected" >&2
	exit 1
fi

"$DIST/bin/ffmpeg.exe" -hide_banner -version | head -1

cd "$WORK"
rm -f "$NAME.zip"
# Windows' own bsdtar writes a zip when the name ends in .zip.
/c/Windows/System32/tar.exe -a -c -f "$NAME.zip" "$NAME"
sha256sum ffmpeg-${FFMPEG_TAG#n}-lean-lgpl-shared-win-*.zip | sed 's/ \*/  /' > checksums.sha256
cat checksums.sha256
ls -l "$NAME.zip"

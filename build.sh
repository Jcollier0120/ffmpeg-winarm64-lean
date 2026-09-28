#!/usr/bin/env bash
# Builds a lean, LGPL, shared FFmpeg for Windows on ARM64.
#
# Runs in an MSYS2 CLANGARM64 shell, locally or on a GitHub windows-11-arm runner.
# The DLLs link only Windows system libraries: dav1d and zlib are linked in statically,
# and every other external library (librsvg, cairo, fontconfig, ...) is left out.
# BtbN's winarm64 builds crash on load on some Snapdragon X machines inside their
# statically linked librsvg/cairo/DirectWrite code; this build avoids that code entirely.
#
# Output: work/<name>.zip with bin/ (7 DLLs, ffmpeg.exe, ffprobe.exe) and licenses,
#         plus work/checksums.sha256 in GNU sha256sum format.
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
NAME=ffmpeg-${FFMPEG_TAG#n}-lean-lgpl-shared-win-arm64
DIST=$WORK/$NAME

if [ "${MSYSTEM:-}" != CLANGARM64 ]; then
	echo "error: run this in an MSYS2 CLANGARM64 shell (MSYSTEM=$MSYSTEM)" >&2
	exit 1
fi

for tool in clang llvm-ar llvm-nm llvm-strip llvm-objdump pkgconf make git; do
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

# -O3 -mtune=oryon-1 schedules for Snapdragon X cores without using any instruction older
# ARM64 Windows PCs lack (-mcpu would): HEVC decodes ~15% faster per core, bit-identically.
# --disable-autodetect stops configure from picking up whatever happens to be installed
# in the MSYS2 prefix, so the result is the same on every machine. Threads, zlib and the
# Windows hardware decoders then have to be enabled explicitly.
# --pkg-config-flags=--static and -static make lld take libdav1d.a/libz.a instead of
# their import libraries; Windows system import libraries are .a files, so they still
# resolve to the system DLLs.
"$SRC/configure" \
	--prefix="$PREFIX" \
	--target-os=mingw32 --arch=aarch64 \
	--cc=clang --cxx=clang++ --ar=llvm-ar --nm=llvm-nm --ranlib=llvm-ranlib \
	--strip=llvm-strip --windres=llvm-windres \
	--pkg-config=pkgconf --pkg-config-flags=--static \
	--extra-ldflags=-static \
	--extra-cflags="-O3 -mtune=oryon-1" \
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
cp /clangarm64/share/licenses/dav1d/COPYING "$DIST/licenses/dav1d-BSD-2-Clause.txt"
cp /clangarm64/share/licenses/zlib/LICENSE "$DIST/licenses/zlib.txt"
{
	echo "FFmpeg $FFMPEG_TAG, lean LGPL shared build for Windows ARM64"
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
sha256sum "$NAME.zip" | sed 's/ \*/  /' > checksums.sha256
cat checksums.sha256
ls -l "$NAME.zip"

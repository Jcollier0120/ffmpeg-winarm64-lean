#!/usr/bin/env bash
# Builds a lean, LGPL, shared FFmpeg for Windows on ARM64 or x64.
#
# Runs in an MSYS2 CLANGARM64 shell for ARM64, or a CLANG64 shell for x64, locally or on
# GitHub's windows-11-arm and windows-latest runners.
# The DLLs link only Windows system libraries: dav1d and zlib are linked in statically,
# and every other external library (librsvg, cairo, fontconfig, ...) is left out.
# BtbN's winarm64 builds crash on load on some Snapdragon X machines inside their
# statically linked librsvg/cairo/DirectWrite code; this build avoids that code entirely.
# The x64 build is the same configuration, plus the graphics cards' own encoders: NVIDIA's
# NVENC, AMD's AMF and Intel's Quick Sync (through libvpl, linked in statically). ARM64
# Windows PCs have none of those graphics cards, so its build leaves them out.
# The source is FFmpeg's tag plus the fixes in patches/, each of which says what it fixes.
#
# Output: work/<name>.zip with bin/ (7 DLLs, ffmpeg.exe, ffprobe.exe), licenses and patches,
#         plus work/checksums.sha256 in GNU sha256sum format, listing this tag's zips
#         for every architecture built in work/.
#
# Environment:
#   FFMPEG_TAG     FFmpeg git tag to build (default n8.1.3, i.e. avcodec-62 for FFmpeg.AutoGen 8.1)
#   NVHEADERS_TAG  nv-codec-headers git tag for NVENC on x64 (default n12.2.72.0)
#   WORK           build directory (default ./work)
#   JOBS           make parallelism (default: nproc)
set -euo pipefail

FFMPEG_TAG=${FFMPEG_TAG:-n8.1.3}
# NVENC's headers are FFmpeg's nv-codec-headers at this tag, not MSYS2's newer package: Video
# Codec SDK 12.2 runs on NVIDIA's drivers from 551.76 on (13.0 needs 570). With it FFmpeg 8.1
# leaves out only what 13.0 added: 10-bit H.264, 4:2:2, AV1's UHQ tuning, HEVC and AV1
# mastering metadata (HDR10) and MV-HEVC.
NVHEADERS_TAG=${NVHEADERS_TAG:-n12.2.72.0}
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
#
# x64 also builds the graphics cards' encoders, each in its maker's MIT-licensed headers;
# all three load the graphics driver's own runtime when they open, so they add no DLL:
# - NVENC (h264/hevc/av1_nvenc, nv-codec-headers at NVHEADERS_TAG): nvEncodeAPI64.dll and
#   nvcuda.dll. No CUDA SDK, no libnpp and no --enable-nonfree: the build stays LGPL.
# - AMF (h264/hevc/av1_amf, AMF headers): amfrt64.dll.
# - Quick Sync (h264/hevc/av1_qsv, vpp_qsv, through libvpl's dispatcher): the Intel
#   driver's libmfx-gen.dll. libvpl.a is linked in; it is C++, so libc++ comes with it,
#   statically, as -static already makes every library.
# They take Direct3D 11 frames, so ddagrab's captures reach them with nothing read back:
# NVENC and AMF as they are, Quick Sync after hwmap=derive_device=qsv and vpp_qsv.
HWENC=()
case "${MSYSTEM:-}" in
	CLANGARM64) ARCH=arm64; FFARCH=aarch64; CFLAGS="-O3 -mtune=oryon-1"; ASM= ;;
	CLANG64)    ARCH=x64;   FFARCH=x86_64;  CFLAGS="-O3";                 ASM=nasm
		HWENC=(--enable-ffnvcodec --enable-nvenc --enable-amf --enable-libvpl --extra-libs=-lc++) ;;
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
# Sources are checked out with LF line endings whatever git's settings, so the patches apply.
clone() { git -c advice.detachedHead=false -c core.autocrlf=false clone --depth 1 --branch "$1" "$2" "$3"; }
if [ ! -d "$SRC" ]; then
	clone "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

# The tag as it is, every build, then the patches. The zip carries them too: with the tag
# they are the source of its programs, as the LGPL asks.
git -C "$SRC" -c core.autocrlf=false checkout -q --force --detach "$FFMPEG_TAG"
git -C "$SRC" clean -q -fdx
shopt -s nullglob
PATCHES=("$ROOT"/patches/*.patch)
shopt -u nullglob
for p in "${PATCHES[@]}"; do
	git -C "$SRC" -c core.autocrlf=false apply "$p"
	echo "Applied ${p##*/}"
done

if [ "$ARCH" = x64 ]; then
	NVSRC=$WORK/src/nv-codec-headers-$NVHEADERS_TAG
	NVPREFIX=$WORK/nv-codec-headers-$NVHEADERS_TAG
	[ -d "$NVSRC" ] || clone "$NVHEADERS_TAG" https://github.com/FFmpeg/nv-codec-headers.git "$NVSRC"
	make -s -C "$NVSRC" install PREFIX="$NVPREFIX"
	# Ahead of MSYS2's own folders, so a newer ffnvcodec-headers package there isn't taken.
	export PKG_CONFIG_PATH="$NVPREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
	nv=$(pkgconf --modversion ffnvcodec)
	[ "$nv" = "${NVHEADERS_TAG#n}" ] || { echo "error: pkgconf finds nv-codec-headers $nv, not ${NVHEADERS_TAG#n}" >&2; exit 1; }
fi

# Out-of-tree build so reconfiguring never needs a clean source tree.
rm -rf "$BUILD" "$PREFIX" "$DIST"
mkdir -p "$BUILD"
cd "$BUILD"

# --disable-autodetect stops configure from picking up whatever happens to be installed
# in the MSYS2 prefix, so the result is the same on every machine. Threads, zlib, the
# Windows hardware decoders and Media Foundation then have to be enabled explicitly.
# Media Foundation's encoders (h264_mf, hevc_mf, av1_mf with -hw_encoding 1) reach the PC's
# own video encoder; Snapdragon X2's is only offered that way, not through D3D12 video
# encode. They load mfplat.dll at run time and add no DLL dependency.
# Of the devices, only lavfi (test sources) and dshow (DirectShow: capture cards, cameras and
# their sound) are built. dshow links strmiids and uuid statically, and imports only Windows'
# own ole32, oleaut32, shlwapi and psapi.
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
	--enable-mediafoundation \
	"${HWENC[@]}" \
	--disable-network \
	--disable-devices --enable-indev=lavfi --enable-indev=dshow \
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
if [ ${#PATCHES[@]} -gt 0 ]; then
	mkdir -p "$DIST/patches"
	cp "${PATCHES[@]}" "$DIST/patches/"
fi
if [ "$ARCH" = x64 ]; then
	# nv-codec-headers' MIT notices are each header's opening comment.
	for h in "$NVPREFIX"/include/ffnvcodec/*.h; do
		echo "== ${h##*/} =="
		sed -n '1,/\*\//p' "$h"
		echo
	done > "$DIST/licenses/nv-codec-headers-MIT.txt"
	cp "$MINGW_PREFIX/share/licenses/amf-headers/LICENSE" "$DIST/licenses/AMF-MIT.txt"
	cp "$MINGW_PREFIX/share/licenses/libvpl/LICENSE" "$DIST/licenses/libvpl-MIT.txt"
	# AMF's headers have no pkg-config file; their version is in Version.h.
	amf=$(sed -n 's/^#define AMF_VERSION_\(MAJOR\|MINOR\|RELEASE\|BUILD_NUM\) *\([0-9]*\).*/\2/p' \
		"$MINGW_PREFIX/include/AMF/core/Version.h" | paste -sd.)
fi
{
	echo "FFmpeg $FFMPEG_TAG, lean LGPL shared build for Windows $ARCH"
	echo "Source: https://github.com/FFmpeg/FFmpeg/tree/$FFMPEG_TAG"
	for p in "${PATCHES[@]}"; do echo "  with patches/${p##*/}"; done
	echo "Compiler: $(clang --version | head -1)"
	echo "dav1d: $(pkgconf --modversion dav1d)  zlib: $(pkgconf --modversion zlib)"
	if [ "$ARCH" = x64 ]; then
		echo "nv-codec-headers: $nv (NVIDIA driver 551.76 or newer)  AMF headers: $amf  libvpl: $(pkgconf --modversion vpl)"
	fi
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

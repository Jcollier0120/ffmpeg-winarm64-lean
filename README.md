# ffmpeg-winarm64-lean

A small, LGPL, shared-library FFmpeg for Windows on ARM64, and since `n8.1.3-3` for x64
too. It's built for [Heiward](https://github.com/Jcollier0120/Heiward)'s in-process
FFmpeg.AutoGen 8.1 binding (avcodec-62) and its ffmpeg.exe/ffprobe.exe code path, and
ships inside Heiward's Microsoft Store package.
Heiward is based on [Video Duplicate Finder](https://github.com/0x90d/videoduplicatefinder).

## Why

BtbN's `winarm64` builds (8.1, 9.0 and master; GPL and LGPL; shared and static) crash
with 0xC0000005 while `avcodec-62.dll` loads on some Snapdragon X machines, so even
`ffmpeg -version` fails. The fault is in load-time init code of the statically linked
librsvg/cairo/DirectWrite stack. This build leaves all of that out.

The x64 build has the same configuration, so an app gets the same FFmpeg on both
architectures, a fraction of the size of a full build.

## What's in it

- All of FFmpeg's built-in decoders, demuxers, filters, parsers and encoders: h264, hevc,
  vp8/vp9, mjpeg, png, gif, webp, tiff, bmp, prores, ...; mov/mp4/HEIF, matroska/webm,
  avi, mpegts, flv, ...
- AV1 through dav1d (static, BSD-2-Clause)
- zlib (static)
- D3D11VA, DXVA2 and D3D12VA hardware decoding (Windows system APIs)
- Media Foundation encoders (`h264_mf`, `hevc_mf`, `av1_mf`; `aac_mf`, `ac3_mf`, `mp3_mf`).
  With `-hw_encoding 1` they reach the PC's own video encoder. On a Snapdragon X2 Elite
  (Adreno X2-90, driver 32.0.172.2) that is the only way in: `hevc_mf` opens "QCOM Hardware
  Encoder - HEVC" and encodes 1080p30 at about 16× real time, while the driver offers no
  D3D12 video encode, so `hevc_d3d12va` and friends are listed but refuse to open.
- Threads through Win32; no libwinpthread
- No network protocols, no capture devices (except the lavfi test input), no ffplay
- ARM64: compiled `-O3 -mtune=oryon-1`, which schedules for Snapdragon X cores. HEVC
  decodes ~15% faster per core than at FFmpeg's default -O2, and it still only uses
  instructions every ARM64 Windows PC has.
- x64: compiled `-O3` with FFmpeg's hand-written SIMD assembly (nasm), picked at run time
  for the CPU at hand

The binaries import only Windows system DLLs and each other. `build.sh` fails if that
changes.

License: LGPL-2.1-or-later (FFmpeg), plus the dav1d and zlib licenses; all three are in
`licenses/` inside the zip.

## Build locally

Install [MSYS2](https://www.msys2.org). For ARM64, in a CLANGARM64 shell:

```sh
pacman -S --needed make diffutils git \
  mingw-w64-clang-aarch64-{clang,lld,llvm-tools,pkgconf,dav1d,zlib}
./build.sh                    # FFMPEG_TAG=n8.1.3 by default
```

For x64, in a CLANG64 shell:

```sh
pacman -S --needed make diffutils git \
  mingw-w64-clang-x86_64-{clang,lld,llvm-tools,pkgconf,dav1d,zlib,nasm}
./build.sh
```

The zip and `checksums.sha256` land in `work/`.

## Build on GitHub Actions

`.github/workflows/build.yml` runs the same script for ARM64 on a `windows-11-arm` runner
and for x64 on `windows-latest`. Push a tag named after the FFmpeg tag (for example
`n8.1.3`, or `n8.1.3-3` for a rebuild of the same FFmpeg) to publish a release with both
zips and a `checksums.sha256` that VDF's downloader verifies. The release is created only
after both architectures have built. An existing release is never touched, since
downloaders pin its assets' SHA-256. Run the workflow by hand to get build artifacts
without a release.

## Releases

- `n8.1.3-4`: adds the Media Foundation encoders, for hardware encoding on Snapdragon X
- `n8.1.3-3`: adds the x64 build; ARM64 is built as in `n8.1.3-2`
- `n8.1.3-2`: `-O3 -mtune=oryon-1` (~15% faster HEVC per core, bit-identical output)
- `n8.1.3`: first release, FFmpeg's default optimization

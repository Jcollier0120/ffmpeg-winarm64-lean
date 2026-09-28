# ffmpeg-winarm64-lean

A small, LGPL, shared-library FFmpeg for Windows on ARM64, built for
[Video Duplicate Finder](https://github.com/0x90d/videoduplicatefinder)'s in-process
FFmpeg.AutoGen 8.1 binding (avcodec-62) and its ffmpeg.exe/ffprobe.exe code path.

## Why

BtbN's `winarm64` builds (8.1, 9.0 and master; GPL and LGPL; shared and static) crash
with 0xC0000005 while `avcodec-62.dll` loads on some Snapdragon X machines, so even
`ffmpeg -version` fails. The fault is in load-time init code of the statically linked
librsvg/cairo/DirectWrite stack. This build leaves all of that out.

## What's in it

- All of FFmpeg's built-in decoders, demuxers, filters, parsers and encoders: h264, hevc,
  vp8/vp9, mjpeg, png, gif, webp, tiff, bmp, prores, ...; mov/mp4/HEIF, matroska/webm,
  avi, mpegts, flv, ...
- AV1 through dav1d (static, BSD-2-Clause)
- zlib (static)
- D3D11VA, DXVA2 and D3D12VA hardware decoding (Windows system APIs)
- Threads through Win32; no libwinpthread
- No network protocols, no capture devices (except the lavfi test input), no ffplay
- Compiled `-O3 -mtune=oryon-1`: scheduled for Snapdragon X cores (HEVC decodes ~15% faster
  per core than at FFmpeg's default -O2), still only using instructions every ARM64 Windows
  PC has

The binaries import only Windows system DLLs and each other. `build.sh` fails if that
changes.

License: LGPL-2.1-or-later (FFmpeg), plus the dav1d and zlib licenses; all three are in
`licenses/` inside the zip.

## Build locally

Install [MSYS2](https://www.msys2.org), then in a CLANGARM64 shell:

```sh
pacman -S --needed make diffutils git \
  mingw-w64-clang-aarch64-{clang,lld,llvm-tools,pkgconf,dav1d,zlib}
./build.sh                    # FFMPEG_TAG=n8.1.3 by default
```

The zip and `checksums.sha256` land in `work/`.

## Build on GitHub Actions

`.github/workflows/build.yml` runs the same script on a `windows-11-arm` runner. Push a
tag named after the FFmpeg tag (for example `n8.1.3`, or `n8.1.3-2` for a rebuild of the
same FFmpeg) to publish a release with the zip and a `checksums.sha256` that VDF's
downloader verifies. An existing release is never touched, since downloaders pin its
assets' SHA-256. Run the workflow by hand to get a build artifact without a release.

## Releases

- `n8.1.3-2`: `-O3 -mtune=oryon-1` (~15% faster HEVC per core, bit-identical output)
- `n8.1.3`: first release, FFmpeg's default optimization

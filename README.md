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
architectures, a fraction of the size of a full build. Since `n8.1.3-7` it also has the
graphics cards' own encoders (NVIDIA, AMD, Intel), which ARM64 PCs don't have.

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
- x64 only: the graphics cards' hardware encoders, for H.264, HEVC and AV1:
  - NVIDIA NVENC (`h264_nvenc`, `hevc_nvenc`, `av1_nvenc`), from nv-codec-headers
    12.2 (MIT). It needs NVIDIA's driver 551.76 or newer. 13.0's headers would need 570
    and add only 10-bit H.264, 4:2:2, AV1's UHQ tuning, HDR10 mastering metadata and
    MV-HEVC.
  - AMD AMF (`h264_amf`, `hevc_amf`, `av1_amf`), from AMF's headers (MIT).
  - Intel Quick Sync (`h264_qsv`, `hevc_qsv`, `av1_qsv`, and the `vpp_qsv` filter),
    through Intel's libvpl dispatcher (MIT), linked in statically.

  Each loads its driver's own runtime when it opens (`nvEncodeAPI64.dll`, `amfrt64.dll`,
  Intel's `libmfx-gen.dll`), so the build adds no DLL and still runs on a PC without
  the card. No CUDA SDK, no libnpp, no `--enable-nonfree`: it stays LGPL.

  They take Direct3D 11 frames, so a `ddagrab` screen capture reaches the encoder with
  nothing read back to memory: `h264_nvenc` and `h264_amf` take ddagrab's frames as they
  are; Quick Sync takes them after `hwmap=derive_device=qsv,format=qsv,vpp_qsv=format=nv12`,
  which maps and converts them on the GPU.
- `scale_d3d11`, patched (`patches/`): scales and converts Direct3D 11 frames to NV12 or
  P010 on any graphics card, with Direct3D 11's own video processor. As FFmpeg ships it,
  it fails unless `format` is given, fails on drivers that refuse NV12 texture arrays
  (Qualcomm's Adreno), lets frames queued in an encoder share one surface, and tags its
  NV12 output from a screen capture as RGB, which an encoder then signals. The patch
  fixes all four; it converts RGB to BT.709 limited range. With it a screen capture stays
  on the GPU all the way into Media Foundation's encoders, which take Direct3D 11 NV12
  frames, on Snapdragon too:

  ```
  ffmpeg -f lavfi -i ddagrab=framerate=60 -vf scale_d3d11=format=nv12 -c:v hevc_mf -hw_encoding 1 out.mp4
  ffmpeg -f lavfi -i ddagrab=framerate=60 -vf scale_d3d11=1920:-2 -c:v h264_nvenc out.mp4
  ```

  It also resolves a negative size (`1920:-2`, keeping the aspect ratio), which FFmpeg's
  own `scale_d3d11` doesn't.
- `ddagrab`, patched: its frames can be read by shaders too. AMD's `h264_amf` and its
  `vpp_amf` and `sr_amf` filters convert a screen capture with a shader, and failed on
  FFmpeg's ddagrab frames (`h264_amf`: "SubmitInput() failed with error 18"); `hevc_amf`
  and `av1_amf` worked.
- x64: AMD's filters take Direct3D 11 frames (`vpp_amf` failed with "AMFConverter-Init()
  failed with error 10"), with FFmpeg's own fix from its master branch (d43b1efd).
- Threads through Win32; no libwinpthread
- No network protocols, no capture devices but lavfi (test sources) and DirectShow
  (`-f dshow`: capture cards, cameras and their sound), no ffplay
- ARM64: compiled `-O3 -mtune=oryon-1`, which schedules for Snapdragon X cores. HEVC
  decodes ~15% faster per core than at FFmpeg's default -O2, and it still only uses
  instructions every ARM64 Windows PC has.
- x64: compiled `-O3` with FFmpeg's hand-written SIMD assembly (nasm), picked at run time
  for the CPU at hand

The binaries import only Windows system DLLs and each other. `build.sh` fails if that
changes.

License: LGPL-2.1-or-later (FFmpeg), plus the dav1d and zlib licenses, and on x64 the
MIT licenses of nv-codec-headers, AMF's headers and libvpl; all of them are in
`licenses/` inside the zip. The source is FFmpeg's tag with the patches in `patches/`,
which the zip carries too. The parts of LLVM's libc++ that libvpl uses are linked in
too, under Apache-2.0 with the LLVM exception, which asks no notice for them.

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
  mingw-w64-clang-x86_64-{clang,lld,llvm-tools,pkgconf,dav1d,zlib,nasm} \
  mingw-w64-clang-x86_64-{amf-headers,libvpl}
./build.sh                    # fetches nv-codec-headers n12.2.72.0 itself
```

The zip and `checksums.sha256` land in `work/`. Each build checks out FFmpeg's tag afresh
and applies `patches/*.patch`.

## Build on GitHub Actions

`.github/workflows/build.yml` runs the same script for ARM64 on a `windows-11-arm` runner
and for x64 on `windows-latest`. Push a tag named after the FFmpeg tag (for example
`n8.1.3`, or `n8.1.3-3` for a rebuild of the same FFmpeg) to publish a release with both
zips and a `checksums.sha256` that VDF's downloader verifies. The release is created only
after both architectures have built. An existing release is never touched, since
downloaders pin its assets' SHA-256. Every pull request builds and smoke-tests both
architectures too, and publishes nothing. Run the workflow by hand to get build artifacts
without a release.

## Releases

- `n8.1.3-8`: `scale_d3d11` patched to work on every graphics card, and `ddagrab`'s
  frames readable by shaders (both architectures); on x64, AMD's `h264_amf` and
  `vpp_amf` take screen captures, and NVENC is built with nv-codec-headers 12.2, for
  NVIDIA drivers from 551.76
- `n8.1.3-7`: x64 adds NVIDIA's, AMD's and Intel's hardware encoders (NVENC, AMF,
  Quick Sync); ARM64 is built as in `n8.1.3-5`
- `n8.1.3-6`: `n8.1.3-5` with every program and library signed, so Windows' Smart App
  Control lets them run; signed after the build, so it has no tag here
- `n8.1.3-5`: adds DirectShow input (`-f dshow`), for recording from capture cards
- `n8.1.3-4`: adds the Media Foundation encoders, for hardware encoding on Snapdragon X
- `n8.1.3-3`: adds the x64 build; ARM64 is built as in `n8.1.3-2`
- `n8.1.3-2`: `-O3 -mtune=oryon-1` (~15% faster HEVC per core, bit-identical output)
- `n8.1.3`: first release, FFmpeg's default optimization

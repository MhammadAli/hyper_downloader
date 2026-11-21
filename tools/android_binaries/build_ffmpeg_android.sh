#!/usr/bin/env bash
set -euo pipefail

# Cross-compiles LGPL-2.1 standalone PIE `ffmpeg` and `ffprobe` executables for
# Android (`arm64-v8a` or `x86_64`, API 26+) with 16 KB ELF page alignment.

ABI="$1"
FFMPEG_SRC="$2"
BUILD_ROOT="$3"
OUT_PREFIX="$4"
NDK_DIR="$5"
API_LEVEL="${6:-26}"

export PATH="/c/Program Files/Git/usr/bin:/usr/bin:/bin:${NDK_DIR}/prebuilt/windows-x86_64/bin:${PATH}"

TOOLCHAIN="${NDK_DIR}/toolchains/llvm/prebuilt/windows-x86_64"
TOOLCHAIN_BIN_WIN="$(cygpath -m "${TOOLCHAIN}/bin")"
SYSROOT_WIN="$(cygpath -m "${TOOLCHAIN}/sysroot")"
OUT_PREFIX_WIN="$(cygpath -m "${OUT_PREFIX}")"

case "${ABI}" in
  arm64-v8a)
    ARCH="aarch64"
    CPU="armv8-a"
    TARGET_TRIPLE="aarch64-linux-android${API_LEVEL}"
    EXTRA_ARCH_FLAGS=""
    ;;
  x86_64)
    ARCH="x86_64"
    CPU="x86-64"
    TARGET_TRIPLE="x86_64-linux-android${API_LEVEL}"
    EXTRA_ARCH_FLAGS="--disable-x86asm"
    ;;
  *)
    echo "Unsupported ABI: ${ABI}. Only arm64-v8a and x86_64 are supported." >&2
    exit 1
    ;;
esac

CC="${TOOLCHAIN_BIN_WIN}/clang.exe --target=${TARGET_TRIPLE}"
CXX="${TOOLCHAIN_BIN_WIN}/clang++.exe --target=${TARGET_TRIPLE}"
AR="${TOOLCHAIN_BIN_WIN}/llvm-ar.exe"
RANLIB="${TOOLCHAIN_BIN_WIN}/llvm-ranlib.exe"
STRIP="${TOOLCHAIN_BIN_WIN}/llvm-strip.exe"
NM="${TOOLCHAIN_BIN_WIN}/llvm-nm.exe"

BUILD_DIR="${BUILD_ROOT}/ffmpeg-build-${ABI}"
rm -rf "${BUILD_DIR}" "${OUT_PREFIX}"
mkdir -p "${OUT_PREFIX}"
cp -a "${FFMPEG_SRC}" "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo "Configuring FFmpeg in-tree for ${ABI} (API ${API_LEVEL})..."
./configure \
  --prefix="${OUT_PREFIX_WIN}" \
  --enable-cross-compile \
  --target-os=android \
  --arch="${ARCH}" \
  --cpu="${CPU}" \
  --cc="${CC}" \
  --cxx="${CXX}" \
  --ar="${AR}" \
  --ranlib="${RANLIB}" \
  --strip="${STRIP}" \
  --nm="${NM}" \
  --sysroot="${SYSROOT_WIN}" \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --disable-gpl \
  --disable-nonfree \
  --enable-small \
  --disable-debug \
  --disable-doc \
  --disable-htmlpages \
  --disable-manpages \
  --disable-podpages \
  --disable-txtpages \
  --disable-autodetect \
  --enable-zlib \
  --disable-avdevice \
  --disable-ffplay \
  --enable-ffmpeg \
  --enable-ffprobe \
  --disable-everything \
  --enable-protocol=file,pipe,crypto,data,hls,http,https,tcp,udp \
  --enable-demuxer=mov,matroska,webm_dash_manifest,ogg,mp3,aac,flac,wav,mpegts,hls,concat,ffmetadata,ac3,eac3,avi,flv \
  --enable-muxer=mp4,matroska,webm,ipod,ogg,opus,mp3,adts,flac,wav,mpegts,ffmetadata,null,mov \
  --enable-parser=aac,aac_latm,ac3,flac,h264,hevc,mpegaudio,mpeg4video,opus,vorbis,vp8,vp9,av1 \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,vp9_raw_reorder,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,av1_metadata,extract_extradata,null \
  --enable-decoder=aac,aac_fixed,aac_latm,ac3,eac3,alac,flac,mp3,mp3float,opus,vorbis,pcm_s16le,pcm_s16be,pcm_s24le,pcm_f32le,h264,hevc,vp8,vp9,av1,mpeg4,mjpeg,png,webp,mov_text,subrip,webvtt \
  --enable-encoder=aac,alac,flac,opus,vorbis,pcm_s16le,mov_text,subrip,webvtt,mjpeg,png \
  --enable-filter=aresample,asetpts,setpts,anull,null,scale,format,aformat,volume \
  ${EXTRA_ARCH_FLAGS} \
  --extra-cflags="-O2 -fPIE -fPIC" \
  --extra-ldflags="-pie -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

# Keep SRC_PATH relative so Win32 NDK make.exe never sees MSYS /f/... paths.
sed -i 's|^SRC_PATH=.*|SRC_PATH=.|; s|^SRC_LINK=.*|SRC_LINK=.|' ffbuild/config.mak

# Avoid Win32 32,767-char CreateProcess truncation when llvm-ar.exe archives libavcodec.a.
perl -i -pe 's|\$\(AR\) \$\(ARFLAGS\) \$\(AR_O\) \$\^|\$(file >\$\@.rsp,\$\^)\n\t\$(AR) \$(ARFLAGS) \$(AR_O) \@\$\@.rsp|' ffbuild/library.mak

JOBS="$(nproc 2>/dev/null || echo 4)"
echo "Building FFmpeg for ${ABI} with -j${JOBS}..."
make SHELL="/c/Program Files/Git/usr/bin/sh.exe" -j"${JOBS}" ffmpeg ffprobe
mkdir -p "${OUT_PREFIX}/bin"
cp -f ffmpeg "${OUT_PREFIX}/bin/ffmpeg"
cp -f ffprobe "${OUT_PREFIX}/bin/ffprobe"
"${STRIP}" --strip-unneeded "${OUT_PREFIX}/bin/ffmpeg" "${OUT_PREFIX}/bin/ffprobe"
echo "Built FFmpeg + FFprobe for ${ABI}."

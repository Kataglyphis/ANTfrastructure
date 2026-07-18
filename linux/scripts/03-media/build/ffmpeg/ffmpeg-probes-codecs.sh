#!/usr/bin/env bash
# ffmpeg-probes-codecs.sh - Codec-specific FFmpeg dependency probe wrappers
# Split out of build-ffmpeg.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by build-ffmpeg.sh — expects its set -euo pipefail and IFS.

ffmpeg_probe_libmp3lame() {
    ffmpeg_probe_library_feature "libmp3lame" "lame/lame.h" "lame_set_VBR_quality" "-lmp3lame -lm"
}

ffmpeg_probe_libopus() {
    ffmpeg_probe_pkg_config_feature "libopus" "opus" "opus_multistream.h" "opus_multistream_decoder_create opus_multistream_surround_encoder_create"
}

ffmpeg_probe_libvorbis() {
    if ffmpeg_probe_pkg_config_feature "libvorbis" "vorbis" "vorbis/codec.h" "vorbis_info_init" &&
       ffmpeg_probe_pkg_config_feature "libvorbisenc" "vorbisenc" "vorbis/vorbisenc.h" "vorbis_encode_init"; then
        return 0
    fi

    echo "Skipping libvorbis: FFmpeg-style codec and encoder probes did not both pass."
    return 1
}

ffmpeg_probe_libvpx_variant() {
    # shellcheck disable=SC2034  # pre-existing dead store ("feature" was never read
    # here even in the monolithic build-ffmpeg.sh); the file split merely unmasked
    # the warning. Kept verbatim — pure structural refactor, no behavior change.
    local feature="$1"
    local headers="$2"
    local symbols="$3"

    ffmpeg_try_pkg_config_probe "vpx >= 1.4.0" "${headers}" "${symbols}" || \
        ffmpeg_try_link_probe "${headers}" "${symbols}" "" "-lvpx -lm -lpthread"
}

ffmpeg_probe_libvpx() {
    local passed=1

    ffmpeg_probe_libvpx_variant "libvpx_vp8_decoder" "vpx/vpx_decoder.h vpx/vp8dx.h" "vpx_codec_vp8_dx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp8_encoder" "vpx/vpx_encoder.h vpx/vp8cx.h" "vpx_codec_vp8_cx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp9_decoder" "vpx/vpx_decoder.h vpx/vp8dx.h" "vpx_codec_vp9_dx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0
    ffmpeg_probe_libvpx_variant "libvpx_vp9_encoder" "vpx/vpx_encoder.h vpx/vp8cx.h" "vpx_codec_vp9_cx VPX_IMG_FMT_HIGHBITDEPTH" && passed=0

    if [ "${passed}" -eq 0 ]; then
        return 0
    fi

    echo "Skipping libvpx: FFmpeg-style decoder and encoder probes failed."
    return 1
}

ffmpeg_probe_libx264() {
    if ffmpeg_probe_pkg_config_feature "libx264" "x264" "stdint.h x264.h" "x264_encoder_encode" &&
       ffmpeg_try_cpp_condition "stdint.h x264.h" "X264_BUILD >= 155"; then
        return 0
    fi

    echo "Skipping libx264: FFmpeg-style pkg-config or build-version probe failed."
    return 1
}

# HEVC encoder. x265 version-macros its public symbols (x265_api_get ->
# x265_api_get_<build>), but the probe micro-program includes x265.h so the
# macro expands before linking, and the framework's spurious-link-failure
# fallback (headers-compile + empty-main-links) covers the versioned .so case.
# Only consulted when FFMPEG_ENABLE_X265 is set (see build-ffmpeg.sh).
ffmpeg_probe_libx265() {
    if ffmpeg_probe_pkg_config_feature "libx265" "x265" "stdint.h x265.h" "x265_api_get"; then
        return 0
    fi

    echo "Skipping libx265: FFmpeg-style pkg-config or link probe failed."
    return 1
}

ffmpeg_probe_vdpau() {
    if ! ffmpeg_try_cpp_condition "vdpau/vdpau.h" "defined VDP_DECODER_PROFILE_MPEG4_PART2_ASP"; then
        echo "Skipping vdpau: FFmpeg-style header probe failed."
        return 1
    fi

    ffmpeg_probe_library_feature "vdpau" "vdpau/vdpau.h vdpau/vdpau_x11.h" "vdp_device_create_x11" "-lvdpau -lX11"
}

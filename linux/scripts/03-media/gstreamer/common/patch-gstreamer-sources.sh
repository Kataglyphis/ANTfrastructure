#!/usr/bin/env bash
set -euo pipefail

append_meson_arg_if_missing() {
  local args_ref_name="$1"
  local arg="$2"
  local current="${!args_ref_name:-}"

  case " ${current} " in
    *" ${arg} "*|*" ${arg}")
      return 0
      ;;
  esac

  printf -v "${args_ref_name}" '%s%s%s' "${current}" "${current:+ }" "${arg}"
}

gst_plugins_rs_meson_option_disabled() {
  local meson_args="$1"
  local option_name="$2"

  case " ${meson_args} " in
    *" -Dgst-plugins-rs:${option_name}=disabled "*)
      return 0
      ;;
  esac

  return 1
}

prune_gst_plugins_rs_workspace_member() {
  local cargo_toml="$1"
  local member="$2"

  [ -f "${cargo_toml}" ] || return 0

  if grep -Fq "\"${member}\"," "${cargo_toml}"; then
    echo "Removing gst-plugins-rs workspace member '${member}' from ${cargo_toml}"
    grep -Fvx "    \"${member}\"," "${cargo_toml}" > "${cargo_toml}.tmp"
    mv "${cargo_toml}.tmp" "${cargo_toml}"
  fi
}

prune_disabled_gst_plugins_rs_workspace_members() {
  local cargo_toml="$1"
  local meson_args="$2"

  [ -f "${cargo_toml}" ] || return 0

  # cargo-cbuild still resolves workspace members from the root manifest even
  # when Meson filters the selected plugin packages with `-p ...`.
  if gst_plugins_rs_meson_option_disabled "${meson_args}" burn; then
    prune_gst_plugins_rs_workspace_member "${cargo_toml}" "analytics/burn"
  fi
}

patch_gstreamer_sources() {
  local repo_root="$1"
  local meson_args="$2"
  local cargo_toml="${repo_root}/subprojects/gst-plugins-rs/Cargo.toml"
  local cargo_wrapper_py="${repo_root}/subprojects/gst-plugins-rs/cargo_wrapper.py"
  local gst_plugins_rs_meson="${repo_root}/subprojects/gst-plugins-rs/meson.build"
  local webrtc_ice_h="${repo_root}/subprojects/gst-plugins-bad/gst-libs/gst/webrtc/ice.h"
  local lame_meson="${repo_root}/subprojects/gst-plugins-good/ext/lame/meson.build"

  [ -d "${repo_root}" ] || {
    echo "ERROR: GStreamer repo root not found: ${repo_root}" >&2
    return 1
  }

  # gst-plugins-bad 1.29.x ships gtk-doc blocks for internal WebRTC ABI fields
  # that do not map to real C identifiers. Downgrade only those blocks to plain
  # C comments so g-ir-scanner ignores the doc.skip-only internals.
  if [ -f "${webrtc_ice_h}" ]; then
    perl -0pi -e '
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI: \(attributes doc\.skip=true\)\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi: \(attributes doc\.skip=true\)\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi\.foundation:\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi\.related_address:\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi\.related_port:\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi\.username_fragment:\n)@/*\n$1@g;
      s@/\*\*\n(\s+\* GstWebRTCICECandidateStats\.ABI\.abi\.tcp_type:\n)@/*\n$1@g;
    ' "${webrtc_ice_h}"
  fi

  # gst-plugins-good's LAME probe currently treats a visible lame header as
  # sufficient even when the target libmp3lame library was not found. On cross
  # builds that can produce a later link line with no -lmp3lame at all. Tighten
  # the probe so the plugin is only enabled when the library lookup succeeded.
  if [ -f "${lame_meson}" ] && \
     grep -Fq "have_lame = cc.has_header_symbol('lame/lame.h', 'lame_init')" "${lame_meson}" && \
     ! grep -Fq "have_lame = lame_dep.found() and cc.has_header_symbol('lame/lame.h', 'lame_init')" "${lame_meson}"; then
    sed -i "s/have_lame = cc.has_header_symbol('lame\/lame.h', 'lame_init')/have_lame = lame_dep.found() and cc.has_header_symbol('lame\/lame.h', 'lame_init')/" "${lame_meson}"
  fi

  # When Meson drives gst-plugins-rs through cargo_wrapper.py in cross builds,
  # the RUSTC wrapper may intentionally omit --target so host-side build scripts
  # still use the native toolchain. cargo-cbuild's pkg-config generation then
  # falls back to the host triple unless cargo_wrapper.py forwards the explicit
  # Cargo target. Reuse CARGO_BUILD_TARGET when available and mirror it back
  # into Cargo's env so cargo-c stops using the host/default target layout.
  if [ -f "${cargo_wrapper_py}" ] && \
     grep -Fq "env['RUSTC'] = rustc_cmdline[0]" "${cargo_wrapper_py}" && \
     ! grep -Fq "env.get('CROSS_RUST_TARGET')" "${cargo_wrapper_py}"; then
    perl -0pi -e "s/env\['RUSTC'\] = rustc_cmdline\[0\]\n(?:\n    if not rustc_target:\n        rustc_target = env\.get\('CARGO_BUILD_TARGET'\)\n)?/env['RUSTC'] = rustc_cmdline[0]\n\n    if not rustc_target:\n        rustc_target = env.get('CARGO_BUILD_TARGET') or env.get('CROSS_RUST_TARGET')\n    if rustc_target and 'CARGO_BUILD_TARGET' not in env:\n        env['CARGO_BUILD_TARGET'] = rustc_target\n/" "${cargo_wrapper_py}"
  fi

  # Meson's custom_target env only forwards the keys in extra_env. Copy the
  # shell's explicit cross Rust target into gst-plugins-rs' extra_env so the
  # vendored cargo wrapper can always append --target for cargo-c.
  if [ -f "${gst_plugins_rs_meson}" ] && \
     grep -Fq "extra_env = {}" "${gst_plugins_rs_meson}" && \
     ! grep -Fq "extra_env += {'CARGO_BUILD_TARGET': cargo_build_target}" "${gst_plugins_rs_meson}"; then
    perl -0pi -e "s/extra_env = \{\}\n/extra_env = {}\n\ncargo_build_target = ''\nif python.found()\n  cargo_build_target = run_command(python, '-c', 'import os; print(os.environ.get(\"CARGO_BUILD_TARGET\") or os.environ.get(\"CROSS_RUST_TARGET\") or \"\")', check: true).stdout().strip()\nendif\nif cargo_build_target != ''\n  extra_env += {'CARGO_BUILD_TARGET': cargo_build_target}\nendif\n/" "${gst_plugins_rs_meson}"
  fi

  prune_disabled_gst_plugins_rs_workspace_members "${cargo_toml}" "${meson_args}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  repo_root="${1:-$PWD}"
  meson_args="${2:-${MESON_ARGS:-${EXTRA_MESON_ARGS:-}}}"
  patch_gstreamer_sources "${repo_root}" "${meson_args}"
fi

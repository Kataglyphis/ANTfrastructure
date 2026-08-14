#!/usr/bin/env bash
# Put the PINNED rustup toolchain ahead of Ubuntu's Rust debs on PATH.
#
# The runtime images carry TWO Rusts:
#   /usr/local/cargo/bin  rustup proxies for the pinned toolchain (RUST_VERSION,
#                         1.97.1 at the time of writing)
#   /bin, /usr/bin        Ubuntu's cargo/rustc debs (1.93.1), pulled in as
#                         dependencies of other packages
# and the image ENV lists /usr/local/cargo/bin AFTER /bin, so the deb wins by
# default. /etc/profile.d/10-rust.sh corrects the order, but only for LOGIN
# shells - and CI steps that run `bash <script>` rather than `bash -lc` are not
# login shells, so they got the deb.
#
# Worse, the two can be mixed WITHIN one step, because the proxies are not a
# complete set: a step could get cargo/clippy from the pinned toolchain while
# `rustc` still resolved to the deb. Measured on Kataglyphis-RustProjectTemplate
# 2026-08-14:
#
#   rustc 1.93 / clippy-driver 1.97
#
# The visible failures are unrelated-looking and blame the dependencies:
#   error: rustc 1.93.1 is not supported by the following packages:
#     egui@0.36.1 requires rustc 1.95   (and seven more)
#   error[E0658]: use of unstable library feature `array_windows`
# for crates that build cleanly on the pinned toolchain.
#
# HOIST, do not merely append: the directory is already on PATH, just last, so
# an "add it if missing" guard is a no-op - a first attempt at this failed
# exactly that way and its diagnostic still printed /bin/cargo.
if [ -x /usr/local/cargo/bin/cargo ]; then
  _rtg_path=":${PATH}:"
  _rtg_path="${_rtg_path//:\/usr\/local\/cargo\/bin:/:}"
  _rtg_path="${_rtg_path#:}"
  _rtg_path="${_rtg_path%:}"
  export PATH="/usr/local/cargo/bin:${_rtg_path}"
  unset _rtg_path
fi

# Report what actually won. A silently-mixed toolchain is the failure mode this
# guard exists to prevent, so the versions belong in the log even on success.
if command -v info >/dev/null 2>&1; then
  info "rust toolchain: $(command -v cargo 2>/dev/null || echo 'cargo: not found') ($(cargo --version 2>/dev/null || echo '?')) | $(rustc --version 2>/dev/null || echo 'rustc: not found')"
fi

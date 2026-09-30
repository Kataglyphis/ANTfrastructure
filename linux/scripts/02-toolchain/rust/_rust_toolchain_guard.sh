#!/usr/bin/env bash
# Hoist, not append, the pinned toolchain ahead of Ubuntu's Rust debs, which non-login shells would mix in.
if [ -x /usr/local/cargo/bin/cargo ]; then
  _rtg_path=":${PATH}:"
  _rtg_path="${_rtg_path//:\/usr\/local\/cargo\/bin:/:}"
  _rtg_path="${_rtg_path#:}"
  _rtg_path="${_rtg_path%:}"
  export PATH="/usr/local/cargo/bin:${_rtg_path}"
  unset _rtg_path
fi

# Log what won, even on success: a silently mixed toolchain is what this guard prevents.
if command -v info >/dev/null 2>&1; then
  info "rust toolchain: $(command -v cargo 2>/dev/null || echo 'cargo: not found') ($(cargo --version 2>/dev/null || echo '?')) | $(rustc --version 2>/dev/null || echo 'rustc: not found')"
fi

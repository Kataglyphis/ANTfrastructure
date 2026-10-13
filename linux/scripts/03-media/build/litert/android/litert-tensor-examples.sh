#!/usr/bin/env bash
# Under android/ because Dockerfile.android COPYs only that dir; both the Linux and the Android LiteRT build source it.

# <litert-root>: drop the tensor API demos no image ships; v2.3.0's gemma3 one fetches sentencepiece v0.2.0, which lacks <cstdint> under clang.
litert_prune_tensor_examples() {
    local d="${1:?LiteRT source root required}/tensor/examples"
    [ -d "${d}" ] || return 0
    rm -rf "${d:?}"
    printf '[INFO] LiteRT: pruned %s; tensor/CMakeLists.txt adds an example only when its directory exists\n' "${d}"
}

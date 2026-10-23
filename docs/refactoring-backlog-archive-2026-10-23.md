# Refactoring backlog archive — 2026-10-23

Closed work moved from [`refactoring-backlog.md`](refactoring-backlog.md) after review
of merged source `657f28031e8438e93cecfff17a1892693ff0abfd` and its recorded gates.
Earlier archives and their original build-proof limits remain unchanged.

## F1. Function size and complexity — closed

`function-size.allow` and `code-complexity.allow` contain no exceptions. Branch,
nesting and function-size limits hold without increasing thresholds or shrinking the scan.
The source-CI record for repair PR35 proves 277 suites, 11,121 assertions and all
2,179 registered mutations; this is gate evidence, not a new full image build.

The completed refactors separate shell orchestration from Python probes, metadata extraction,
Meson emission, UV extras and dependency dispatch. GStreamer configuration separates host
and target settings. Runtime checks separate row dispatch, version comparisons and tree
verdicts. Storage admission, pressure recovery and archive enumeration retain their refusal
paths. Vulkan installation separates download verification from archive placement and target
builds. Regression and mutation suites exercise these boundaries.

The comment walker keeps its independent scan: importing `verify_code_size.scan` would omit
patch directories and narrow comment coverage. Function extraction changes no scan scope.
The empty-list requirement remains in [AGENTS.md](../AGENTS.md).

## Shared wrapper sequence — closed

The former review note about repeated image/rootfs build, smoke and ship orchestration is
superseded by `_runtime_wrapper_then_ship` in `01-core/runtime-build-fns.sh`.
Both public paths use it; the smoke-overlap and wheel-source suites retain their failure guards.
See [CHANGELOG.md](../CHANGELOG.md), 2026-10-22, shared wrapper build and shipping.

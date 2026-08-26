# Kataglyphis-ContainerHub — agent guardrails

**This file is the rulebook, not the manual.** It captures what an automated
agent must and must not do to avoid regressing the build, plus the canonical
build commands. Reference data — what is in an image, per-component build
matrices, script tables — lives in `docs/`; the map from topic to owning
document is [`docs/INDEX.md`](docs/INDEX.md).

Four companion pages carry what used to live here. Read the one that matches
what you are about to do:

| Before you… | Read |
|---|---|
| Edit anything under `windows/` | [`docs/windows-build-invariants.md`](docs/windows-build-invariants.md) — 44 load-bearing rules |
| Debug an error message | [`docs/failure-modes.md`](docs/failure-modes.md) — symptom → cause → fix |
| Launch or debug a Windows chain | [`docs/windows-build-lanes.md`](docs/windows-build-lanes.md) — BuildKit, nerdctl, classic |
| Wire a new project to this repo | [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md) |
| **Add or bump a dependency** | [`docs/third-party-licenses.md`](docs/third-party-licenses.md) § Maintaining this list — an `spdx` id is mandatory, copyleft needs a source pointer, and the build gates both |

## Contents

**Rules — never regress these**

- [Project priorities](#project-priorities-owner-directive--optimize-for-all-three-always) — the three goals, and that correctness bounds every shortcut
- [Shell safety conventions](#shell-safety-conventions-five-bug-classes-all-found-live-2026-08-08) — five bash bug classes, all found live
- [Caching discipline](#caching-discipline-do-not-regress) — closure freeze, the ccache/sccache hybrid, the Windows exception
- [Cross Chain Stage Handoff](#cross-chain-stage-handoff-do-not-regress) — digest pinning, and why `-t` not `--output type=image`
- [Five Critical Fixes To Maintain](#five-critical-fixes-to-maintain)
- [Linux Build Rules](#linux-build-rules) · [Push And Publish Rules](#push-and-publish-rules) · [Development Rules](#development-rules)
- [`.dockerignore` Guardrail](#dockerignore-guardrail)

**Doing the work**

- [Quick Reference](#quick-reference) — the canonical build commands
- [Build Workflow](#build-workflow) — stage graph, prerequisites, expected outputs
- [Validation](#validation) — the preflight gate list, host config, disk reclaim
- [Version Bumping](#version-bumping) — `versions.env` first, then the sweep
- [Common Failure Modes](#common-failure-modes) — pointer into the symptom index

**Orientation**

- [Container Architecture](#container-architecture) — the stage table, both lanes
- [Repo Map](#repo-map) — what lives where, including the consumer surface
- [Code Organization](#code-organization-key-shared-utilities) — the shared helpers to use instead of hand-rolling
- [Dockerfile.media BuildKit Strategy](#dockerfilemedia-buildkit-strategy)
- [Reusable Sphinx Theme Package](#reusable-sphinx-theme-package) · [Documentation Maintenance](#documentation-maintenance) — the four docs gates, and why adding a dependency is a docs change

## Project priorities (owner directive — optimize for ALL THREE, always)

1. **Fastest possible build.** Cache-first engineering: BuildKit layer cache
   with narrow per-file closures, local cache exports, ccache wired end-to-end
   (and MEASURED — emit stats to stderr, the stream the 2MiB step-log clip
   never truncates), pinned buildkitd GC budget, parallelism levers
   (`GCC_PARALLEL_TARGETS`, `--parallel-archs`) taken when proven safe. The
   resource monitor showed peak CPU at 42% — idle cores are the standing
   wall-clock reserve. Speed that risks a silently wrong image is not speed
   (the `--no-push` handoff lesson): correctness bounds every shortcut.
2. **Maximum stability.** Digest-pinned handoffs, machine-checked ancestry,
   verified version pins (checksums from official sources), the five shell
   bug classes (§ Shell safety conventions) never reintroduced, and gates
   that FAIL LOUDLY — an assertion-free PASS ("will work at runtime") or an
   inner warning swallowed by an outer green is a defect, not a success.
3. **Many tests.** Every fix ships with a regression test where testable:
   unit suites under `linux/scripts/tests/` (auto-discovered by the
   pre-commit `script-tests` gate), lint gates (shellcheck, IFS-safety,
   hadolint, actionlint, ruff via `lint-python.sh`, gitleaks via
   `lint-secrets.sh`), preflight checks, and smoke assertions that assert
   real behavior against `versions.env` pins.
4. **Docs always follow the change — in the same work unit.** Any behavior,
   flag, workflow, or invariant change updates AGENTS.md (rules/quick-ref),
   README.md (user-facing pointers), the relevant `docs/` page, and
   `CHANGELOG.md` before the work is called done. A mechanism that only the
   git history knows about does not exist for the next session.

## Container Architecture

Three build lanes. Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows **host**:
`windows/amd64` only; Windows **targets**: `amd64` (image, production) and `arm64`
(cross-compiled artifact bundle — plumbing landed 2026-08-22 and the lane **BUILDS** since
2026-08-23; **nothing it produces has ever been RUN**, because Windows x64 has no ARM64 emulation,
so every arm64 signal is a static PE machine-type check. `build-buildkit.ps1 -TargetArch arm64`
just works: `torch` is dropped from the DEFAULT stage list with a notice (asking for it
**explicitly** still throws — it runs `uv sync`, which must execute the target interpreter).
Which components are through is tracked in the status banner of `docs/windows-cross-builds.md` —
do not restate it here, it moves).

> **Never publish the arm64 lane's output with `--platform windows/arm64`.** It
> is a cross build out of the same `windows/amd64` container and its product is
> an artifact bundle, not a runnable image; that flag yields a manifest nothing
> can run. Why no arm64 Windows container can exist, and the lane's current
> coverage: [`docs/windows-cross-builds.md`](docs/windows-cross-builds.md).
>
> **The base carries four arm64-only prerequisites, all installed UNCONDITIONALLY in the shared
> base** — never gate them on an arch ARG (that re-pays the chain's most expensive layers on every
> lane switch). They are warn-only in the base (`probe-arm64-prereqs.ps1` reports on all four); the
> GStreamer build **throws** on the ones it actually needs. `WINDOWS_ARM64_STRICT=1` promotes the
> base checks to hard gates, but it must be passed as a build-arg (`-BuildArg
> WINDOWS_ARM64_STRICT=1`; a host env var alone does nothing) and it never reaches `setup-vs.ps1`'s
> MSVC `lib\arm64` check (that RUN sits above the `ARG` declaration in `Dockerfile.base`). The
> prerequisite list, rationale and traps: `docs/windows-cross-builds.md`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` (stable apt deps only; copies no project scripts — stays cache-stable) |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:base` + `:cross-android-<arch>` | `:latest-cross-package-<arch>` |
| `Dockerfile.torch` | `:latest-cross-package-<arch>` | `:latest-cross-<arch>` |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | optional GPU layer (CUDA or MIGraphX) |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64`, or `:winarm64` under `-TargetArch arm64` — still a `windows/amd64` image, carrying an aarch64 artifact bundle; **never publish it with `--platform windows/arm64`** |

### Windows-Specific Naming

The Windows lane uses local intermediate tags (`local/kataglyphis:windows-base`, `local/kataglyphis:windows-sdk`, `local/kataglyphis:windows-toolchain`, the media fan-out branch tags `local/kataglyphis:windows-media-<branch>` for `media-core`/`media-litert`/`media-tvm` (plus `-builder` variants; see `Get-MediaBranchTag`), the merged `local/kataglyphis:windows-media`, and `local/kataglyphis:windows-torch` for the app stage) and publishes the final image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`. See `docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

**Build logs.** `--log-dir ./out/build-logs` is accepted by
`build-cross-chain.sh` and `build-cross-stage.sh` — the two that tee each stage
build (the Makefile wraps them). The other three orchestrators
(`build-cross-compiler.sh`, `build-runtime-manifest.sh`,
`build-runtime-artifacts.sh`) do **not** take it: pipe them through
`2>&1 | tee ./out/build-logs/<name>.log`.

**Stopping a chain.** Use `bash linux/scripts/stop-cross-chain.sh` — it finds
the run via its pidfile (falling back to a bracket-trick pgrep) and reaps the
orphaned nerdctl/buildctl subtree. **Never `pkill` the orchestrator**; that
orphans its children.

**Cache knobs — three distinct things, never conflate them:**

| Knob | What it actually does |
|---|---|
| `NO_CACHE=1` | disables ALL `--cache-from`, local **and** registry, for the whole chain |
| `RUNTIME_NO_CACHE=1` | `--no-cache` on only the runtime package+wrapper builds (`runtime-build-fns.sh`) — a targeted guarantee against BuildKit worker-cache reuse of a stale `COPY /opt/ffmpeg` layer |
| `CROSS_NO_LOCAL_CACHE_EXPORT=1` | stops **writing** the local buildcache, but still **reads** the registry inline cache |

**Verify the shipped BYTES, never the push.** `:latest-cross` shipped STALE five
times with every static gate and every smoke GREEN, because they all checked the
push rather than the content. `verify-shipped-wrapper.sh` now gates this
automatically in `build-runtime-manifest.sh`'s per-arch loop, before the manifest
is assembled; `WRAPPER_CONTENT_GATE=0` downgrades it to advisory. The saga, its
real root cause and the two bugs the re-ship flushed out are owned by
[`docs/cross-build-verification.md`](docs/cross-build-verification.md#verify-the-shipped-bytes).

**Three more knobs**, all detailed in
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § versions.env feature
toggles: `MEDIA_STRIP=0` turns off the media-prefix symbol-strip pass (default
ON; `--strip-all` keeps `.dynsym`, so runtime linking is unaffected), while
`VULKAN_CROSS_STRICT=1` and `WHEEL_SOABI_STRICT=1` promote two advisory WARN
gates to fatal — the second catches a vendored wheel whose native
`.cpython-*.so` carries a SOABI for the wrong arch, which otherwise fails only
at `import`.

Most common build commands:

```bash
# Full cross-build chain (base -> compiler -> sdk -> media -> android -> runtime)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Compiler image only (amd64-hosted, contains cross toolchains for all arches)
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64

# Compiler with custom image repo (matches --image-repo on the orchestrator)
./linux/scripts/build-cross-compiler.sh --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

# Single cross stage — the canonical way to rebuild one stage for one arch.
# Handles parent digest pinning, build-arg assembly, log capture, and push.
# See docs/linux-cross-builds.md § "Recommended: digest-pinned orchestrator".
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch arm64 --push --log-dir ./out/build-logs

# ⚠️ --no-push FULL-CHAIN runs are broken on OCI-worker hosts (this host):
# the FROM handoff resolves against the REGISTRY, silently building each stage
# on the last PUSHED parent (verified live 2026-08-08 — two runs lost). Use
# --no-push ONLY for single-stage validation:
bash linux/scripts/build-cross-chain.sh --only media --target-arches amd64 --no-push --log-dir ./out/build-logs
# Correct full-chain flow: push mode to android, then the runtime lane with
# --skip-manifest so a partial-arch run cannot clobber the public manifest —
# see docs/linux-cross-builds.md § "The flow that is correct today".

# Opt-in: build the per-target cross GCCs concurrently inside the compiler
# stage (~30% off the GCC RUN at 3 targets; default 0 = sequential).
GCC_PARALLEL_TARGETS=1 bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Verify chain freshness without building (real FRESH/STALE verdicts for images
# that carry the org.kataglyphis.parent-digest ancestry annotation)
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Partial runs (--from-stage after base) auto-assert the ancestor chain against
# the registry and REFUSE to build on a stale ancestor. Deliberate override:
#   --no-verify-ancestry   (or CROSS_VERIFY_ANCESTRY=0)

# Standalone quick chain verification (lighter, no orchestrator flags)
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64

# Print the full stage graph with tag names (no builds)
bash linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Dry-run: print all build commands without executing
bash linux/scripts/build-cross-chain.sh --dry-run --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot OR containerd restart (see § Prerequisites)
linux/scripts/setup-rootless-binfmt.sh --arches arm64,riscv64 --install-service
```

**Fresh Linux host?** GPU driver + CUDA install, the NVIDIA default-runtime `daemon.json`, CPU/GPU performance mode, and GRUB recovery are `docs/linux-host-setup.md` — the Linux counterpart to `docs/windows-host-setup.md`.

> **See also:** [`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) for the full stage graph, digest pinning, and single-stage build details. [`docs/linux-build-basics.md`](docs/linux-build-basics.md) for build fundamentals, caching, and troubleshooting.

### Windows Container Build

**Fresh Windows machine?** Follow
[`docs/windows-host-setup.md`](docs/windows-host-setup.md) rather than
reconstructing the sequence — after the interactive steps, the scriptable half
is one elevated `setup-new-host.ps1` run.

All stages use **Ninja + clang-cl + lld-link**. The container toolchain is
**containerd + BuildKit + nerdctl**. Role split — each tool where its pipe ACL
allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\build-buildkit.ps1` → `buildctl` | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` | **admin** |
| Publish / classic-lane ops | Stevedore's `docker.exe` | non-admin |

```pwsh
.\windows\build-buildkit.ps1 -Gpu          # build (non-admin)
```

**The lane mechanics live in
[`docs/windows-build-lanes.md`](docs/windows-build-lanes.md)** — isolation
policy and the probe-log trap, the sccache and RDNA4 and step-log preflight
gates, the BuildKit/containerd lane, the nerdctl lane, the classic lane's
run+commit path, mid-chain failure recovery, and the RDNA4 A/B history.

Four things an agent gets wrong without reading it:

- **The classic lane is NOT a fallback any more.** Twelve Windows Dockerfiles
  use BuildKit-only `RUN --mount`, so `build.ps1` cannot build `base`
  (measured 2026-08-21). Reviving it is a deliberate decision.
- **`nerdctl` needs an ADMIN shell** — containerd's pipe is Administrator-only
  upstream, and there is no `--group` equivalent. Do not attempt pipe-ACL
  hacks and do not re-litigate it.
- **Every Stevedore/containerd update reverts the patched runhcs shim.**
  `windows/scripts/host/deploy-shim-patch.ps1 -ReportOnly` belongs in your
  post-update routine.
- **A Stevedore REINSTALL wipes more than the shim** — the buildkitd service
  `Environment`, the dufs task and its serve directory all go with it. See
  [`docs/windows-host-setup.md`](docs/windows-host-setup.md) § Phase R.

See [`docs/windows-builds.md`](docs/windows-builds.md) § Build Commands for the
full build sequence.

### Running Linux containers (Rancher Desktop)

**Rancher Desktop is the preferred Linux-container runtime on this host**, and
the way to reproduce a Linux CI failure locally instead of guessing through
pipeline round trips. It does not replace the Windows lane — Windows containers
still go through Stevedore's `docker.exe`. Full details:
[`docs/rancher-desktop-linux-containers.md`](docs/rancher-desktop-linux-containers.md).

```pwsh
$nerdctl = "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
& $nerdctl --namespace default run --rm alpine:3.20 uname -a   # expect ...WSL2... x86_64 Linux
```

- **Use `nerdctl`, not `docker`.** Rancher defaults to the **containerd** engine,
  and `docker.exe` ships in the same directory while talking to a different
  engine entirely — `docker info` on this host reports `OSType=windows`, because
  the default context is the Windows lane. Both CLIs are present; only one is
  talking to Linux. (Switching Rancher's engine to `dockerd (moby)` flips this —
  pick one and stay with it.)
- Pass `--namespace default` explicitly. containerd namespaces are real
  isolation, so an image pulled into another namespace is genuinely "not found".
- **Linux builds use `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`,
  in CI *and* locally.** Not `:latest` — that tag went unrebuilt from 2026-04-16
  while the cross lane was refreshed (2026-07-20). Both publish amd64/arm64/
  riscv64. `python-ci-linux.yml` sets `CONTAINER_IMAGE` to `:latest-cross`; if a local run
  uses a different tag, reproducing a CI failure proves nothing. Neither tag is
  digest-pinned, so both still float.

### LLM Stack (Ollama + Open WebUI)

A standalone serving stack lives in `linux/llm-stack/` (docs in its own
README). CPU-only is the compose default; an opt-in GPU override
(`linux/llm-stack/docker-compose.gpu.yml`, `docker compose -f docker-compose.yml
-f docker-compose.gpu.yml up -d`) grants the Ollama service all NVIDIA GPUs and
raises `OLLAMA_CONTEXT_LENGTH`. **VRAM caveat:** the context Ollama lists is the
model's max, not what fits — ~19 GB of weights + ~104 KB/token q8_0 KV means a
28 GB stack (e.g. 12 GB + 16 GB GPUs) caps at ~64K, and 256K needs >45 GB VRAM.
Requires the nvidia-container-toolkit on any host that wants GPU mode.

### Triggering the opt-in CI lanes

The Linux x86 lane runs on every push; **Windows and ARM are opt-in per
commit** — and a green tick without the opt-in says nothing about them, because
the workflow reports `skipped`. Which markers, and what each lane runs:
[`docs/ci-build-triggers.md`](docs/ci-build-triggers.md).

```
git commit -m "build: check every target [build-win][build-arm]"
```

### Reading CI status with the GitHub CLI

**Check the pipeline after every push, and again before starting unrelated
work.** `gh` is installed (winget) and authenticated; see
[`docs/github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md).

```pwsh
gh run list --limit 10
```

To go from a run id to the failing STEP, use the `--jq` recipe in
[`docs/github-cli-pipeline-monitoring.md`](docs/github-cli-pipeline-monitoring.md)
— that page owns the query, so it is maintained in one place.

Three things that will otherwise cost you an hour:

- **A shell opened before the winget install cannot find `gh`.** Use a new
  shell, or `C:\Program Files\GitHub CLI\gh.exe`. Prefer PowerShell — Git
  Bash may not see winget's user PATH at all.
- **Never open with `gh run view --log-failed`.** It dumps every failed job's
  full log — one antlr4 `llvm-ar` line alone is ~15 KB — and grepping it for
  `error` mostly returns the runner's apt-get cleanup echoes. Ask which STEP
  failed first (command above), then grep the log for `SUMMARY:` (sanitizers)
  or `[  FAILED  ]` (GoogleTest).
- **`skipped` is not a pass.** Gated workflows (the Windows container build
  wants `[build-win]` in the commit message) report `skipped`, which reads as
  success at a glance.

Green local tests do not imply green CI: the Linux lane runs ASan/UBSan fuzzing
that the Windows dev box does not, so some bugs are only ever observable there.
Fix what failed — do not edit the workflow to silence it.

### Where does knowledge belong? (docs, not just code)

The reuse rules below are about code. The same discipline applies to **what you
write down**, and one question decides it:

> **Would this still be true in a different project?**

- **Yes** → it belongs here, and the consumer LINKS to it.
- **No** → it belongs in the consumer.

Most topics split down the middle. "Allow the `bindFlt`/`wcifs` filters on a Dev
Drive" is ours; "Dart's `copySync` fails on a bind mount" is
Kataglyphis-Inference-Engine's, because it only matters for a Flutter app.

**Link rather than restate** — restating has produced three broken copies of
one command before (the 2026-08-11 Dev Drive filter incident; the story lives
in [`docs/INDEX.md`](docs/INDEX.md)).

[`docs/INDEX.md`](docs/INDEX.md) maps topic → owning document. Consumers link
one hop through it, so reorganising docs here means editing that page instead of
hunting links across seven repositories.
[`shared/templates/AGENTS.md.template`](shared/templates/README.md) is the
consumer-side skeleton that keeps the split visible.

One caution against automating this: a keyword check ("this consumer doc
mentions wcifs") cannot tell *restating* from *applying*. Inference-Engine's
AddressSanitizer section legitimately discusses image-level runtimes, because
which ASan runtime a Flutter/COM app can survive is a property of that app. A
human has to read it.

### Contributing Reusable Work Here

Consumer projects are expected to push reusable work upstream rather than keep
local copies (BeschleunigerBallett's AGENTS.md states this as a rule).
Wiring a NEW project to this repo — submodule, module resolver, Windows and
Linux container builds, the agentic loop, launchers, CI actions — is a
checklist in [`docs/adopting-in-a-new-project.md`](docs/adopting-in-a-new-project.md);
read it before hand-rolling any of that in a consumer.

When adding here:

- PowerShell 7 (pwsh) is the standard shell. All `.ps1` scripts require `#Requires -Version 7.0`. Windows containers use pwsh as the default SHELL.
- PowerShell scripts go in `windows/scripts/modules/` with `Export-ModuleMember`, and
  consumers resolve it ContainerHub-first with a vendored fallback. The resolver
  itself is a copied template:
  [`shared/windows/templates/Resolve-BuildModule.ps1`](shared/windows/templates/README.md).
- **The two-consumer test.** If a second consumer needs it, it belongs here — not
  vendored twice. That test is what moved `WindowsTesting.Common` (test-exe
  discovery, ctest driving, scoped ASAN_OPTIONS, ASan-runtime discovery) and
  `WindowsClang.Common` (clang-tidy driving) upstream on 2026-08-11. When moving
  one, turn its project-specific values into parameters whose DEFAULTS preserve
  the original behaviour, so the vendoring consumer can delete its copy without
  any behaviour change.
- Document the **symptom**, not just the fix — platform traps here are found by
  recognising an error message, not by reading code.
- Keep functions free of consumer-specific paths, preset names and build
  directories; pass those in as parameters.

### Reusable Module: WindowsContainerBuild.Reuse

The container-reuse API consumers build on:
[`docs/windows-builds.md`](docs/windows-builds.md) § Reusable module: WindowsContainerBuild.Reuse.

### Building Projects Inside the Windows Image (performance)

Consumers building large projects in this image should read
[`docs/windows-container-build-performance.md`](docs/windows-container-build-performance.md)
before hand-rolling anything. The number that motivates it, measured on a
~690-object C++23 modules project: **9.6 s ninja / 44 s wall** for a no-change
incremental build against a reused container, versus **352-484 s** when every
build got a fresh one.

The rule that follows: **reuse ONE container**, recreating it only when the
image ID changes; stream sources in and executables/logs out, never the
intermediate build tree. Transport choice, the Dev Drive filter setup, and the
four traps that cost measurable time (bind mount slower behind a filesystem
filter, sccache useless on C++20/23 modules, a named volume unusable as a CMake
build dir, deep paths aborting tar transfers) are all in that page.


### Windows Build Invariants (do not regress)

44 load-bearing rules — pwsh discipline, the gates that must stay armed, probe
and log discipline, layer/scratch rules, lane and CNI rules, and the
build-input invariants — live in
[`docs/windows-build-invariants.md`](docs/windows-build-invariants.md),
grouped and individually linkable. **Read it before editing anything under
`windows/`.** Each entry carries the incident that produced it; a rule whose
evidence no longer matches the code is a bug in the rule.

The three most often regressed by someone who skipped that page:

- **pwsh 7 everywhere** — no `powershell.exe`, no `cmd` SHELL directives.
- **Every BK chain ends with a mandatory smoke gate** — `-SkipSmokeGate` is for
  chain iteration only, never for "it passed locally".
- **`versions.env` is the single source of truth** — never hardcode a version
  in a script or Dockerfile.

### TensorRT Setup (Optional)

TensorRT is **not downloaded automatically** — it needs an accepted NVIDIA EULA.
[`docs/windows-builds.md`](docs/windows-builds.md) § TensorRT setup owns the
staging procedure, the `current/` rationale and the reasoning behind each rule
below. The rules themselves:

- **OWNER DIRECTIVE: always take the NEWEST release.** Never resolve a
  pin-vs-zip mismatch by lowering `TENSORRT_VERSION` — stage a newer zip and
  delete the superseded one.
- Set `TENSORRT_ZIP_SHA256` in `versions.env` for the new zip. A stale hash
  failing the build loudly is intended.
- `TENSORRT_VERSION` must never derive a **filesystem** path or the runtime
  PATH; the tree is resolved from disk and normalised to `current`.
- **No zip staged is the NORMAL state of this host's GPU lane — do NOT
  re-harden the graceful skip into a fail-fast.** That was tried on 2026-08-04
  and reverted the next day.
- **A PRESENT zip fails CLOSED**: a half-extracted tree is a build failure,
  while an absent one is supported.

### Windows Build Notes

The Windows lane source-builds the media stack with Ninja + clang-cl + lld-link (exceptions: CPython via `PCbuild\build.bat` with the VS ClangCL toolset; FFmpeg via MSYS2 `make` with `--toolchain=msvc`; GStreamer via Meson; LiteRT-**LM** via Bazel/bazelisk, `build-litert-lm-bazel.ps1`): CPython in the toolchain stage; ONNX Runtime → ONNX GenAI → OpenCV → FFmpeg in media-core; LiteRT (Ninja) → LiteRT-LM (Bazel) in media-litert; TVM → IREE in media-tvm; GStreamer in the merge stage. **That is the amd64 chain.** On `-TargetArch arm64` all three media branches build since 2026-08-24 (TVM/IREE runtime-only; what a branch cannot build for the target is decided INSIDE the branch and shipped as an empty, marker-carrying tree — the driver-level `$crossBlockedBranches` refusal list was removed on 2026-08-25), and what each branch skips or names ABSENT inside the bundle (LiteRT-LM, the TVM/IREE compilers, the python packages that need the compilers) is owned by the status banner of `docs/windows-cross-builds.md` — do not restate it here, it moves. **Assemblers are the one place the "clang-cl everywhere" rule does not hold on amd64:** NASM-syntax kernels (FFmpeg since #119, libjpeg-turbo in OpenCV, openh264 in GStreamer) go through the pinned `nasm` — LLVM has no NASM-syntax assembler — and MASM-syntax sources split by what LLVM's `llvm-ml` can actually parse (#123, 2026-08-25/26): IREE's single trampoline `x86_64_msvc.asm` goes through `llvm-ml -m64` (`-m64` is load-bearing — llvm-ml assembles i386 by default and then rejects the `.seh_*` directives; proven on the cross lane's host tools), while **MLAS's x64 kernels stay on MSVC's `ml64.exe` by design** — measured on amd64 run 6: every MLAS `.asm` opens with `.xlist` (LLVM 22's MasmParser has no listing directives), `INCLUDE mlasi.inc` is not found (llvm-ml searches `-I` dirs only, ml64 also the includer's directory), and behind it sits the Windows SDK's MASM macro layer; the ORT configure log asserts ml64 so a drift stops at configure. On arm64 every assembly path is clang's integrated assembler. All version pins come from `linux/scripts/01-core/versions.env` — never restate versions here (the duplicated tables this section used to carry drifted, e.g. the GenAI/LiteRT-LM labels).

- **Per-library reference** (generator/compiler per component, EP/delegate flags, patch stacks, RAM budgets, fallback paths): the authoritative table is `docs/windows-builds.md` § Component Build Matrix.
- **Per-script reference** (every build/setup/verify and HOST-maintenance script, with flags, gotchas and refusal conditions): the authoritative table is `docs/windows-builds.md` § Windows Script Reference.
- Build sequence and commands: `docs/windows-builds.md` § Build Commands; container validation: § Smoke Testing there.

Update those tables in `docs/windows-builds.md` — this section stays a pointer. The Windows Build Invariants above remain here because they are agent-behavioral rules, not reference data.

### Orchestrator Stage Selection

Resume mid-chain, build one stage, or use `--parallel-archs`:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Orchestrator stage selection.

### Runtime Helpers

Wrapper builds, manifest publishing and manifest repair:
[`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) § Runtime lane helper commands.

---

## Build Workflow

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
```

Stages 1-5 run on `linux/amd64`. Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches), delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>` to prevent stale cache reuse. The stage graph is defined in `linux/scripts/01-core/stage-defs.sh`. See `docs/linux-cross-builds.md` for the full pipeline details.

The **Windows lane** follows a separate staged build (`base → [nvidia] → toolchain → media → torch → final`; torch assembles the Orchestr-ANT-ion app env, `local/kataglyphis:windows-torch`, and final builds FROM it) driven by `windows/build.ps1`, which uses Stevedore's `docker.exe` for builds (`nerdctl build` has broken DNS on Windows). The `windows-sdk` tag is either a plain re-tag of `windows-base` (CPU lane, default) or the NVIDIA GPU stage `Dockerfile.nvidia` (`-Gpu` switch) for a CUDA-enabled image. See `docs/windows-builds.md` § Build Commands for the full build sequence and prerequisites.

### Prerequisites

- **nerdctl** with BuildKit backend
- **QEMU/binfmt** for foreign-architecture runtime builds. Registration is lost
  on host reboot **and on `systemctl --user restart containerd`** (it lives in the
  rootlesskit namespace — that's how it silently vanished on 2026-08-08 after the
  shim-failure restart). On this rootless host the privileged
  `tonistiigi/binfmt --install` container does NOT work (wrong namespace); use:
  ```bash
  linux/scripts/setup-rootless-binfmt.sh --arches arm64,riscv64 --install-service
  ```
  `--install-service` installs a systemd --user unit so re-registration is
  automatic. Without registration, foreign-arch execs fail with `exec format
  error` — including wrong-arch NATIVE tool sub-builds inside "no-emulation"
  cross stages (the IREE tblgen failure mode).
- **Registry access** (GHCR) for pushing intermediate and final images
- **Disk space**: ~50GB+ for full cross chain with all architectures
- **Python 3** for digest resolution (`registry-digest.py`)

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **CNI nat conf (historical note)**: before 2026-08-03 `nerdctl run` failed on this host (no CNI `nat` **conf**) and `nerdctl build` had broken DNS, so docker.exe was the only working tool. Since 2026-08-03 `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` is installed (see `docs/windows-build-lanes.md` § Getting it going, step 2 — including the subnet-drift trap) and nerdctl works — from **admin** shells only (containerd's pipe is admin-only). Stevedore's `docker.exe` remains the classic-lane tool and needs no CNI plugin. Run with `--isolation process` for the host's full CPU count (Hyper-V isolation is capped at 2 CPUs). See `docs/windows-builds.md` § Running the Image.

### Stevedore Fixes After Install

Apply the post-install fixes documented in `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes (Defender exclusions, daemon.json cleanup, default runtime change, verification). Those instructions are the canonical source — keep them in sync instead of duplicating here.

### Supported Platforms

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |
| Windows cross lane | `windows/amd64` | `arm64` artifact bundle (clang-cl `aarch64-pc-windows-msvc`; **not** a container image) |

### Expected Outputs

After a successful `build-cross-chain.sh` run:
- All cross-lane intermediate images pushed to GHCR
- Per-architecture wrapper images (`:latest-cross-<arch>`) pushed to GHCR
- Multi-arch manifest (`:latest-cross`) pushed to GHCR

---

## Repo Map

```
linux/scripts/
├── 01-core/             shared utilities (59 as of 2026-08-14 — `ls linux/scripts/01-core/*.sh | wc -l`; the literal said 48 for long enough that README repeated it, so treat any count here as indicative: versions.env, logging, platform, cross-env, cross-gcc, cross-meson, cross-apt, compiler-resolution, tag-naming, stage-defs, digest-pinning, ancestry, build-helpers, cli-parsers, …)
├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
├── 03-media/            media library build scripts
│   ├── core/common.sh   single DRY bootstrap — sourced by every media script
│   ├── build/           per-library build scripts
│   │   ├── onnxruntime/   ONNX Runtime + GenAI (build/ steps, runtime/ pkgconfig, android/)
│   │   ├── litert/        LiteRT + TFLite C API (Critical Fix #2: abseil span.h copy in build-litert.sh)
│   │   ├── opencv/        OpenCV 5.x
│   │   ├── ffmpeg/        FFmpeg (build-ffmpeg.sh has fixed host compiler wrapper)
│   │   ├── gstreamer/     GStreamer monorepo (common/ has patch-gstreamer-sources.sh — Critical Fix #5)
│   │   └── libcamera/     libcamera
│   └── runtime/         artifact collection, runtime config, wheel repair, verification, media-env.sh (canonical ENV)
├── 04-runtime/          entrypoint + env scripts (gstreamer-env.sh, etc.)
├── 05-frameworks/       TVM, Torch, Flutter
└── 06-packaging/        assembly + smoke tests (smoke-media.sh, smoke-common.sh)
```

Top-level orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.

Beyond `linux/scripts/`:

```
linux/scripts/lib/       consumer-facing bash libraries: agentic-loop.sh,
                         app-runner.sh (generic app launcher: arg parse, exe
                         discovery, LD_LIBRARY_PATH, per-profile hooks),
                         cmake-build.sh, code-quality.sh, coverage.sh,
                         slang-compile.sh, wasm-opt.sh, ctest-run.sh (ctest
                         runner + perf-baseline comparator), docs-build.sh
                         (Sphinx build helper), rust-toolchain.sh — the last
                         three had NO doc entry anywhere until the 2026-08-08
                         orphan sweep; nothing in-repo invokes lib/, it is a
                         consumer surface shipped into the images
linux/scripts/02-toolchain/rust/   cargo_* helpers (test/bench/fmt+clippy/
                         security/coverage/release/update/doc via
                         _cargo_wrapper.sh) — consumer surface COPY'd into the
                         toolchain/sdk/package images; nothing in-repo calls
                         them (the redundant zero-ref Build-Linux.sh duplicate
                         was deleted 2026-08-08)
linux/scripts/02-toolchain/python/ci_*.sh   Python CI helpers (tests, static
                         analysis, packaging, docs) — same consumer-surface
                         status as rust/
linux/scripts/01-core/setup-host-deps.sh    hand-run host bootstrap (rootless
                         nerdctl/buildkit prerequisites); intentionally not
                         wired into CI or builds
linux/scripts/06-packaging/package_archive.sh   tar/deb/AppImage/Flatpak
                         assembly — consumer surface. Called from
                         Kataglyphis-RustProjectTemplate's
                         .github/workflows/rust_ubuntu24_04.yml release job.
                         Deleted by the 2026-08-08 orphan sweep as
                         "zero-reference" and restored 2026-08-11: the sweep
                         searched only THIS repo, so a consumer's CI lane was
                         broken silently. Grep the consumer repos before
                         deleting anything under lib/, rust/, python/ or
                         06-packaging/.
windows/scripts/         Windows lane, GROUPED since #108 (2026-08-20):
                         build/ (chain components: build-*-from-source.ps1,
                         *-all wrappers, smoke-test-container, load-versions),
                         host/ (setup-*/apply-*/repair-*/reset-* + elevated
                         maintenance), diagnostics/ (probe-*/test-* + the
                         run-diagnostic-probe runner; settled one-shots in
                         diagnostics/archive/, still runnable via
                         -ProbeScript archive/<name>.ps1). Container mounts
                         stay FLAT (C:\bkmnt, C:\temp\scripts) — the
                         $scriptAssetRoot resolver bridges both layouts and
                         is gated by ScriptAssetRoot.Parity.Tests.
                         Ungrouped residents BY DECISION (#131):
                         Invoke-Lint.ps1, entrypoint.cmd, cargo-retry.cmd
                         (consumer-CI suspect — never delete unverified),
                         certificates/ (MSIX cert generation + WebDAV
                         download_webdav_files.py — see its README.md),
                         python/ + rust/ (consumer CI-lane drivers).
                         modules/*.psm1 (reusable PS modules: SourceBuild,
                         Build.Common, ContainerBuild.Reuse, AgenticLoop,
                         CMake, Config, Formatting, Msix.{Common,Signing},
                         WebDav, Uv, Scripts.Shared, Toolchain, CodeQL,
                         ContainerImage, Flutter, Installer,
                         HostMaintenance, SmokeTest, GstPlugins, …),
                         tests/ (harness + suites), shims/
windows/upstream/        prepared upstream submissions (not build inputs):
                         hcsshim-teardown-timeout/ = ISSUE.md + PR.md +
                         format-patch making the shim teardown timeouts
                         configurable, plus the deployed 45min local patch
                         and the rebuild recipe (see its README.md);
                         sccache-nvcc-quote-fix/ = the 0003 diag-family
                         patch riding until mozilla/sccache#2816 merges
                         (0001/0002 merged upstream in #2811; the dir is
                         ALSO a build input — setup-rust-toolchain applies
                         0003 on top of the pinned rev)
shared/agentic-loop/     cross-platform data: prompts/*.md — the single source
                         for the default planner/refactor-planner/executor task
                         prompts read by BOTH WindowsAgenticLoop.Common.psm1
                         and linux/scripts/lib/agentic-loop.sh
.github/actions/         composite actions consumers call @main:
                         cleanup-disk-space (Windows runners),
                         run-in-linux-container, run-in-windows-container
                         (see .github/actions/README.md)
```

`out/`: generated build artifacts (OCI layouts, rootfs exports). Excluded from Docker context via `.dockerignore`.

## Shell safety conventions (five bug classes, all found live 2026-08-08)

Every one of these killed or falsified a real build before being fixed. The
full stories are in `CHANGELOG.md` (2026-08-08); `tests/test-ifs-safety.sh`
lint-gates class 3. When writing or reviewing bash in this repo:

1. **No `trap … RETURN` inside functions** — the trap survives the function and
   fires again on the CALLER's return, where the locals are gone (`set -u`
   abort AFTER a green run). Capture rc with `|| rc=$?`, clean up explicitly.
2. **Guard every pipeline whose empty result is legitimate** — `grep`/`find`/
   `ls`/`du`/`pgrep`/`dpkg -S`/`readelf` in `$(...)` under `set -euo pipefail`
   needs `|| true` when the code below handles the empty case. `find | head -1`
   additionally dies of SIGPIPE (rc 141) on multiple matches.
3. **Split comma lists with `IFS=',' read -r -a arr <<< "$list"`** — never
   `${list//,/ }` or `$(... tr ',' ' ')`: under a script's `IFS=$'\n\t'` those
   do not split and the loop runs once with the whole list as one bogus item.
   Sourced 01-core functions run under the CALLER's IFS. The two list helpers
   (`arch_list_to_words`, `smoke_arch_words`) emit NEWLINE-separated words
   since 2026-08-08 precisely so `for x in $(...)` splits under any IFS —
   keep that property if you touch them (test-smoke-arch-parity.sh pins it).
4. **Source vendor scripts (SDK setup-env, venv activate) with nounset
   suspended** — `case $- in *u*) …; set +u;; esac` … `set -u` after. LunarG's
   setup-env.sh reads `$1` unguarded.
5. **Never end a function with a bare `[ cond ] && action`** — the false case
   becomes the function's return value 1; under `set -e` the HEALTHY path kills
   the caller. End with `|| true`, `; return 0`, or an `if`.

## Caching discipline (do not regress)

Full map: `docs/linux-build-basics.md` § Caching Layers. Toggles: `USE_CCACHE`,
`USE_SCCACHE`, `USE_LLD` accept `0/false/no/off` to disable (since 2026-08-08 —
previously ONLY the literal `false` worked and `USE_CCACHE=0` was silently
ignored); `ENABLE_SCCACHE_RUST`/`ENABLE_SCCACHE_CUDA` are strict `0/1`.
The rules an agent must never violate:

1. **Closure freeze between runs that should cache-hit.** Editing ANY file in
   the base/toolchain closure changes the compiler image digest and forces
   sdk/media/android to rebuild from scratch on the next run. Since 2026-08-08
   (A1 applied, commit 5d7a318) **`Dockerfile.base` mounts a traced 15-file
   closure**, not whole directories — the closure is now: those 15 files
   (13× `01-core` + `cmake.sh` + `packaging-deps.sh`; the lists live in
   Dockerfile.base itself), `versions.env`, `python/build_python.sh`, the
   three bundled `06-packaging/smoke-*` scripts, `Dockerfile.base`,
   `Dockerfile.toolchain`. Editing 01-core files OUTSIDE those lists no longer
   busts base — but a file NEWLY needed by a base RUN must be ADDED to the
   per-file mount lists (closure = source edges + **exec/`bash` edges**; the
   A1 validation build caught exactly such a miss). Batch closure edits;
   apply them in ONE commit at
   a planned rebuild boundary. Files in a not-yet-started stage's closure are
   free to fix until that stage begins (each `nerdctl build` snapshots its
   context at stage start).
2. **`~/.config/buildkit/buildkitd.toml` pins the GC budget** (`gckeepstorage`)
   so the multi-hour layers survive between runs. Restart buildkitd only
   BETWEEN runs (`systemctl --user restart buildkit`), never while a build
   solves. Do not delete this file.
3. **The compiler-cache HYBRID is doctrine, keep it wired**: ccache for C/C++
   (GCC via `--ccache` in `gcc.sh`'s three `build-gcc.sh` call sites, LLVM via
   cmake launchers + the ccache/sccache cache mounts on BOTH heavy RUNs in
   `Dockerfile.toolchain`), sccache for Rust + the GPU
   compilers (`ENABLE_SCCACHE_RUST`, `ENABLE_SCCACHE_CUDA` — gated until
   validated; ccache can wrap neither rustc nor nvcc/hipcc, while sccache's
   plain-C/C++ path loses to ccache's direct mode). Never "simplify" to a single tool; see
   docs/linux-build-basics.md § Why the HYBRID. The failure mode
   this replaced (mount without wiring, wiring without mount) was invisible —
   builds stayed green, just slow. When touching these paths, verify with
   `grep -c ccache <stage>.log` on the next build.
4. **Never edit a running orchestrator's main script** (`build-cross-chain.sh`
   while a chain runs): bash reads it incrementally by byte offset; an edit can
   corrupt the in-flight process. Sourced library files are safe to edit for
   FUTURE runs (the running process holds them in memory) but see rule 1.
5. **The WINDOWS chain caches differently — do not assume rules 1-4 apply.**
   It relies on (a) deliberate layer ORDERING — `setup-vs.ps1` sits ABOVE the
   `versions.env` COPY in `Dockerfile.base` so a pin bump cannot re-pay VS
   Build Tools (confirmed live 2026-08-08: 4 of 16 base steps CACHED through a
   PYTHON_VERSION bump, and they were the expensive ones), (b) a five-file
   in-container module closure so host-only module edits cannot bust a compile
   layer, and (c) sccache. **Preserve (a) and (b) in any Dockerfile edit** —
   moving a COPY above the VS layer, or widening the module COPY, costs hours
   per bump.

   **Wired**, with the rules an agent must not break. Full rationale,
   measurements and decision history:
   [`docs/windows-build-resources.md`](docs/windows-build-resources.md)
   § Persistent compile cache (sccache).
   - **sccache runs WebDAV-remote-only since 2026-08-16.**
     `SCCACHE_MULTILEVEL_CHAIN` defaults to `""` in **both**
     `Dockerfile.media-builder`'s `common` stage and the merge builder (not a
     descendant, so the ENV is repeated — **change BOTH or neither**). Restore
     `disk,webdav` only after re-verifying against a newer buildkit.
     **`SCCACHE_DIR` alone does nothing** without the chain variable.
   - **sccache is BUILT FROM SOURCE at `SCCACHE_GIT_REV`** — load-bearing, not a
     preference. **Never bump that pin without checking the local patch series
     (`windows/upstream/sccache-nvcc-quote-fix/`) still applies**; the rust layer
     throws if it does not.
   - **`CMAKE_CUDA_COMPILER_LAUNCHER` is ON BY DEFAULT since 2026-08-18.** Never
     flip that default off silently, and never export the launcher onto a new
     sccache without all THREE canaries — the miscompile it once caused is
     invisible until the DLL link.
   - **uv/pip wheel cache** in `Dockerfile.torch`, set INSIDE the RUN (an `ENV`
     would bake a build-only mount path into the shipped image).

   Still NOT wired, with a measured reason: **source-fetch mounts.** The clones
   are shallow (`Invoke-GitClone` passes `--depth`), so they cost minutes
   against compiles that cost hours. If you do it, cache the ARCHIVES/CLONES
   only, never the working tree — directory RENAMES fail on cache mounts and
   `build-gstreamer-from-source.ps1` moves the extracted tree. Also raise the
   tier-0 `type==exec.cachemount` cap in `windows/buildkitd.toml` — it is
   **shared** by every cache mount plus local sources and git checkouts, and
   the sccache L0 (15G) and uv cache (10G) already claim most of it. Cache
   sizes and that cap are ONE decision, not two. (Since 2026-08-16 the L0 mount
   is attached but DORMANT — the chain defaults to WebDAV-only — so its 15G is
   reserved rather than consumed. Do not repurpose that headroom: the tier is
   meant to return, see #99.)

## Code Organization (key shared utilities)

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. Single source of truth — never use ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from canonical name + aliases with fallback. Use instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`. Use instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`. Bootstrap pattern for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`. Single DRY entry that sources the 01-core module framework. Every media build script sources this instead of duplicating a preamble block. (The old `media_build_preamble_init` alias no longer exists — zero callers and zero definition remain.)
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, runtime tag functions. Never construct tags manually.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`. Informational only — it prints digests, it does not gate a build.
- **Stage ancestry (gating):** `ancestry.sh` → `ancestry_output_annotations()`, `ancestry_recorded_parent()`, `ancestry_assert_chain()`. Every pushed cross stage records the parent ref it was built FROM as the OCI manifest annotation `org.kataglyphis.parent-digest`; a run with `--from-stage` after `base` walks that chain and HARD-FAILS when a parent was re-pushed after the child that would be inherited. Read path: `manifest-annotation.py` (annotations live in the base64 `Raw` field of `manifest inspect --verbose`). Absent annotation = warn (predates the mechanism); present + mismatch = fail. Escape hatch: `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`.
- **Cross-stage build:** `cross-stage-build.sh` → `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `cross_stage_assemble_runtime_helper_args()`.
- **Runtime flow init:** `runtime-flow-common.sh` → `init_runtime_flow_defaults()` (sourced directly by the two runtime scripts).
- **Retry logic:** `logging.sh` → `retry <max> <sleep> <desc> <cmd...>`.
- **Mirror args:** `build-helpers.sh` → `append_mirror_build_args_from_env()`.
- **Version forwarding:** `version-forwarding.sh` → `append_version_build_args()` (auto-discovers from `versions.env`).
- **CMake cache/linker:** `cmake-cache-linker.sh` → `append_cmake_cache_linker_args <array_ref>`. Sourced by `03-media/core/common.sh` automatically.
- **Install deps preamble:** `cross-apt.sh` → `install_deps_preamble [packages...]`.
- **Media ENV reference:** `03-media/runtime/media-env.sh` is the canonical definition of PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH/GI_TYPELIB_PATH. `Dockerfile.media` and `Dockerfile.package` ENV blocks must stay in sync with this file.
- **Media artifact verification:** `03-media/runtime/verify-media-artifacts.sh` validates each media build stage produced output. Called from `Dockerfile.media` RUN steps after every library build. Stages: `onnxruntime-cpu`, `onnxruntime-genai`, `onnxruntime-gpu`, `onnxruntime-pkgconfig`, `litert`, `litert-headers`, `opencv`, `opencv-core`, `ffmpeg`, `gstreamer`, `libcamera`, `app-wheels`, `media-inputs`.
- **Runtime stage elements:** `Dockerfile.torch` final stage is canonical for COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, OCI labels.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper (`BUILDKIT_HOST` support). Use instead of ad hoc `nerdctl build`.

### Module Loading Order

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `ancestry.sh` 7. `build-helpers.sh` 8. `cross-stage-build.sh` 9. `context-management.sh` 10. `version-forwarding.sh` 11. `cli-parsers.sh` 12. `runtime-build-fns.sh` 13. `compiler-resolution.sh` 14. `parallel-loop.sh` 15. `abseil-headers.sh` 16. `path-helpers.sh`.

`runtime-flow-common.sh` is sourced directly by `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` (after `artifact-common.sh`).

**Which loader a NEW script should use (the dual-loader rule):** scripts that
also execute INSIDE containers (bind-mounted or COPY'd — base-image, 02-toolchain,
03-media, 06-packaging) load via `modules.sh` / `source_module`, which resolves
both the repo layout and the `/opt/scripts` container layout. Host-only
orchestration (`build-cross-*.sh`, runtime flows) sources `artifact-common.sh`
directly. Do not mix: a container-capable script hard-sourcing repo paths breaks
at `/opt/scripts`. (Known wart: `modules.sh` hardcodes a `../02-toolchain`
search path — a 01-core file encoding stage-2 layout; fold a fix into any
future `modules.sh` touch. The layer order itself is frozen by
`tests/test-layer-order.sh`.)

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage does `FROM ${BASE_IMAGE}`: `base → compiler → sdk → media → android →
package → torch → wrapper → manifest`. The base-image handoff MUST NOT rely on a
bare mutable tag, or a stage can silently consume a STALE locally-cached image.

`--output type=image,name=...` does not reliably refresh the local containerd
tag; BuildKit's default `FROM` prefers an already-present local image. So
rebuilding `media` then building `android` can quietly reuse the old `media`.
**This is not just a `FROM` hazard — it broke the runtime wrapper's OWN tag.**
On this rootless nerdctl host, `nerdctl build --output type=image,name=X`
creates NO local tag X at all (verify: `--output type=image,name=X` → X absent
from `nerdctl images`; `-t X` → present). The runtime lane used the annotated
`--output type=image,name=<tag>,annotation.*` exporter to tag the wrapper, so
the freshly built wrapper was invisible and `nerdctl push <tag>` +
`nerdctl manifest create <tag>` resolved the STALE pre-existing tag — shipping
`:latest-cross` byte-identical five times (2026-08-14/15, amd64 frozen at
`35c1f1df`). FIXED: `runtime-build-fns.sh append_runtime_image_output` now uses
plain `-t` on both paths (reliably creates AND overwrites the tag). Do NOT
reintroduce the `--output type=image,name=` exporter for a tag you then push or
index — use `-t`. (The dropped ancestry annotations never reached the registry
anyway; re-embedding them is a tracked follow-up.)

Rules:

0. **The chain now checks this for you.** A run starting after `base` asserts the
   recorded ancestry of every stage it inherits (`01-core/ancestry.sh`) and
   refuses to build on a parent that was re-pushed after its child. Rules 1-4
   below describe what that check enforces and what its failure message asks you
   to do — they are no longer yours alone to remember. Bypass only deliberately,
   with `--no-verify-ancestry` / `CROSS_VERIFY_ANCESTRY=0`. Images built before
   this mechanism carry no annotation and only warn, so a chain that predates it
   still needs rules 1-4 applied by hand until each stage has been rebuilt once.
1. When ANY base image in the registry tag hierarchy is replaced, rebuild every
   downstream image from the replaced stage, OR verify the downstream images
   already contain the new content (e.g. check `/opt/gcc-16.2.0-native-arm64`
   exists in the pinned sdk digest).
2. `--from-stage` only controls where execution starts; it does NOT update the
   base image of the first stage. If the previous stage's tag was built from a
   stale upstream, your rebuild inherits that staleness.
3. After pushing a rebuilt compiler image, run from `--from-stage sdk` (not
   `media`) so the sdk is built from the new compiler.
4. Do NOT use `--from-stage android` unless you verified the media tag already
   contains the compiler's content (e.g. native GCC directories).
5. Prefer `linux/scripts/build-cross-chain.sh` — it captures each stage's
   registry digest after push and feeds it to the next as
   `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`, making stale reuse
   structurally impossible. Supports `--target-arches`, `--from-stage`,
   `--to-stage`, `--only`.
6. When driving manual `nerdctl` loops, pass `--pull=true` on every stage that
   consumes a `BASE_IMAGE` tag (weaker defense; digest pinning preferred).
7. Capture pinnable digests with `nerdctl manifest inspect --verbose <tag>` →
   `.Descriptor.digest` (the `registry_pin_ref` helper in
   `01-core/digest-pinning.sh`). Do NOT use `RepoDigests`: BuildKit pushes a
   converted `docker.v2+json` manifest whose digest differs from the local OCI
   manifest and is not registry-resolvable.

## Five Critical Fixes To Maintain

Always preserve these. The canonical reference is `docs/linux-cross-builds.md` § "Five Critical Fixes"; CI validates them via `linux/scripts/verify-critical-fixes.sh`.

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl`/`ctr` commonly fail with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working.
- `build-cross-compiler.sh` builds one `linux/amd64` compiler image with cross toolchains for all arches. Not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images must keep source-built `clang 22.1.8` (not Ubuntu `clang 22.1.2`). Source-built GCC (`GCC_VERSION`, currently 16.2.0) at `/opt/gcc-${GCC_VERSION}` is the default `cc`/`c++` on all arches. On `arm64`/`riscv64`, GCC is cross-compiled (Canadian cross) and swapped in at the Android stage via `Dockerfile.android`.
- **Supply-chain discipline (audit 2026-08-08).** Every network fetch is verified: trust anchors (CUDA keyring, ROCm key), toolchains (Vulkan SDK, Android cmdline-tools, Flutter, rustup/uv installers) and header tarballs carry sha256 pins in versions.env; `download_verified_file` is the default fetch, `download_file` needs a reason. Python **build executors** (meson/ninja/cython/pybind11/setuptools/wheel/auditwheel/patchelf — anything that runs code at build time or rewrites shipped binaries) are pinned via the `PY_*_VERSION` family; bump them TOGETHER, deliberately, with a real build — never let an install site float back to `-U pkg`. Never `curl | sh`; clone at tags with `--depth 1 --branch` and hard-fail on a missing tag rather than falling back to a branch.
- Preserve optional runtime payloads and LLVM normalization in `Dockerfile.package`. Do not drop `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Dockerfile.media BuildKit Strategy

`Dockerfile.media` uses a parallel multi-stage DAG (BuildKit runs independent stages concurrently):

```
base ─┬─ onnxruntime ───────┐
      ├─ litert ────────────┤
      ├─ opencv ────────────┼─ media-inputs ─ gstreamer ─ libcamera ─ final
      ├─ ffmpeg ────────────┤
      └─ app-wheelhouse ────┘
```

- `--mount=type=cache` (apt/ccache/sccache/uv/pip/cargo) keyed per-arch via `id=...-${TARGETARCH}`, `sharing=locked`.
- `--mount=type=bind,readonly` for per-library build scripts — no COPY layer, so editing one library's scripts invalidates only that RUN, not downstream layers.
- `--mount=type=tmpfs` for `/tmp` scratch (no layer bloat).
- `COPY --link` for layer-parallel copying from independent build stages.
- Shared/common files (`core/common.sh`, `activate-cross-python.sh`, `verify-media-artifacts.sh`, 01-core helpers) are COPY'd in the `base` stage (rarely change → stable cache).
- Runtime scripts are COPY'd only in the `final` stage (must persist in the published image; build scripts are NOT shipped).

## Push And Publish Rules

- `build-runtime-artifacts.sh --push` pushes only final per-arch wrapper images.
- `build-runtime-manifest.sh --push` pushes wrappers + final manifest.
- `--push-all` only when explicitly requested (publishes `base`/`package` intermediates).
- Final cross release: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Before rebuilding expensive foreign-arch wrappers, inspect remote tags with `nerdctl manifest inspect`. If wrappers exist remotely, recreate the manifest directly instead of rebuilding.

## Validation

- **`bash linux/scripts/preflight.sh` is the single source of the no-build gate
  list.** The authoritative check inventory is its `KNOWN_SLUGS` array (do NOT
  enumerate it here — this very paragraph went stale by three slugs once);
  `tests/test-preflight-slugs.sh` enforces that every slug has a registered
  check and vice versa. Newest additions: `python-lint` (ruff, hard on
  real-error classes, advisory rest), `secret-scan` (gitleaks, enforcing,
  false positives via `.gitleaksignore` with justification), `stage-graph`.
  CI workflows and `.githooks/pre-commit` run SUBSETS of it via
  `PREFLIGHT_ONLY=<slugs>` / `PREFLIGHT_SKIP=<slugs>` — never copy the check
  list into a new caller.
  On Windows hosts: `PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh`.
- **Linux host config is code**: `linux/host-config/` carries the canonical
  rootless-BuildKit `buildkitd.toml` (gc keep-budget + cachemount-sparing
  gcpolicy pair + max-parallelism) and the systemd drop-in.
  `apply-host-config.sh` installs (refuses while a chain runs; daemon restart
  is a printed operator step), `verify-host-config.sh` warn-diffs live vs
  repo. Exists because a live-only toml edit silently regressed once —
  reconcile drift through the repo, never by editing `~/.config` alone.
- **Linux disk reclaim: `linux/host-config/prune-safe.sh`, NEVER
  `nerdctl builder prune -f`** (CACHE1, 2026-08-17). The -f prune deletes
  `type==exec.cachemount` records — ccache/sccache/uv/cargo/llvm-src, hours
  of compile time in a few GB — together with the cheap-to-regenerate layer
  cache (measured 207 GB vs 4.9 GB); one run paid ~1.5-2 h of cold LLVM
  rebuilds for it. prune-safe.sh prunes `type==regular` only via buildctl's
  `--filter` (nerdctl has none), takes `PRUNE_KEEP_GB`/`DRY_RUN`, and proves
  cachemount survival before/after. Battle-proven through wave-4: 12
  invocations, ~1 TB reclaimed, 0 cachemount losses. Mid-run, use
  `PRUNE_KEEP_GB>=100` — smaller budgets evict the IN-FLIGHT lanes' fresh
  layers and buy recompile churn; the kata-buildcache media slugs
  (rewritten every round) are the better lever when the store runs lean. Mid-run lever ORDER:
  (1) prune-safe.sh, (2) `nerdctl rmi` of specific already-pushed tags
  (refuses in-use ones — safe), (3) `nerdctl system prune` NEVER while a
  chain runs — "unused" means not-container-referenced, so it deletes TAGGED
  cross-stage locals too (2026-08-18: cross-media-* vanished mid-run; the
  registry-digest-pinned handoffs survived via re-pull, costing ~25 min).
- **ghcr REGISTRY hygiene: `linux/host-config/ghcr-prune-package.sh`**
  (2026-08-24). The container package accumulates one untagged version per
  re-pushed moving tag; it had grown to 771 versions (~85% dead). NEVER
  "delete all untagged" by hand — the per-arch entries of a multi-arch index
  are themselves untagged manifests, and a chain that is pushing creates
  untagged manifests seconds before tagging them. The script's keep-set is
  tags + every index CHILD (resolved live, abort on any unresolvable tag) +
  the digest each tag currently resolves to + everything younger than
  `KEEP_DAYS` (default 7). Dry-run by default; `GHCR_PRUNE_CONFIRM=1`
  deletes, re-checking each version's tags immediately before its DELETE.
  First confirmed run: 604 deleted, 0 failed, `:latest-cross` + all
  cross-stage tags verified 200 afterwards, running build untouched. Known
  pre-existing damage it did NOT cause: legacy tags android/compiler/latest/
  media/sdk/torch were already dangling (children 404) before the tool
  existed.
- **HOST DISK RECLAIM IS ALLOW-LISTED AND DEFAULT-DRY —
  `windows/scripts/host/free-disk-space.ps1`, and NOTHING ad hoc** (2026-08-21,
  the worst incident this repo has produced). A "let's free some space"
  command was composed on the spot, handed over for an elevated shell, and did
  not stop at the container stores: it walked into the installed programs and
  the user profile and took the host with it — editor, VCS, GPU driver stack,
  container runtime, the PowerShell 7 this repo's whole gate suite needs, all
  reinstalled by hand. Nothing in the loop said no, because a blanket delete
  rule had been allow-listed in `.claude/settings.local.json`. The rules now:
  - **The reclaim script is the only sanctioned path.** It cleans exactly the
    regenerable classes — unused container layers (via the daemon's own GC),
    dead `*.bak-<stamp>` store husks, user + Windows TEMP, rotated host logs,
    repo `out/` scratch — resolved from an ALLOWLIST, reports by default, and
    needs `-Apply` to touch anything. Every live-directory rule is AGE-GATED
    (`-TempOlderThanDays`, default 7) so nothing in flight is deleted. It
    aborts the WHOLE run — not just the one target — if any resolved candidate
    lands on a protected root, because a candidate that lands there means the
    resolution logic is wrong and the rest of the plan is untrustworthy too.
  - **A name is not a target.** A candidate containing a junction or symlink is
    skipped: every path check reasons about names, and a reparse point is
    exactly where a name stops predicting what a recursive delete reaches — a
    cleared candidate could otherwise tunnel straight into the profile.
  - **The compile caches are NOT cleanup targets.** sccache/ccache/cargo/uv
    read as "cache" and are the most expensive bytes on the disk (CACHE1: a
    prune once traded ~1.5–2 h of cold LLVM rebuilds for a few GB). The
    reclaim script never lists them, and neither should you.
  - **Daemon levers before filesystem levers, always.** `buildctl prune
    --free-storage`, `docker image prune`, the store-GC sequence in
    `docs/windows-build-lanes.md` § Store GC. They hand back far more and they know
    what is still referenced. Filesystem reclaim is a last resort limited to
    dead `*.bak-<stamp>` husks.
  - **Protected roots are OFF LIMITS to the agent, permanently**: `C:\Program
    Files`, `C:\Program Files (x86)`, `C:\Windows`, `C:\ProgramData` outside
    the container stores, any user profile under `C:\Users`, `AppData`,
    per-user tool directories (`.vscode`, `.ssh`, `scoop`, `.claude`), drive
    roots, and every installed-package or driver store. Not with a flag, not
    with a force switch, not "just this once". Space that only comes back by
    reaching in there is a reinstall, not a cleanup — and it is the user's
    call, run by the user, outside the agent.
  - **Uninstalling the user's software is never the agent's move.** No package
    manager removals, no MSI removals, no appx removals. Suggest, never do.
  - **The gate is mechanical, not advisory.**
    `.claude/hooks/guard-destructive-deletes.ps1` runs as a `PreToolUse` hook
    (registered in both `.claude/settings.json` and the user-level settings, so
    one broken path cannot silently disarm it). It DENIES — a decision no
    prompt can override — any command touching a protected root, and it scans
    file CONTENT on Write/Edit too, because the 2026-08-21 vector was a script
    written for the user to paste, not a command the agent ran. Outside the
    protected roots it downgrades to a prompt rather than a block.
    `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1` is the incident
    in executable form; it also fails if a settings file ever re-introduces a
    blanket delete permission. If a guard regex ever needs relaxing, that is a
    reviewed repo change with a test — never a bypass in the moment.
- PowerShell gate: `pwsh -File windows/scripts/Invoke-Lint.ps1` +
  `pwsh -File windows/scripts/tests/Invoke-Tests.ps1` (also run in CI by
  `.github/workflows/windows-scripts.yml` on windows-latest). The suite is
  zero-dependency and guards *classes* of defect, not just instances — e.g.
  `Driver.ClosureScope.Tests.ps1` walks the AST of both drivers and fails any
  `.GetNewClosure()` block inside a function that reads a top-level `param()`
  variable, because that silently resolves to EMPTY and broke the scripted
  resume for months (backlog #40). Same shape elsewhere:
  `Dockerfile.EolAttributes.Tests.ps1` walks the real COPY instructions and
  fails any COPY-reachable file with no frozen git EOL attribute (#55);
  `Patches.CmakeNoOpGuards.Tests.ps1` fails unguarded source rewrites (#56);
  `Pins.CanonicalValues.Tests.ps1` pins CUDA_ARCHITECTURES at versions.env
  itself rather than at a code fallback the real build path never reaches, and
  compares every merge-builder ARG default against the pin (#58, #60). Each
  carries a rot guard so a moved target cannot make it pass vacuously.
  When you fix a bug here, prefer a guard for its class.
  Note the linter also exits **2** for an INFRASTRUCTURE failure — PSScriptAnalyzer
  1.25.0 throws intermittently (~2 in 9 runs) and an exception is not a finding;
  files are retried once and never silently skipped (#82). And CI currently runs
  the linter WITHOUT `-FailOnAnalyzer` while `main` is not branch-protected, so
  this gate is advisory (backlog #59).
- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs` (absolute symlinks resolve against host root).
- Confirm on all arches: `clang --version` reports `22.1.8`; `cc -dumpmachine` matches arch; `gcc --version` reports `16.2.0`; symlinks `cc/c++/gcc/g++ → /opt/gcc-16.2.0/bin/*`; `clang → /usr/local/llvm-target/bin/clang`; optional runtime payloads present.
- Use the `wrapper-smoke` target (see `docs/linux-build-basics.md`) for cheaper packaging validation before large publish runs.

## Common Failure Modes

Symptom → cause → fix for 35 failures seen live on both lanes, keyed by the
error message you actually get:
[`docs/failure-modes.md`](docs/failure-modes.md). Grouped as Linux/cross-lane ·
the Windows layer store (hcsshim) · container networking (CNI) · buildkitd and
the store · Stevedore and the docker service · build content and toolchain.

**Three reflexes that page encodes — worth holding before you need them:**

1. **Check free disk FIRST** on any weird hcsshim failure. Disk exhaustion
   wears three different costumes and only one of them names the disease.
2. **Prefer letting a doomed solve fail cleanly over killing it.** A clean
   finalize failure leaves no debris; a `buildctl` kill mid-finalize
   manufactures the deterministic `0xb7` that then costs a `-NoCache` re-run.
3. **After ANY red finalize, REBOOT before further A/B tests.** A wedged hcs
   state falsifies every experiment run after it.

---

## Version Bumping

**Single source of truth: `linux/scripts/01-core/versions.env`.** Update it first.

**Automated sweep: `python3 docs/scripts/bump_versions.py`** (report), `--write` (safe tier), `--write-all` (report tier + paired checksum extras — extras MUST be applied together with the version, see the CUDA-hash incident note in the script). Three tiers: SAFE / REPORT / MANUAL, plus a self-audit for unclassified keys.

**`bump:hold` marker:** a comment line containing `bump:hold <reason>` directly above a `KEY=` in versions.env blocks ALL automated writes for that key (reported as `HELD`). Use it for pins that are **slaved to another project's internals**, not independent software — e.g. `PROTOC_VERSION`/`PROTOBUF_VERSION` must match LiteRT-LM's internal `protobuf.cmake` pin (auto-bumping protoc to latest shipped gencode its runtime `#error`s on, 2026-08-03). Re-derive held keys manually when their master pin moves.

`common.sh` and `artifact-common.sh` source `versions.env` at load time with `set -a`. Per-Dockerfile ARG defaults are safety nets and should match.

After changing versions:
1. `python3 docs/scripts/sync_versions.py --write` (one pass now syncs Dockerfile
   ARGs BEFORE regenerating the snapshot — no second pass needed; `--check` to verify)
2. `python3 docs/scripts/generate-website-licenses.py --write` (regenerate website /openSourceLicenses page)
3. **Refresh the matching `*_SHA256` pins in versions.env** (pwsh zip / git installer /
   nuget / CUDA / cuDNN / ollama / binaryen / hadolint / actionlint — each key's comment
   documents its fetch command; GitHub releases expose per-asset digests on
   `https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>`)
4. Update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`, and `AGENTS.md`
5. Verify ARG consistency: `bash linux/scripts/01-core/verify-arg-consistency.sh`
   (also enforces that every versions.env-named ARG has a safety-net default in its file)
6. Rebuild affected stages (base→tooling, compiler→sdk, media→libs, android→SDK/NDK)

Windows LLVM bump note: bumping `LLVM_WINDOWS_VERSION` also requires adding the
new version's SHA256 to `$llvmSrcSha` in `build-tvm-from-source.ps1` (the #47
mini-LLVM heal pins the llvm-project source tarball per version and THROWS on
an unknown one — deliberately, unpinned downloads are forbidden).

Windows layer-cost note: `windows/Dockerfile.base` declares `VULKAN_VERSION`/
`CMAKE_VERSION` just above the scoop step (NOT at the top) so bumping them
re-runs scoop, never the hours-long VS Build Tools layer. Keep new version ARGs
below the VS layer unless they are consumed above it. Same trap for modules:
`WindowsScripts.Shared.psm1` (plus `WindowsContainerImage.Common.psm1` and
`WindowsInstaller.Common.psm1`) sit in `Dockerfile.base`'s PRE-VS module COPY —
editing any of them re-pays the VS Build Tools layer, so batch such edits
deliberately.

GPU constraints: when bumping CUDA/ROCm/MIGraphX, verify driver requirements and that `UBUNTU_CODENAME` ARG in `Dockerfile.amd` matches a supported Ubuntu codename (default `resolute`/26.04). MIGraphX packages currently come from the AMD ROCm noble (24.04) repo since no resolute builds exist yet.

## Development Rules

- Every script: `#!/usr/bin/env bash` + `set -euo pipefail`. Use `run()`/`run_quiet()` from `build-helpers.sh`.
- Source `artifact-common.sh` for shared utilities. Use `parse_shared_orchestrator_args()`/`parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` before the build loop.
- Use centralized helpers: `resolve_arch_list()`, `is_dry_run()`, `append_mirror_build_args_from_env()`, `append_version_build_args()`, `normalize_target_arches()`.
- New OS packages → `Dockerfile.base`. Compiler changes → `Dockerfile.toolchain`. SDK/frameworks → `Dockerfile.sdk`. Media libs → `Dockerfile.media` + `03-media/build/`. Android → `Dockerfile.android`. GPU → `Dockerfile.nvidia`/`Dockerfile.amd`.
- New architecture: add to `CROSS_DEFAULT_ARCHES` in `versions.env`, update cross-target lists, add triple mapping in `platform.sh`, add checksums in `versions.env`, verify QEMU/binfmt.

## `.dockerignore` Guardrail

**Never exclude the `linux/` directory from `.dockerignore`.** The Linux Dockerfiles
(`Dockerfile.base`, `Dockerfile.package`, `Dockerfile.torch`, etc.) use `COPY`
instructions that reference files under `linux/` (scripts, Vulkan manifests,
smoke-test scripts, etc.). A blanket `linux/` exclusion breaks every COPY step
with `failed to compute cache key: ... not found`.

Windows build contexts are sufficiently small already (they only reference
`windows/`). If the Windows lane needs a smaller context, add specific excludes
for large directories under `linux/` (e.g., `linux/out/`, `linux/build/`) rather
than blocking `linux/` itself.

`linux/.dockerignore` is a SEPARATE allowlist for builds whose context is
`linux/` (the compose-built webserver image): it admits only
`webserver/{nginx.conf,entrypoint.sh,dist/,license-assets/}`. `webserver/dist`
must stay INCLUDED there — the root file's `**/dist/` exclusion applies only to
root-context builds and must not be copied over.

## Reusable Sphinx Theme Package

The shared theme and its `conf.py` snippet:
[`docs/project-info.md`](docs/project-info.md) § Reusable Sphinx theme package.

## Documentation Maintenance

- **Pre-commit hooks:** Run `git config core.hooksPath .githooks` once after clone. The `.githooks/pre-commit` script runs version-staleness checks, arg consistency, shell syntax, and the three docs gates below — the same checks CI enforces.
- **Four gates guard the docs; none of them is optional.** They exist because
  this tree lost a licence page, a doc index and ~50 cross-references to silent
  drift on a single day. Run them with
  `PREFLIGHT_ONLY=doc-links,doc-dupes,sbom,version-snapshot bash linux/scripts/preflight.sh`.
  - `doc-links` — every relative link, deep-link anchor, `file.md § Heading`
    prose reference, and index coverage against BOTH `docs/INDEX.md` and the
    Sphinx toctree. **Rename a heading and this fails**, which is the point.
  - `doc-dupes` — a passage copied into a second page. Deliberate rule-page /
    mechanism-page overlap is budgeted in `docs/scripts/doc-dupes.allow`, which
    also fails when an entry goes stale, so it cannot decay into a blanket
    exemption. **Do not add an entry to silence a finding**; give the passage one
    owner and link to it. `docs/INDEX.md` decides which page owns what.
  - `sbom` / `version-snapshot` — the generated licence pages and the curated
    SBOM must match `deps.json` + `versions.env`.
- **Adding a dependency is a docs change.** A new component needs an entry in
  `docs/deps/deps.json` with an `spdx` id, and — if that licence is copyleft — a
  `source` block, or the build fails. If this repo patches it, a `modified`
  marker too. The procedure, schema and worked examples are
  [`docs/third-party-licenses.md`](docs/third-party-licenses.md) § Maintaining
  this list. Regenerate with `sync_versions.py --write` and
  `generate_sbom.py --write`.
- **Never hand-edit a generated block.** The licence tables, the version
  snapshot and `docs/deps/sbom-curated.spdx.json` are all rewritten from
  `deps.json` + `versions.env`; edits between the `generated:` markers are lost
  on the next run and the gate will say so.
- If Dockerfiles or Linux helpers change, update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`.
- If Windows Dockerfiles/scripts change, update `docs/windows-builds.md`.
- If version defaults change, run `python3 docs/scripts/sync_versions.py --write` then `python3 docs/scripts/generate-website-licenses.py --write`.
- The canonical `custom.css` lives in the DocumANTation submodule at `external/Kataglyphis-DocumANTation/sphinx-kataglyphis-theme/sphinx_kataglyphis/_static/css/custom.css` — change it there (and commit in that repo). `docs/_static/css/custom.css` is only for per-project overrides. Run `cd docs && make html` to verify.

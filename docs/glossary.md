<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Glossary

These words have a fixed meaning in the family's docs. Most of them have more than one sense, and
each sense links to the page that owns it. A word that is not listed here means what it means in
plain English.

## admission

The checks a step must pass before it may start.

- Launch admission: a local build, export or stage starts only on an idle host, with fresh image,
  unit and output names, the qualified parent and source, and enough free disk. If one check fails,
  the stage does not start. See
  [local-proof-workflows.md § Default amd64 Media admission](local-proof-workflows.md#default-amd64-media-admission).
- Chain storage admission: the Linux cross chain checks free disk before it starts. When space is
  short, it trims old cache exports first. See
  [build-cache-tiers.md § 3.1](build-cache-tiers.md#31-preflight-trim-d4-and-the-salvage-disk-gate-d5).
- Compile admission: the compile governor lets one more compiler process start. The first slot
  always may; any other slot may only while enough memory is free. See
  [build-parallelism-memory-tuning.md § The compile governor](build-parallelism-memory-tuning.md#the-compile-governor).

The disk part of an admission is also called the disk floor.

## census

A tool's count or list of everything of one kind. The scanners share the name, but they are
separate tools.

- ORT census: finds every ONNX Runtime library and wheel in an image, an app bundle or a Python
  environment. Each one must be the chain's build, byte for byte, and every importer must load it.
  See [onnxruntime-single-source.md § The guards](onnxruntime-single-source.md#the-guards).
- Warning census: a committed file with the number of compiler warnings in the repository's own
  code, per CI lane and warning flag. A count that rises fails the lane. A count that falls fails
  until its row is lowered. See [code-quality-tooling.md § The warning census](code-quality-tooling.md#the-warning-census).
- Doc-prose census: the committed prose rates of each page. It works like the warning census. See
  [code-quality-tooling.md § Doc prose](code-quality-tooling.md#doc-prose-doc-prose).
- Dead-function census: `verify_dead_functions.py --census` lists the shell functions whose "dead"
  verdict cannot be trusted. It is a watch list and always exits 0. See
  [code-quality-tooling.md § --census](code-quality-tooling.md#--census-the-per-file-pass-and-why-it-is-advisory).
- Workflow census rows: `CENSUS | <repo> | <check> | <count> | <reason>` rows freeze the findings of
  a workflow check that is not enforced yet. See
  [code-quality-tooling.md § Four fleet workflow conventions](code-quality-tooling.md#four-fleet-workflow-conventions-workflow-lint).

## chain

- Image chain: the ordered image build stages, each built `FROM` the stage before it, so a rebuild
  repeats only what changed. "A chain" is also one run of that sequence. See
  [overview.md § Linux Image Chain](overview.md#linux-image-chain) and
  [project-info.md § Windows Image Chain](project-info.md#windows-image-chain).
- Built by the chain: a library or wheel the image chain builds from source instead of
  downloading it. "The chain ORT" is the one ONNX Runtime every consumer uses. See
  [onnxruntime-single-source.md](onnxruntime-single-source.md).

A lane is the route or the job; a chain is the ordered stages a lane builds.

## closure

The complete set of things something needs, found by following every reference.

- Runtime library closure: every shared library an executable or package needs to load. Packaging
  walks the imports and copies the libraries into the package, so it runs on a clean machine. On
  Linux this is the ELF closure, on Windows the DLL closure. See
  [linux-build-basics.md § The ELF closure walker](linux-build-basics.md#the-elf-closure-walker) and
  [windows-cross-builds.md § Consumer cross lanes](windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml).
- File closure: the exact files a build step or tool reads, its imports included. An image build
  step mounts only its own closure, so an edit elsewhere keeps its cached layer. A copied tool
  carries its whole closure. See
  [shared-script-libraries.md § Selected script closures](shared-script-libraries.md#selected-script-closures).
- Dependency closure: a Python package and everything it depends on. See
  [riscv64-venv-parity.md](riscv64-venv-parity.md).
- Licence closure: the licence texts and notices for everything linked into a shipped binary. See
  [third-party-licenses.md](third-party-licenses.md).

## companion

A helper file that a script, module or test loads and that must be copied beside it: a shell
library, a Python or PowerShell module, or a fixture. A missing companion fails the caller at once.
The caller never falls back to a private copy of the code. See
[shared-script-libraries.md § The logging bootstrap](shared-script-libraries.md#the-logging-bootstrap).

## floor

A lower bound that a check enforces.

- Count floor: the fewest passed tests, inspected files or found matches a gate accepts. A step that
  silently does nothing then fails instead of passing. See
  [windows-builds.md § Smoke Testing](windows-builds.md#smoke-testing).
- Coverage floor: the lowest code coverage a test lane accepts. See
  [code-quality-tooling.md § The Dart coverage floor](code-quality-tooling.md#the-dart-coverage-floor).
- Disk floor: the free disk a build host must keep. Below it the chain prunes cache or refuses to
  start a stage. See [build-cache-tiers.md § 3.1](build-cache-tiers.md#31-preflight-trim-d4-and-the-salvage-disk-gate-d5)
  and [windows-build-resources.md § The Windows cache, tier by tier](windows-build-resources.md#the-windows-cache-tier-by-tier).
- ISA floor: the oldest CPU the built binaries run on, set by the instruction-set baseline. On
  amd64 that is x86-64-v3, with AVX2. See [amd64-x86-64-v3-baseline.md](amd64-x86-64-v3-baseline.md).
- Version floor: the lowest version of a tool or SDK that a project accepts, such as the
  `environment: sdk:` line of a `pubspec.yaml`.

## lane

A route that work takes.

- Build lane: one route through the image build, named by OS, host, variant or architecture: the
  Windows lane, the cross lane, the nvidia lane, the arm64 lane. See
  [overview.md § Linux Image Chain](overview.md#linux-image-chain).
- Runtime lane: the last part of the Linux build. For each architecture it builds, smoke-tests and
  pushes the package and wrapper images. See
  [linux-cross-builds.md § Runtime lane helper commands](linux-cross-builds.md#runtime-lane-helper-commands).
- Windows engine lane: the tool that builds the Windows image. BuildKit with containerd is the only
  build driver; the classic docker lane is retired. See [windows-build-lanes.md](windows-build-lanes.md).
- CI lane: one CI workflow of a repository, named after its workflow file, such as `linux-x64` or
  `windows-arm64`. See
  [branch-and-release-strategy.md § Asking for a lane in a commit message](branch-and-release-strategy.md#asking-for-a-lane-in-a-commit-message).
- GenieX lane: on the Snapdragon GenieX host, one model server bound to one accelerator and port.
  See [geniex-local-ai-setup.md](geniex-local-ai-setup.md).

## Phase N

A numbered step of one plan. Each plan numbers its own phases, so "phase 3" on one page has nothing
to do with "phase 3" on another. Phase 0 is usually the step that decides or measures.

- Rollout phase: one step of a staged plan that lands and is checked on its own. See
  [hailo-support.md § Phased rollout](hailo-support.md#phased-rollout).
- Build-script phase: a numbered step inside one Windows build script, marked by
  `Switch-BuildPhase`. Only the scripts explain the numbers.
- Stage labels: [overview.md § Linux Image Chain](overview.md#linux-image-chain) labels the first
  Linux stages Phase 1 to Phase 4.

## proof

Evidence that a claim holds. A page says what a check leaves open with "does not prove".

- Source proof: the saved result of the complete preflight on one exact committed source tree. A
  local image build refuses a source that differs from it. See
  [local-proof-workflows.md](local-proof-workflows.md).
- Mutation proof: evidence that a test guards something. The mutation gate breaks one guarantee,
  and the named test must then fail. See
  [code-quality-tooling.md § The mutation gate](code-quality-tooling.md#the-mutation-gate-mutations).
- Gate proof: a test suite or mutation that shows a preflight gate can fail. The gate registry
  needs one for every gate. See
  [code-quality-tooling.md § Gate proof registry](code-quality-tooling.md#gate-proof-registry-gate-registry).
- Local proof: a bounded run on a local build host whose command, logs and receipts are kept. Its
  drivers live in `linux/scripts/local-proof/`. See [local-proof-workflows.md](local-proof-workflows.md).

## ratchet

A limit that moves only one way.

- Downward ratchet: a committed file freezes today's count of findings, and the count may only
  fall. A higher count fails. A lower count also fails until its row is lowered in the same commit,
  so the file always matches the tree. See
  [code-quality-tooling.md § The allowlist contract](code-quality-tooling.md#the-allowlist-contract).
- `--ratchets`: the switch of `run-lint-gates.sh` that adds the measurement gates, each with its own
  freeze file in the consumer. See
  [shared-script-libraries.md § run-lint-gates.sh](shared-script-libraries.md#run-lint-gatessh--the-gates-over-a-consumer-tree-plus-the-opt-in-ratchets).
- Upward ratchet: a floor that may only rise. Above it, the check asks you to record the new number.
  See [vulkan-foreign-arch-sdk.md § The toolset floor only ratchets up](vulkan-foreign-arch-sdk.md#the-toolset-floor-only-ratchets-up).

## receipt

A file a check writes when it finishes: what it checked, the hashes it saw and whether it passed.
Later steps read it and refuse to run when the hashes no longer match. A receipt records a check; it
does not show where its inputs came from.

- Acceptance receipt: an image tag moves to a digest only after a passed consumer receipt for that
  digest. See [image-acceptance.md](image-acceptance.md).
- GPU package receipt: ties a built package's file names and hashes to one CI run and the check run
  on it. See [gpu-artifact-receipts.md](gpu-artifact-receipts.md).
- Local workflow receipt: written by a local stage build, export, cleanup or transfer once it has
  checked its own result. A stopped receipt follows a unit that ended and was cleaned up. See
  [local-proof-workflows.md](local-proof-workflows.md).
- Frozen test receipt: in a script suite, a saved copy of a helper's original output that a
  refactored helper must reproduce byte for byte.

In the local workflows, receipt and proof name the same kind of file.

## seal

- Sealing a run: the closing step of a local workflow after its systemd unit has ended. It checks
  the unit's result, hashes the inputs and outputs again, confirms the owned cleanup and writes a
  final stopped record. A seal shows the run ended and cleaned up; it does not show that what the
  run built is correct. See
  [local-proof-workflows.md § Consumer command seals](local-proof-workflows.md#consumer-command-seals).
- Sealed wheelhouse: in the runtime build's export mode, the wheel directory leaves the Android
  image with a sha256 manifest. The wrapper build checks the manifest again before it mounts the
  directory. See
  [linux-cross-builds.md § The wrapper's wheelhouse](linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).

<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# GPU package receipts

Windows GPU checks can use `shared/python/windows_installer_payload.py` to inspect a
trusted MSIX or administratively extract a trusted MSI into a temporary directory.
The caller profiles the extracted executable and owns artifact identity checks. The
helper estimates disk use before extraction; it is not an enforced quota. MSI
administrative extraction can execute custom actions, so use a trusted runner and
trusted same-run packages. Extraction does not install the app or test installed
behavior. `windows_gpu_process.py` terminates a timed-out Windows process tree.
The Windows CI fixture checks a real MSI File table and synthetic MSIX archives;
`pwsh -File windows/scripts/tests/Test-WindowsInstallerPayloadFixture.ps1 -IncludeRoundtrip` also
builds and extracts a text-only MSI with WiX when that tool is available. Neither
fixture installs an application or exercises a GPU.

The `windows-clean-gpu-check` action accepts the Windows package identity from the
trusted producer resolver, downloads the current-run archive by ID, and runs a
caller-owned PowerShell CPU inference check on a fresh GitHub-hosted Windows x64
runner. It first compares the downloaded files to the current-attempt producer
receipt, then writes a clean-host receipt only if the check succeeds, package bytes
remain unchanged, and scratch cleanup succeeds. The caller owns installation and removal, and must upload
the resulting receipt and pair it with a separate hardware GPU profile receipt.
Before download it reserves 4 GiB after the reported compressed archive size; before
extraction it reserves 2 GiB for the hosted runner and 2 GiB for installer work
after the measured expanded package size. This estimate is not an extraction quota
and does not guarantee an installer will fit. Local and self-hosted GPU checks retain
their separate disk floor.

The same `windows_clean_gpu_receipt.py` driver supports a trusted self-hosted GPU
check with `--check gpu-model-inference --evidence-dir <absolute-empty-directory>`.
That directory must be outside `--work`; the PowerShell callback receives it as
`GPU_EVIDENCE_DIR`, with `GPU_PACKAGE_DIR` and `GPU_VENDOR`. It must write at least
one regular evidence file. The driver verifies the producer receipt before the
callback, rechecks package bytes afterward, rejects linked evidence, and publishes
the GPU receipt only after package scratch cleanup. The caller owns and removes
the evidence directory, including on failure; upload it only after the driver
succeeds. This records the caller's check, not independent proof of GPU execution.

`shared/python/gpu_artifact_receipt.py` binds a flat set of named package files to
a caller-supplied CI identity and a named passed check. It uses only the Python
standard library and runs on Windows and Linux. It is a building block; it is not
yet connected to any release workflow.

Both `create` and `verify` require the same arguments: `--directory`, `--receipt`,
one `--file` per expected package, `--repository`, `--revision` (a full 40-digit
lowercase commit SHA), `--run-id`, `--run-attempt`, `--artifact-id`,
`--artifact-digest` (the upload action's bare SHA-256 archive digest), `--platform`,
`--arch`, `--vendor` and `--check` (a stable check name). IDs and attempts are
positive decimal integers. The supported tuples are Linux x64 NVIDIA/AMD, Linux
arm64 NVIDIA, and Windows x64 NVIDIA/AMD. The receipt must be outside the package
directory; `create` refuses to overwrite an existing file.
An optional `sha256:` prefix is accepted and normalized to the same bare digest.

The directory must contain exactly the named regular files: extras, subdirectories,
links, duplicate names and path components fail. The receipt records each file's
SHA-256 separately from the Actions archive digest. `verify` compares the caller's
expected identity and filenames against the receipt and rehashes the packages.
Malformed or duplicate JSON fields and a status other than `passed` fail.

For a trusted Linux x64 NVIDIA job, for example, assemble the arguments from the
workflow's own context and the upload action's outputs, then use them after the
checks described below:

```bash
receipt_args=(--directory "$PACKAGES" --receipt "$RECEIPT"
  --file app.deb --file app.AppImage --repository "$GITHUB_REPOSITORY"
  --revision "$GITHUB_SHA" --run-id "$GITHUB_RUN_ID" --run-attempt "$GITHUB_RUN_ATTEMPT"
  --artifact-id "$ARTIFACT_ID" --artifact-digest "$ARTIFACT_DIGEST"
  --platform linux --arch x64 --vendor nvidia --check gpu-model-inference)
python3 shared/python/gpu_artifact_receipt.py create "${receipt_args[@]}"
python3 shared/python/gpu_artifact_receipt.py verify "${receipt_args[@]}"
```

**A receipt does not prove a GPU check happened or authenticate its author.** A
trusted workflow must download an immutable artifact ID with digest verification,
hash the packages before the hardware test, run the real named check against those
same bytes, and confirm their hashes did not change before creating a passed receipt.
This tool compares the supplied artifact ID and archive digest as identity strings;
it does not fetch GitHub metadata or independently verify the downloaded archive.
The workflow must obtain those values from trusted upload metadata and validate the
archive using a digest-verifying download action before invoking the tool.
Promotion must independently obtain the expected repository, commit, run, attempt,
artifact ID and digest from trusted workflow context, download that same ID, verify
the passed receipt and hashes, and enforce the required check for every tuple.
Do not read the expected values solely from the receipt being checked. Checks on
an untrusted runner cannot be made trustworthy by this file. Coordinate access to
the directory so other processes cannot replace files while they are being hashed.

An overwritten Actions artifact is a new artifact: bind to its ID, not only its
name. On a rerun, require matching run attempt and recreate all dependent receipts;
do not promote a stale receipt or a different matrix entry. GPU releases also need
explicit expected asset names and their existing clean-host and license checks.

The `resolve-gpu-producer` action runs on Linux and accepts a trusted `producer-verified` receipt and
an exact attempt-scoped artifact name. It independently queries the current workflow
run's artifact metadata, requires one non-expired matching artifact, and compares
its ID and digest with the receipt before returning them and the package filenames.
The calling job needs `actions: read`. The caller must form the name from the current
run, attempt and validated GPU tuple, and must verify that its upload contains the
producer-hashed package bytes before publishing the receipt. This resolver does not
run a GPU check or authenticate a receipt from an untrusted producer.

Linux artifacts retain the existing DEB, tarball and AppImage contract. Windows x64 GPU
callers must set `package-layout` explicitly to `zip` (one ZIP), `installers` (MSI,
MSIX and test certificate) or `zip-installers` (all four); the installer files and
certificate must share a stem. Both `-testcert.cer` and `-test-signing.cer` match the
existing installer producers. For AccelerANTgine, `accelerantgine` expects the actual
CPack ZIP/MSI stem and its four-component, underscore-named MSIX; it permits one
matching `.cer`, `-testcert.cer` or `-test-signing.cer`, but the current producer does
not guarantee a certificate. Windows ARM GPU tuples are rejected. This check does
not run Windows installers or verify GPU inference: separate trusted clean-host and
hardware receipts are still required before staging.

For Windows GPU artifacts, `Assert-PackageOrtFamily` in
`WindowsPackageBinary.Common` requires exactly the named ORT-family DLLs in a
declared bundle or ZIP, MSI or MSIX directory. Unexpected, duplicate, nested or
linked ORT-family files fail, including files outside that directory. MSI checks
the installed file table and root-relative paths. This census does not verify
the files' bytes: use `Assert-PackageBinary` against wheel-proven inputs and
verify their notices separately.

## Stage checked bytes for a release

`shared/python/stage_gpu_artifact.py` accepts the raw, flat ZIP of a single
Actions artifact, two receipts and independently supplied CI identity fields.
Download the artifact by its immutable ID with `actions/download-artifact@v8`,
`skip-decompress: true` and `digest-mismatch: error`; derive the expected ID and
SHA-256 digest from the trusted upload step. Pass the current repository, commit,
run and attempt from the trusted workflow context. The script hashes the raw ZIP
and requires it to match that digest, then checks the two distinct receipts for
`clean-host-inference` and `gpu-model-inference`, the same identity, exact filenames
and the hashes of the ZIP's actual package bytes.

Pass `--file` once per explicitly expected package, and set positive
`--max-uncompressed-bytes` and `--max-compression-ratio` limits for the intended
packages. Extra, duplicate, nested, linked and encrypted entries fail. The output
must be a nonexistent path under an existing real directory. Files are written in
a temporary sibling and published atomically without replacing an existing path;
Linux requires `renameat2` with `RENAME_NOREPLACE` support from the output
filesystem; Windows requires its no-replace rename. Some filesystems, including
WSL DrvFs mounts such as `/mnt/c`, can reject this operation. Use a filesystem
that supports it, such as a suitable native Linux filesystem; the script reports
the error and fails closed instead of falling back to a replacing rename. A failed
run must never be followed by upload, and callers must guard against other processes
changing inputs or the output during and after the operation.

This staging step does not fetch the artifact or authenticate either receipt.
Only trusted jobs that verified and tested the exact artifact may produce those
receipts, and the caller must obtain the expected identity independently. It does
not run GPU inference, create a release, or establish that a physical GPU was used.
Each caller must explicitly wire successful check jobs and upload only the staged output.

## Linux check actions

`clean-host-package-check` retains its existing name-based download by default.
For a GPU receipt, a trusted caller supplies `artifact-id`, `artifact-digest`,
the three exact `artifact-files`, vendor, architecture, output receipt path and
expansion limits. It downloads the raw archive by ID, checks the trusted digest,
extracts the packages, and records their hashes before running its usual clean-host
commands. Only after those commands succeed and the same files still match does it
write a `clean-host-inference` receipt. All three DEB, tarball and AppImage checks
and their commands are required in this mode; partial inputs fail before download.

`gpu-package-check` applies the same pre/post protocol around a trusted Linux GPU
profiling command, with the extracted packages in `GPU_PACKAGE_DIR`. The command
must actually profile each expected package on the requested physical GPU; its
exit status and the receipt alone cannot prove that it did. A caller must upload
both receipts only after their corresponding checks succeed, and use the current
run's immutable artifact ID and upload digest for the staging step.

For default MIGraphX verification, source `linux/scripts/lib/gpu-profile-env.sh`
and call `gpu_without_migraphx_overrides COMMAND [ARG...]`. It removes inherited
`MIGRAPHX_*` and `ORT_MIGRAPHX_*` variables from that command's environment while
preserving the caller's environment and GPU visibility. Apply any intentional
diagnostic setting inside the command; a diagnostic run does not establish default
runtime behavior. Callers still select and verify the physical GPU independently.

### Comparing a Windows AMD display with WSL HIP

For a local WSL check, first enumerate Windows display devices with
`Get-PnpDevice -Class Display`. Pass the exact AMD PCI device `InstanceId` to
`windows/scripts/diagnostics/Get-AmdDisplayPciAddress.ps1`. The read-only helper
requires that device to be healthy and its bus/device/function to be unique among
Windows PCI display devices. It prints an address such as `18:00.0`.

In the same Linux or container environment that will run the application, with the
same runtime library and visibility settings, call
`python3 -I shared/python/verify_hip_adapter.py --pci-address 18:00.0` using the
Windows result. It loads `libamdhip64.so.7`, requires exactly one HIP-visible GPU
and matches the HIP-reported PCI address in domain zero. The command never changes
which devices are visible. A missing device, multiple visible GPUs, a nonzero domain,
an inaccessible runtime or an address mismatch fails the check.

This comparison does not prove PCI-address equivalence on every WSL configuration,
that the application loaded the same HIP library, or that ORT ran on the device;
retain separately verified provider profiles and output-parity checks. It also does
not establish a stable GPU UUID: the WSL iGPU inspected on 2026-10-31 returned a HIP
UUID with bytes `5858` followed by zeros. Recheck both sides after hardware or driver
changes, and do not assign that value to another adapter.

## Detector parity

`shared/python/compare_detector_parity.py CPU.json GPU.json` compares detections
from the two-cats fixture. Both inputs use schema version 1 with image dimensions
and detection classes, scores and pixel boxes. It requires a credible CPU baseline
and a one-to-one class, score and box match. Empty, malformed and non-finite results
fail. Callers must run the actual packaged detector twice, independently verify the
CPU and GPU operator profiles, and pass results from those same runs. A match alone
does not establish GPU execution or prove parity on other images.

After validating a CPU baseline against every result, use `--pairwise` to compare
repeated results to each other. It retains the schema, bounds and one-to-one tolerance
checks without reapplying the CPU-only two-cats score oracle to a GPU reference.
Pairwise checks must not replace the default CPU-baseline checks.

## A package on your own GPU

No hosted runner has a GPU, so a package has run on one only where someone ran it. On Windows, unpack
the package and run its detector on ModelANT's `contracts/fixtures/two_cats.jpg`, on the CPU and then
on the GPU:

| Repository | Command |
| --- | --- |
| OxidANT | `$env:KATAGLYPHIS_ORT_DEVICE='directml'; oxidant-directml.cmd onnx-detect --image two_cats.jpg --output gpu.json --profile gpu-prof --repeat-output gpu-repeat.json` |
| AccelerANTgine | `AccelerANTgine_demo.exe --device directml --device-id 0 --detector-image two_cats.jpg --detector-output gpu.json --detector-repeat-output gpu-repeat.json --profile gpu-prof` |
| OmniAccelerANT | `$env:KATAGLYPHIS_ORT_DEVICE='directml'; omni_accelerant.exe --detect-check two_cats.jpg`, exit 0 with two cats |
| OrchestrANT | `scripts/diagnostics/detector_parity.py --device directml` on the bundle's `runtime/python.exe` |

Compare with `compare_detector_parity.py cpu.json gpu.json`, then check the GPU run's profile with
`verify_ort_profile.py PROFILE.json --device directml`. Take both. On 2026-11-02 an RX 9070 XT ran
`deim_dfine_n_coco-v1` with every profiled operator on `DmlExecutionProvider` and returned no
detection, because DirectML computes MatMul by a 1-D vector wrongly; v2 returns the CPU's detections.

To build a GPU package yourself, run the repository's Windows build inside `:winamd64-nvidia` or
`:winamd64-rocm`: AccelerANTgine's `Invoke-ContainerBuild.ps1 -OrtVariant nvidia|amd -Image IMAGE`
or OmniAccelerANT's `Build-Windows.ps1 -OrtProvider cuda|directml`.

## Repeated ORT profile runs

`python3 shared/python/verify_ort_profile.py PROFILE.json --device migraphx --min-runs 2`
requires at least two complete, non-overlapping `model_run` intervals in one
process, and a non-copy model operator on the requested provider fully inside
every complete run. Qualifying intervals need valid timing; a run without a
matching provider event fails. Omitting `--min-runs` retains the single-profile check.
The trace identifies a process, not an ORT session; callers must independently
ensure repeated runs use the same session and compare their outputs. A provider
event alone does not establish correct results or physical GPU execution.

`--device xnnpack` and `--device dnnl` apply the same operator rule to ORT's CPU
accelerator providers, so a session that fell back to `CPUExecutionProvider` fails.

## Reusable workflow invocation scopes

For each callable GPU workflow, pass the caller's optional scope through the environment
as `GPU_INVOCATION_SCOPE` to `python3 -I shared/python/gpu_invocation_scope.py` before
using it. The helper writes `suffix` to `GITHUB_OUTPUT`: the default scope produces an
empty suffix, and another valid scope produces `-scope-<scope>`. Scopes must match
`[a-z][a-z0-9-]{0,31}`; invalid values fail before the output file is opened. Callers
of the same reusable workflow in one parent run must use distinct scopes, including
when their selected GPU targets overlap. The caller remains responsible for uniqueness.

Use the validated output consistently in attempt-scoped artifact names, receipts and
scratch paths, and in job concurrency groups after the validation job succeeds. Do not
use raw scope input in a cancellation-sensitive group before validation. A scope
separates evidence; it does not authenticate an artifact or verify GPU execution.

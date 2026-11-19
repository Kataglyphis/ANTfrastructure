#!/usr/bin/env bash
# Run source controls inside the family image; no parent OCI, compiled ORT or hardware acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
proof_dir="$1"
selected_manifest="$2"
cd "${ROOT}"
test -d "${proof_dir}"
test -f "${selected_manifest}"
test ! -e "${proof_dir}/as-tested-source.patch"
source "${ROOT}/linux/scripts/01-core/python-probe.sh"
ci_image_python_require webgpu-media-lane-controls
PATH="$(dirname "${PREFLIGHT_PYTHON}"):${PATH}"
export PATH
bash linux/scripts/tests/test-doc-numbers.sh --update > "${proof_dir}/doc-number-preparation.log" 2>&1
git add -- AGENTS.md docs/code-quality-tooling.md docs/cross-build-verification.md
git diff --cached --full-index --binary > "${proof_dir}/as-tested-source.patch"
git ls-files --stage -z > "${proof_dir}/index-before.bin"
for suite in webgpu-media-lanes normal-stage-launch gpu-handoff media-handoff sccache-s3-level-environment; do
  bash "linux/scripts/tests/test-${suite}.sh" > "${proof_dir}/${suite}.log" 2>&1
done
test ! -e "${proof_dir}/selected-mutations.json"
cp -- "${selected_manifest}" "${proof_dir}/selected-mutations.json"
UV_OFFLINE=1 bash linux/scripts/03-media/build/migraphx/source-check.sh "${proof_dir}" > "${proof_dir}/source-check.log" 2>&1
git diff --cached --full-index --binary > "${proof_dir}/source-after.patch"
git ls-files --stage -z > "${proof_dir}/index-after.bin"
cmp "${proof_dir}/as-tested-source.patch" "${proof_dir}/source-after.patch"
cmp "${proof_dir}/index-before.bin" "${proof_dir}/index-after.bin"
dirty_worktree="$(git diff --name-only --ignore-submodules=all)"
test -z "${dirty_worktree}"
printf '%s\n' 'WebGPU Media six command profiles, legacy controls, selected mutations and structural gates passed'

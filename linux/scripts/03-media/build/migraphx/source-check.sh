#!/usr/bin/env bash
# These preparation protocol and source checks do not establish an installed backend or image acceptance.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/cli-value-options.sh"
cli_require_positionals 'EVIDENCE_DIRECTORY' 1 1 "$@"
evidence="$(cd "$1" && pwd)"
hub="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
cd "${hub}"
export LC_ALL=C KNOB_GATE=1
bash linux/scripts/tests/test-migraphx-stack.sh > "${evidence}/stack-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-python-selection.sh > "${evidence}/python-selection-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-python-probe.sh > "${evidence}/python-probe-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-plugin-ep.sh > "${evidence}/plugin-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-backend-build.sh > "${evidence}/backend-build-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-source-launcher.sh > "${evidence}/source-launcher-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-rocmlir-api.sh > "${evidence}/rocmlir-api-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-rocmlir-build.sh > "${evidence}/rocmlir-build-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-rocmlir-source.sh > "${evidence}/rocmlir-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-ck-consumer.sh > "${evidence}/ck-consumer-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-sdk-closure.sh > "${evidence}/sdk-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-source-deps.sh > "${evidence}/deps-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-source-plan.sh > "${evidence}/plan-tests.log" 2>&1
bash linux/scripts/tests/test-migraphx-configure-launcher.sh > "${evidence}/launcher-tests.log" 2>&1
python3 docs/scripts/verify_mutations.py --root "${hub}" --manifest "${evidence}/selected-mutations.json" --jobs 2 > "${evidence}/mutations.log" 2>&1
python3 docs/scripts/verify_mutations.py --root "${hub}" --stale-check > "${evidence}/anchors.log" 2>&1
python3 docs/scripts/verify_mutations.py --root "${hub}" --parse-check > "${evidence}/parsers.log" 2>&1
PREFLIGHT_ONLY=cmake-format,env-knobs,crlf-guard,shellcheck,stdout-returns,copy-coverage,code-dupes,python-lint,python-types,masked-decls,trailing-conditional,comment-size,code-size,code-complexity,dead-functions,large-files,readme-length,agents-drift,shellcheck-warnings,gate-registry,doc-links,doc-dupes,version-snapshot,sbom,dockerfile-lint,stage-graph \
  PREFLIGHT_JOBS=2 bash linux/scripts/preflight.sh > "${evidence}/preflight.log" 2>&1

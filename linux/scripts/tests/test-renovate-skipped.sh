#!/usr/bin/env bash
# Semantic skip classification must distinguish immutable code-controlled inputs from real lookup failures; live registry freshness is outside this fixture.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PLANNER="${TESTS_DIR}/../renovate_planner.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '# hadolint ignore=DL3022\nCOPY --from=site / /site/\n' > "${WORK}/Dockerfile"

cp "${TESTS_DIR}/fixtures/renovate-semantic-skips.json" "${WORK}/report.json"

run_skipped() { python3 "${PLANNER}" skipped "${WORK}/report.json" "${WORK}"; }

t_case "floating image aliases, local build images and workflow outputs are not version pins"
OUT="$(run_skipped)"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tfloating-image-tag\t2')" "both floating aliases are counted"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tlocal-build-image\t2')" "both local image spellings are counted"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tworkflow-output-expression\t1')" "a runtime Actions value is counted"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tespup-toolchain-channel\t1')" "the named espup toolchain is counted"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tnamed-build-context\t1')" "the asserted COPY context is counted"
t_assert_contains "${OUT}" "$(printf 'DESIGN\tfloating-git-source\t1')" "an unversioned Git source has no manifest version to edit"

t_case "other invalid values, lookup failures and invalid config remain fatal rows"
t_assert_contains "${OUT}" "$(printf 'SKIP\tdocker-compose\tcompose.yaml\tghcr.io/acme/other\trolling\tinvalid-value')" \
  "an unrecognized moving tag is not silently cleared"
t_assert_contains "${OUT}" "$(printf 'SKIP\tdockerfile\tDockerfile\tghcr.io/acme/base\tsdk\tinvalid-value')" \
  "a remote image named like a stage remains a finding"
t_assert_contains "${OUT}" "lookup-failed: registry unreachable" "a failed lookup remains a finding even for a local image"
t_assert_contains "${OUT}" "$(printf 'SKIP\tdockerfile\tDockerfile\tlocal/kataglyphis\tsdk\tinvalid-value')" \
  "an explicit invalid value with a warning cannot become DESIGN"
t_assert_contains "${OUT}" "$(printf 'SKIP\tregex\ttool-pins.env\tdartdoc\t9.0.8\tinvalid-config')" \
  "invalid config remains a finding"
t_assert_contains "${OUT}" '${{ nonsense }}' "an unrecognized expression remains a finding"
t_assert_contains "${OUT}" "cannot reach Rust toolchain feed" "a failed rust lookup remains a finding"
t_assert_contains "${OUT}" "$(printf 'SKIP\trust-toolchain\tfirmware/rust-toolchain.toml\trust\tlates\tinvalid-version')" \
  "a mistyped channel remains a finding"
t_assert_contains "${OUT}" "$(printf 'SKIP\tpep621\tpyproject.toml\ttorch\t@ git+https://github.com/pytorch/pytorch.git@v2.14.1\tinvalid-value')" \
  "a tagged Git source remains a version pin requiring coverage"
t_assert_contains "${OUT}" "lookup-failed: registry unreachable" "a failed lookup never becomes a floating-source pass"

t_case "removing the adjacent DL3022 context proof makes COPY --from visible as unchecked"
printf 'COPY --from=site / /site/\n' > "${WORK}/Dockerfile"
MUTATED="$(run_skipped)"
t_assert_contains "${MUTATED}" "$(printf 'SKIP\tdockerfile\tDockerfile\tsite\t-\tinvalid-value')" \
  "a bare from name is not assumed to be a build context"
printf '# hadolint ignore=DL3022\nCOPY --from=site / /site/\n' > "${WORK}/Dockerfile"

t_case "mutating the floating-tag rule makes its two cases fail as unchecked"
sed 's/return "floating-image-tag"/return ""/' "${PLANNER}" > "${WORK}/mutated.py"
MUTATED="$(PYTHONPATH="${TESTS_DIR}/.." python3 "${WORK}/mutated.py" skipped "${WORK}/report.json" "${WORK}")"
t_assert_contains "${MUTATED}" "$(printf 'SKIP\tdocker-compose\tcompose.yaml\tghcr.io/acme/app\tlatest\tinvalid-value')" \
  "the planted regression reaches the failing class"
t_assert_fails grep -q 'DESIGN.floating-image-tag' <<<"${MUTATED}"

t_summary

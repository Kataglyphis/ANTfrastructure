#!/usr/bin/env bash
# default.json's CMake managers: what they detect, then what --apply writes; see docs/dependency-updates.md#cmake-dependencies
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
SCRIPTS_DIR="${TESTS_DIR}/.."
PRESET="${HUB}/default.json"
CM_REL="third_party/CMakeLists.txt"

# AccelerANTgine's third_party/CMakeLists.txt pins (2026-10-01), googletest already moved to a tag archive.
ACC="${WORK}/acc.cmake"
cat > "${ACC}" <<'CMAKE'
include(FetchContent)

FetchContent_Declare(
  abseil-cpp
  GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
  # Keep this pinned to the version FUZZTEST's MODULE.bazel declares - the two
  # MUST move together (mismatch breaks e.g. absl::random_mocking_access).
  # renovate: datasource=github-tags depName=abseil/abseil-cpp versioning=loose
  GIT_TAG 20260526.0)
FetchContent_MakeAvailable(abseil-cpp)

if(BUILD_TESTING)
  FetchContent_Declare(googletest
                       URL https://github.com/google/googletest/archive/refs/tags/v1.17.0.zip)
  FetchContent_MakeAvailable(googletest)
endif()

FetchContent_Declare(
  GSL
  GIT_REPOSITORY "https://github.com/microsoft/GSL"
  # renovate: datasource=github-tags depName=microsoft/GSL
  GIT_TAG "v4.2.1")
FetchContent_MakeAvailable(GSL)

if(RUST_FEATURES)
  set(CXXBRIDGE_CMD_VERSION
      # renovate: datasource=crate depName=cxxbridge-cmd versioning=semver
      "1.0.191"
      CACHE STRING "Lower bound for cxxbridge-cmd; cargo install resolves it as a caret range")

  FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG master)
  FetchContent_MakeAvailable(Corrosion)
endif()
CMAKE

# BeschleunigerBallett's shapes: set(ABSL_TAG) under its hint, GSL and corrosion bare, and an archive behind a URL_HASH.
BB="${WORK}/bb.cmake"
cat > "${BB}" <<'CMAKE'
# Must stay >= the absl_TAG FuzzTest pins in
# third_party/FUZZTEST/cmake/BuildDependencies.cmake.
# renovate: datasource=github-tags depName=abseil/abseil-cpp versioning=loose
set(ABSL_TAG 20260526.0)
FetchContent_Declare(
  abseil-cpp
  GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
  GIT_TAG ${ABSL_TAG}
  GIT_SHALLOW 1
)

FetchContent_Declare(
  benchmark
  URL https://github.com/google/benchmark/archive/refs/tags/v1.9.4.tar.gz
  URL_HASH SHA256=0000000000000000000000000000000000000000000000000000000000000000)

FetchContent_Declare(
  GSL
  GIT_REPOSITORY "https://github.com/microsoft/GSL"
  GIT_TAG "v4.2.1")
FetchContent_MakeAvailable(GSL)

if(RUST_FEATURES)
  FetchContent_Declare(
    Corrosion
    GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git
    GIT_TAG v0.5.2)
  FetchContent_MakeAvailable(Corrosion)
endif()
CMAKE

# Nothing here is a version: a commit archive, two branches, a SHA and a variable.
SKIPS="${WORK}/skips.cmake"
cat > "${SKIPS}" <<'CMAKE'
FetchContent_Declare(googletest URL https://github.com/google/googletest/archive/56efe3983185e3f37e43415d1afa97e3860f187f.zip)
FetchContent_Declare(Corrosion GIT_REPOSITORY https://github.com/corrosion-rs/corrosion.git GIT_TAG master)
FetchContent_Declare(benchmark GIT_REPOSITORY https://github.com/google/benchmark.git GIT_TAG 56efe3983185e3f37e43415d1afa97e3860f187f)
FetchContent_Declare(abseil-cpp GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git GIT_TAG ${ABSL_TAG})
ExternalProject_Add(astc GIT_REPOSITORY https://github.com/ARM-software/astc-encoder GIT_TAG main)
CMAKE

# _preset <detect FILE REL | syntax | re2>: questions put to the preset's customManagers, read from the JSON itself.
_preset() {
  "${PY_ABS}" - "${PRESET}" "${SCRIPTS_DIR}" "$@" <<'PY'
import json
import re
import sys

preset, scripts, mode = sys.argv[1:4]
with open(preset, encoding="utf-8") as fh:
    managers = json.load(fh)["customManagers"]


def picks(cm, rel):
    return any(re.search(p[1:-1], rel) for p in cm["managerFilePatterns"])


# Renovate's handleAny: one row per match of every matchString, never de-duplicated.
if mode == "detect":
    with open(sys.argv[4], encoding="utf-8") as fh:
        text = fh.read()
    rows = []
    for cm in [cm for cm in managers if picks(cm, sys.argv[5])]:
        for pat in cm["matchStrings"]:
            for m in re.finditer(re.sub(r"\(\?<(?=\w)", "(?P<", pat), text, re.ASCII):
                g = m.groupdict()
                rows.append(" ".join((cm.get("datasourceTemplate") or g["datasource"], g["depName"],
                                      g["currentValue"], g.get("versioning") or "-")))
    print("\n".join(sorted(rows)))
elif mode == "syntax":
    sys.path.insert(0, scripts)
    import renovate_locator
    for rel in ("CMakeLists.txt", "third_party/CMakeLists.txt", "cmake/deps.cmake",
                "CMakeLists.txt.in", "cmake/README.md", "linux/scripts/01-core/versions.env"):
        print(rel, all(picks(cm, rel) for cm in managers),
              renovate_locator.syntax("regex", rel) == renovate_locator.CMAKE)
elif mode == "re2":
    for pat in [p for cm in managers for p in cm["matchStrings"]]:
        if re.search(r"\(\?<?[=!]|\\[1-9]", pat):
            print(pat)
PY
}

t_case "AccelerANTgine's pins: three annotated, one tag archive, the master branch skipped"
t_assert_eq "crate cxxbridge-cmd 1.0.191 semver
github-tags abseil/abseil-cpp 20260526.0 loose
github-tags google/googletest v1.17.0 -
github-tags microsoft/GSL v4.2.1 -" "$(_preset detect "${ACC}" "${CM_REL}")" \
  "each pin once: the URL form must not ALSO read the annotated abseil and GSL"

t_case "BeschleunigerBallett's shapes: set() under a hint, and the URL forms alone"
t_assert_eq "github-tags abseil/abseil-cpp 20260526.0 loose
github-tags corrosion-rs/corrosion v0.5.2 -
github-tags google/benchmark v1.9.4 -
github-tags microsoft/GSL v4.2.1 -" "$(_preset detect "${BB}" "${CM_REL}")" \
  "GIT_TAG \${ABSL_TAG} is no version; the set() it names is"

t_case "a branch, a SHA, a commit archive and a variable are not versions"
t_assert_eq "" "$(_preset detect "${SKIPS}" cmake/deps.cmake)" \
  "a floating or digest pin reported as a version proposes a bogus update"

t_case "the managers read CMake files, and the locator calls the same files CMake"
t_assert_eq "CMakeLists.txt True True
third_party/CMakeLists.txt True True
cmake/deps.cmake True True
CMakeLists.txt.in False False
cmake/README.md False False
linux/scripts/01-core/versions.env False False" "$(_preset syntax)" \
  "a file the preset reads but the locator does not call CMake is applied with the env reader"

t_case "Renovate compiles matchStrings with RE2, which has no lookaround or backreference"
t_assert_eq "" "$(_preset re2)" "an RE2-invalid pattern is a config error for the whole run"

# _cmake_repo <name> <fixture>: a committed checkout carrying the fixture as third_party/CMakeLists.txt.
_cmake_repo() {
  local d
  d="$(_repo "$1")"
  mkdir -p "${d}/third_party"
  cp "$2" "${d}/${CM_REL}"
  _commit "${d}"
  printf '%s' "${d}"
}

# _apply <fixture> <dep> <cur> <new>: --apply over a fresh checkout; CM_REPO is the checkout.
CM_REPO=""
CM_N=0
_apply() {
  CM_N=$((CM_N + 1))
  local report="${WORK}/cm-${CM_N}.json"
  CM_REPO="$(_cmake_repo "cm-${CM_N}" "$1")"
  _report "${report}" regex "${CM_REL}" "$2" "$3" "$4"
  _run "${CM_REPO}" "${report}" --apply --managers custom.regex
}

# _moved <fixture> <sed expression>: the checkout is the fixture with exactly that one edit.
_moved() {
  t_assert_eq "$(sed -e "$2" "$1")" "$(cat "${CM_REPO}/${CM_REL}")" \
    "the reported value moved, and nothing else in the file did"
}

t_case "an annotated GIT_TAG under a comment block is written"
_apply "${ACC}" abseil/abseil-cpp 20260526.0 20260611.0
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${ACC}" 's/GIT_TAG 20260526.0)/GIT_TAG 20260611.0)/'

t_case "the tag inside a tag-archive URL is written"
_apply "${ACC}" google/googletest v1.17.0 v1.18.0
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${ACC}" 's#refs/tags/v1.17.0.zip#refs/tags/v1.18.0.zip#'

t_case "a quoted value under its hint, inside a multi-line set(), is written"
_apply "${ACC}" cxxbridge-cmd 1.0.191 1.0.200
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${ACC}" 's/"1.0.191"/"1.0.200"/'

t_case "set(<NAME> <value>) under its hint is written, and GIT_TAG \${NAME} is left alone"
_apply "${BB}" abseil/abseil-cpp 20260526.0 20260611.0
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${BB}" 's/set(ABSL_TAG 20260526.0)/set(ABSL_TAG 20260611.0)/'

t_case "GIT_REPOSITORY + GIT_TAG with no hint: the quoted tag is written, quotes kept"
_apply "${BB}" microsoft/GSL v4.2.1 v4.3.0
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${BB}" 's/GIT_TAG "v4.2.1")/GIT_TAG "v4.3.0")/'

t_case "GIT_REPOSITORY + GIT_TAG with no hint: a bare tag is written"
_apply "${BB}" corrosion-rs/corrosion v0.5.2 v0.6.0
t_assert_eq "0" "${RC}" "the apply exits 0"
_moved "${BB}" 's/GIT_TAG v0.5.2)/GIT_TAG v0.6.0)/'

t_case "a tag archive behind a URL_HASH is refused: the hash would describe the old archive"
_apply "${BB}" google/benchmark v1.9.4 v1.9.5
t_assert_eq "2" "${RC}" "a refusal is the result, so the run exits 2"
t_assert_contains "${OUT}" "checked against its URL_HASH" "and it names the hash"
t_assert_eq "$(cat "${BB}")" "$(cat "${CM_REPO}/${CM_REL}")" "nothing was written"

t_case "a declaration inside a comment is no declaration, whatever the regex matched"
COMMENTED="${WORK}/commented.cmake"
printf '%s\n' '# FetchContent_Declare(GSL GIT_REPOSITORY https://github.com/microsoft/GSL GIT_TAG v4.2.1)' \
  > "${COMMENTED}"
_apply "${COMMENTED}" microsoft/GSL v4.2.1 v4.3.0
t_assert_eq "2" "${RC}" "the CMake reader refuses what only the text search saw"
t_assert_contains "${OUT}" "a real parser finds no declaration of 'microsoft/GSL'" \
  "and the reason is the parser's"
t_assert_eq "$(cat "${COMMENTED}")" "$(cat "${CM_REPO}/${CM_REL}")" "nothing was written"

t_case "one regex report over versions.env and a CMake file: each file is read in its own syntax"
MIXED_REPO="$(_cmake_repo cm-mixed "${BB}")"
mkdir -p "${MIXED_REPO}/linux/scripts/01-core"
printf '%s\n' '# renovate: datasource=github-tags depName=rust-lang/rust' 'RUST_VERSION=1.98.0' \
  > "${MIXED_REPO}/linux/scripts/01-core/versions.env"
_commit "${MIXED_REPO}"
MIXED_REPORT="${WORK}/cm-mixed.json"
printf '{"repositories":{"local":{"packageFiles":{"regex":[%s,%s]}}}}\n' \
  "$(_pkg_json linux/scripts/01-core/versions.env rust-lang/rust 1.98.0 1.98.1)" \
  "$(_pkg_json "${CM_REL}" corrosion-rs/corrosion v0.5.2 v0.6.0)" > "${MIXED_REPORT}"
_run "${MIXED_REPO}" "${MIXED_REPORT}" --apply --managers custom.regex
t_assert_eq "0" "${RC}" "both rows apply"
t_assert_eq "RUST_VERSION=1.98.1" "$(_line "${MIXED_REPO}/linux/scripts/01-core/versions.env" 2)" \
  "the env file moved under the env reader"
CM_REPO="${MIXED_REPO}"
_moved "${BB}" 's/GIT_TAG v0.5.2)/GIT_TAG v0.6.0)/'

t_case "a plan that rewrites the WRONG pin is written, caught by the CMake reader, put back"
WRONG_REPO="$(_cmake_repo cm-wrong "${ACC}")"
WRONG_PLAN="${WORK}/cm-wrong-plan.json"
WRONG_LINE="$(grep -n -e 'GIT_TAG master)' "${ACC}" | cut -d: -f1)"
WRONG_CMD="$(grep -n -e '^  FetchContent_Declare($' "${ACC}" | cut -d: -f1)"
printf '[{"file":"%s","line":%d,"old":"    GIT_TAG master)","new":"    GIT_TAG v4.3.0)","manager":"regex","dep":"microsoft/GSL","cur":"v4.2.1","next":"v4.3.0"}]\n' \
  "${CM_REL}" "$((WRONG_LINE - 1))" > "${WRONG_PLAN}"
_apply_plan "${WRONG_REPO}" "${WRONG_PLAN}"
t_assert_eq "1" "${RC}" "the run must fail"
t_assert_contains "${OUT}" "it changed FetchContent_Declare@${WRONG_CMD}.args[4].arg" \
  "and it names the declaration that moved, by command and line"
t_assert_eq "$(cat "${ACC}")" "$(cat "${WRONG_REPO}/${CM_REL}")" "the file is back"

t_summary

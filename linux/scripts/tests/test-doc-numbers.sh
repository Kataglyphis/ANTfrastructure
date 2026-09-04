#!/usr/bin/env bash
# Doc numbers that are DERIVED, never re-typed: the mutation-manifest counts and
# the hook's fast-slug list, measured here and compared against the three pages
# that quote them. Three waves in a row shipped a stale count that hand-editing
# failed to catch; --update rewrites the digits instead.
# docs/code-quality-tooling.md#doc-numbers-are-derived
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"

_mode=check
[ "${1:-}" = "--update" ] && _mode=update

_out="$(python3 - "${_mode}" "${ROOT}" <<'PY'
import json
import os
import re
import sys

MANIFEST = "docs/scripts/mutations.json"
HOOK = "linux/host-config/git-hooks/pre-commit"
OWNER = "docs/code-quality-tooling.md"
MIRRORS = ("AGENTS.md", "docs/cross-build-verification.md")
TOTALS = re.compile(r"\*\*(\d+) entries\*\* over \*\*(\d+) distinct test commands\*\*")
FAMILY = re.compile(r"(\d+)([^()\n]{0,60}?)\(`([a-z0-9][a-z0-9-]*)\.\*`\)")
BARE = re.compile(r"all \d+ entries|still run all \d+")
FAST = re.compile(r"the (\d+) (?:fast|cheap whole-tree) slugs")
SPAN = re.compile(r"`_FAST_SLUGS` \(`:(\d+)-(\d+)`\)")


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def write(root, rel, text):
    with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
        fh.write(text)


def fast_slugs(root):
    lines = read(root, HOOK).splitlines()
    first = next(i for i, ln in enumerate(lines, 1) if ln.startswith("_FAST_SLUGS="))
    last = first
    while lines[last - 1].rstrip().endswith("\\"):
        last += 1
    body = "".join(ln.rstrip().rstrip("\\") for ln in lines[first - 1:last])
    body = body.split("=", 1)[1].strip().strip('"')
    return len([s for s in body.split(",") if s]), first, last


def truth(root):
    entries = json.loads(read(root, MANIFEST))
    fam = {}
    for entry in entries:
        key = entry["id"].split(".")[0]
        fam[key] = fam.get(key, 0) + 1
    count, first, last = fast_slugs(root)
    return {"total": len(entries), "distinct": len({e["test"] for e in entries}),
            "fam": fam, "fast": count, "span": (first, last)}


def check_totals(root, t, out):
    hits = TOTALS.findall(read(root, OWNER))
    if len(hits) != 1:
        out.append("totals: %s must carry the authority line exactly once, found %d"
                   % (OWNER, len(hits)))
        return
    got = (int(hits[0][0]), int(hits[0][1]))
    if got != (t["total"], t["distinct"]):
        out.append("totals: %s says %s, mutations.json has (%d, %d)"
                   % (OWNER, got, t["total"], t["distinct"]))


def check_family(root, t, out):
    for rel in (OWNER,) + MIRRORS:
        for num, _mid, prefix in FAMILY.findall(read(root, rel)):
            have = t["fam"].get(prefix)
            if have is None:
                out.append("family: %s quotes prefix %s, which no id carries" % (rel, prefix))
            elif int(num) != have:
                out.append("family: %s says %s entries for %s.*, manifest has %d"
                           % (rel, num, prefix, have))


def check_bare(root, _t, out):
    for rel in MIRRORS:
        for hit in BARE.findall(read(root, rel)):
            out.append("bare-total: %s re-quotes the manifest total (%r); %s owns it"
                       % (rel, hit, OWNER))


def check_fast(root, t, out):
    for rel in MIRRORS:
        hits = FAST.findall(read(root, rel))
        if not hits:
            out.append("fast-slugs: %s no longer states the hook's fast-slug count" % rel)
        for num in hits:
            if int(num) != t["fast"]:
                out.append("fast-slugs: %s says %s, the hook lists %d" % (rel, num, t["fast"]))


def check_span(root, t, out):
    seen = 0
    for rel in (OWNER,) + MIRRORS:
        for first, last in SPAN.findall(read(root, rel)):
            seen += 1
            if (int(first), int(last)) != t["span"]:
                out.append("fast-span: %s says :%s-%s, _FAST_SLUGS spans :%d-%d"
                           % (rel, first, last, t["span"][0], t["span"][1]))
    if not seen:
        out.append("fast-span: no page quotes the _FAST_SLUGS line span any more")


CHECKS = (check_totals, check_family, check_bare, check_fast, check_span)


def rewrite(root, t):
    done = []
    for rel in (OWNER,) + MIRRORS:
        before = read(root, rel)
        after = TOTALS.sub(lambda m: "**%d entries** over **%d distinct test commands**"
                           % (t["total"], t["distinct"]), before)
        after = FAMILY.sub(lambda m: "%d%s(`%s.*`)"
                           % (t["fam"].get(m.group(3), int(m.group(1))), m.group(2), m.group(3)),
                           after)
        after = FAST.sub(lambda m: m.group(0).replace(m.group(1), str(t["fast"]), 1), after)
        after = SPAN.sub("`_FAST_SLUGS` (`:%d-%d`)" % t["span"], after)
        if after != before:
            write(root, rel, after)
            done.append("updated: %s" % rel)
    return done


def main():
    mode, root = sys.argv[1], sys.argv[2]
    t = truth(root)
    if mode == "update":
        lines = rewrite(root, t)
    else:
        lines = []
        for check in CHECKS:
            check(root, t, lines)
    print("derived: total=%d distinct=%d fast=%d span=%d-%d"
          % (t["total"], t["distinct"], t["fast"], t["span"][0], t["span"][1]))
    print("\n".join(lines))


main()
PY
)" || _out="fatal: the derivation itself failed"

if [ "${_mode}" = update ]; then
  printf '%s\n' "${_out}"
  exit 0
fi

_kind() { printf '%s\n' "${_out}" | grep -e "^$1:" || true; }

t_case "the derivation ran and measured a non-empty manifest"
t_assert_eq "" "$(_kind fatal)"
t_assert_contains "${_out}" "derived: total="
t_assert_fails bash -c 'printf "%s" "$1" | grep -q -e "total=0 "' _ "${_out}"

t_case "the manifest totals in the owning page are the manifest's own"
t_assert_eq "" "$(_kind totals)" "stale manifest totals"

t_case "every per-family count matches the ids carrying that prefix"
t_assert_eq "" "$(_kind family)" "stale per-family mutation count"

t_case "only the owning page quotes a whole-manifest total"
t_assert_eq "" "$(_kind bare-total)" "a second page re-quotes the manifest total"

t_case "the hook's fast-slug count is quoted correctly"
t_assert_eq "" "$(_kind fast-slugs)" "stale fast-slug count"

t_case "the quoted _FAST_SLUGS line span is where the list really is"
t_assert_eq "" "$(_kind fast-span)" "stale _FAST_SLUGS line span"

t_summary

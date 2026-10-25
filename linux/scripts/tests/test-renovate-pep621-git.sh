#!/usr/bin/env bash
# Tagged PEP 508 Git URLs are located by repo and audited as TOML; registry lookup and pair policy live elsewhere.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-harness.sh"

t_case "tagged PEP 508 Git URLs: exact sites, counts, tags and parser audit"
PYTHON_BIN="$(command -v python3 || command -v python)"
PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)${PYTHONPATH:+:${PYTHONPATH}}" \
  "${PYTHON_BIN}" - <<'PY'
import unittest

import renovate_audit as audit
import renovate_locator as locator

BEFORE = '''[project]
name = "fixture"
keywords = ["torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1"]
dependencies = ["ruff==0.16.6"]

[project.optional-dependencies]
cpu = [
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == \\"riscv64\\"",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == \\"riscv64\\"",
  "torch @ git+https://github.com/pytorch/pytorch-extra.git@v2.14.1",
]
cuda = [
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == 'riscv64'",
]
rocm = [
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
  "torchvision @ git+https://github.com/pytorch/vision.git@v0.29.1 ; platform_machine == 'riscv64'",
]

[tool.uv.extra-build-dependencies]
torchvision = [
  "torch==2.14.1 ; platform_machine != 'riscv64'",
  "torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1 ; platform_machine == 'riscv64'",
]

[tool.metadata]
example = ["torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1"]
'''
KIND = locator.PEP621_GIT
TORCH = ("pytorch/pytorch", "v2.14.1", "v2.14.2", 4)
VISION = ("pytorch/vision", "v0.29.1", "v0.29.2", 3)


def rewrite(text, groups, manager=KIND):
    lines = text.splitlines()
    edits = []
    for dep, old, new, count in groups:
        verdict, found, why = locator.resolve(manager, lines, dep, old, new, count)
        if verdict != "EDIT":
            raise AssertionError(why)
        edits.extend((site.line, site.start, site.end, new) for site in found)
    for line, start, end, new in sorted(edits, reverse=True):
        lines[line] = lines[line][:start] + new + lines[line][end:]
    return "\n".join(lines) + "\n"


class TaggedGitUrls(unittest.TestCase):
    def assert_tagged_refusal(self, text, group, reason):
        verdict, _, located_reason = locator.resolve(KIND, text.splitlines(), *group)
        self.assertEqual(verdict, "REFUSE")
        self.assertIn(reason, located_reason)
        _, _, parsed_reason = audit.expected(KIND, text, [group])
        self.assertIn(reason, parsed_reason)

    def test_exact_repo_and_known_arrays(self):
        lines = BEFORE.splitlines()
        for dep, old, new, count in (TORCH, VISION):
            verdict, found, why = locator.resolve(KIND, lines, dep, old, new, count)
            self.assertEqual((verdict, why), ("EDIT", ""))
            self.assertEqual([site.value for site in found], [old] * count)
        self.assertEqual(len(locator.sites(KIND, lines, "pytorch/pytorch-extra")), 1)
        self.assertEqual(locator.sites(KIND, lines, "elsewhere/pytorch"), [])

    def test_all_seven_tags_and_only_tags_move(self):
        after = rewrite(BEFORE, [TORCH, VISION])
        self.assertEqual(audit.audit(KIND, BEFORE, after, [TORCH, VISION]), "")
        self.assertIn("keywords = [\"torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1\"]", after)
        self.assertIn("pytorch-extra.git@v2.14.1", after)
        self.assertEqual(after.count("pytorch/pytorch.git@v2.14.2"), 4)
        self.assertEqual(after.count("pytorch/vision.git@v0.29.2"), 3)
        self.assertIn("platform_machine == \\\"riscv64\\\"", after)

    def test_generic_pep621_can_move_full_git_spec_beside_wheel_pin(self):
        old = "@ git+https://github.com/pytorch/pytorch.git@v2.14.1"
        new = "@ git+https://github.com/pytorch/pytorch.git@v2.14.2"
        groups = [("torch", old, new, 4), ("torch", "==2.14.1", "==2.14.2", 1)]
        after = rewrite(BEFORE, groups, "pep621")
        self.assertEqual(audit.audit("pep621", BEFORE, after, groups), "")
        self.assertEqual(after.count("torch==2.14.2"), 1)
        self.assertEqual(after.count("pytorch/pytorch.git@v2.14.2"), 4)

        extra = BEFORE.replace(
            "[tool.metadata]",
            '[dependency-groups]\nextra = ["torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1"]\n\n[tool.metadata]',
        )
        _, _, why = audit.expected("pep621", extra, groups)
        self.assertIn("5 of them", why)

    def test_tagged_locator_refuses_one_extra_url_at_a_different_tag(self):
        extra = BEFORE.replace(
            "[tool.metadata]",
            '[dependency-groups]\nextra = ["torch @ git+https://github.com/pytorch/pytorch.git@v2.13.0"]\n\n[tool.metadata]',
        )
        self.assert_tagged_refusal(extra, TORCH, "unmatched URLs")

    def test_report_count_mismatch_refuses(self):
        self.assert_tagged_refusal(BEFORE, (*TORCH[:3], 1), "4 tagged Git URLs")

    def test_malformed_tag_refuses_locator_and_audit(self):
        new = 'v2.14.2 ; python_version > "3"'
        self.assert_tagged_refusal(BEFORE, (TORCH[0], TORCH[1], new, 4), "URL-safe")

    def test_wrong_repo_or_unpinned_url_refuses(self):
        wrong = BEFORE.replace("pytorch/pytorch.git@v2.14.1", "pytorch/not-pytorch.git@v2.14.1")
        verdict, _, _ = locator.resolve(KIND, wrong.splitlines(), *TORCH)
        self.assertEqual(verdict, "REFUSE")
        wrong_package = BEFORE.replace("torch @ git+https://github.com/pytorch/pytorch.git@v2.14.1",
                                       "torchvision @ git+https://github.com/pytorch/pytorch.git@v2.14.1")
        verdict, _, _ = locator.resolve(KIND, wrong_package.splitlines(), *TORCH)
        self.assertEqual(verdict, "REFUSE")
        floating = BEFORE.replace("pytorch/pytorch.git@v2.14.1", "pytorch/pytorch.git@main")
        verdict, _, _ = locator.resolve(KIND, floating.splitlines(), *TORCH)
        self.assertEqual(verdict, "REFUSE")

    def test_audit_rejects_wrong_line_and_invalid_toml(self):
        after = rewrite(BEFORE, [TORCH])
        changed_marker = after.replace("platform_machine == 'riscv64'", "platform_machine == 'amd64'", 1)
        self.assertIn("reported update makes it", audit.audit(KIND, BEFORE, changed_marker, [TORCH]))
        self.assertIn("does not read as toml", audit.audit(KIND, BEFORE, after + "[broken\n", [TORCH]))


unittest.main()
PY
RC=$?
t_assert_eq 0 "${RC}" "the tagged Git URL mutation checks must all pass"
t_summary

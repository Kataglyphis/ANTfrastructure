# Agentic-loop templates

Copy-and-edit starting points for a project adopting the loop. The loop's
logic lives in `windows/scripts/modules/WindowsAgenticLoop.Common.psm1` and
`linux/scripts/lib/agentic-loop.sh`; these files are the thin consumer half.

| File | Copy to | Then |
|---|---|---|
| `AgenticLoop.config.template.json` | `scripts/agentic-loop/AgenticLoop.config.json` | Replace every `TODO`: the build matrix entries and the build/test/quality commands. The loop refuses to start while any remain, naming each one — so you cannot silently run a half-filled template. |
| `Run-AgenticLoop.ps1` | `scripts/agentic-loop/Run-AgenticLoop.ps1` | Nothing, unless your submodule path differs. |
| `Run-AgenticLoop.sh` | `scripts/agentic-loop/Run-AgenticLoop.sh` | Same. `chmod +x`. |

You also need a `BACKLOG.md` at the repo root using the checkbox protocol:
`- [ ]` actionable, `- [b]` blocked (skipped by the executor and excluded
from the pending count, so a backlog of only blocked entries lets the planner
run again), `- [x]` done (pruned automatically — history lives in git).

Optionally add project system prompts (`scripts/agentic-loop/prompts/*.md`)
describing your conventions; they are passed per engine and are separate from
the per-phase **task** prompts, which default to `../prompts/*.md` here and
should not be duplicated into a consumer.

## What the wrappers deliberately do not do

They pass no prompt text and no build-config list. Both default from the
shared prompt files and from the config's `buildMatrix`. Hard-coding either in
a wrapper is what let the Windows and Linux copies drift apart until the
Windows side had silently lost the blocked-task protocol and the
foreground-build discipline.

## Before running it unattended

- The loop auto-commits with `git add -A`. Do not run interactive work in the
  same tree without checking whether the loop is live.
- It does not watch CI. It will happily keep committing over a red pipeline.
- The executor is a one-shot headless session: it must run builds in the
  foreground, because anything backgrounded is orphaned when the session ends.

Full wiring checklist: [`../../../docs/adopting-in-a-new-project.md`](../../../docs/adopting-in-a-new-project.md).

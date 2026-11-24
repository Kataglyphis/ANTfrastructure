<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Writing docs

How to write a page, an `AGENTS.md` rule or a failure entry in this family, so that an agent can act
on it and a person can read it. The rules hold in the hub and in every consumer. The `doc-prose`
gate measures four of them.

## Where text goes

| Text | Home |
|---|---|
| A rule an agent must not break | `AGENTS.md`, in one or two sentences |
| How something works, how to run it, what breaks | the `docs/` page that owns the topic; [INDEX.md](INDEX.md) names it |
| What changed, and when | `CHANGELOG.md` |
| Open work | `BACKLOG.md` |
| An owner decision, its date and its reason | [decisions.md](decisions.md) |
| A family term such as receipt, floor or lane | [glossary.md](glossary.md) |

`AGENTS.md` changes only for a new or changed rule. A README changes only for a new entry point.

## The rules

Each rule has one pair from a real page: the text before, and the same facts after.

### 1. Put the instruction first

Start with what to do. The reason follows in one clause.

| Before | After |
|---|---|
| **Owner rule for every repo of the family (2026-10-05).** Search with `rg`, not `grep -r` or `findstr`. | Search with `rg`, not `grep -r` or `findstr`: it skips ignored build trees and binaries. |

### 2. Keep dates and ids out of instructions

Dates, decision ids, run ids and hashes belong in `CHANGELOG.md`, `BACKLOG.md` and
[decisions.md](decisions.md). An instruction states the rule and its reason.

| Before | After |
|---|---|
| Switched ON on 2026-10-01 (hub CON9: the image ships `clang_rt.profile`), the Debug suite died at process exit in the profile writer … after all 654 tests had passed (run 36997000491). | Keep coverage off for the ClangCL presets. With ASan on, the profile runtime comes from Microsoft's ASan DLL and crashes at process exit, so the test executables exit 1 even when every test passed. Coverage is measured on Linux. |

### 3. Write short sentences

Aim for 15 to 20 words. A sentence over 30 words is rare, and it says one thing.

| Before | After |
|---|---|
| Explicit local FINAL acceptance retains the complete canonical consumer plan, its own immutable manifest/config and successful producer/source/cleanup bindings before and after checks; its schema-2 receipt cannot promote a registry tag. | Local FINAL acceptance keeps the full consumer plan, its own manifest and config, and the producer, source and cleanup bindings. It checks them before and after the run. Its schema 2 receipt cannot promote a registry tag. |

### 4. Use plain words, and explain a family term

Prefer the common word. When a family term is the right word, link it to [glossary.md](glossary.md)
the first time a page uses it. A mechanism goes to its own page, not into the rulebook.

| Before | After |
|---|---|
| GPU admission requires the exact qualified SDK, rehashed native blobs and compiler ancestry, complete source proof, fresh local alias, idle host and unchanged disk floor. | Before a GPU stage starts, the launcher checks that the SDK is the qualified one, that the native blobs and the compiler ancestry re-hash, that the source has a complete proof, that the local image alias is fresh, that no other build runs and that free disk has not dropped. If one check fails, the stage does not start. |

### 5. Turn a chain of clauses into a list

Steps, rules and conditions go in a numbered or bulleted list, one per line.

| Before | After |
|---|---|
| Its five rules: a candidate scores its objectness times its best class score, or its best class score alone, …; it needs at least the threshold; its corners come from its centre and size in model-input pixels; the candidates are taken in descending score, … above 0.45, …; the survivors come in that order, mapped and cut as decode rule 5 says. | 1. A candidate's score is its objectness times its best class score, or that class score alone.<br>2. A candidate below the threshold is dropped.<br>3. Its corners come from its centre and size, in model-input pixels.<br>4. Candidates go in descending score. Each suppresses every later one of its class whose IoU with it is above 0.45.<br>5. The survivors keep that order and are mapped and cut as decode rule 5 says. |

### 6. Start a page with its purpose

The first paragraph says what the page is for. The newest note goes into the section it is about.

| Before | After |
|---|---|
| IREE's x86-64-v3 floor coexists with explicit clang-cl AVX512 flags on its dispatched kernels. … The 24908390 NVIDIA attempt stopped in this kernel compilation … | The reference for the Windows image: what is installed, how it is built and how it is checked. (The IREE note moves to the IREE section.) |

### 7. Name a section after its topic

A heading says what the section is about, not where the text came from.

| Before | After |
|---|---|
| ## Version bumping, as AGENTS.md carried it<br>Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading, … | ## Bumping a pin by hand<br>The rules are in `AGENTS.md` § Version Bumping. This is the procedure. |

### 8. Give each topic one owning page

State a fact once, on the page [INDEX.md](INDEX.md) names for it. Every other page links there. A
copy drifts, and the `doc-dupes` gate fails a copied passage.

| Before | After |
|---|---|
| `jq` is *not* in the Linux image. (The image script installed it, and `AGENTS.md` said the opposite.) | What the Linux image carries: [consumer-image-contract.md](consumer-image-contract.md). |

### 9. Derive a number, or test it

A typed count goes stale. Write the sentence without the number, or let a script write it and a
test check it, as `test-doc-numbers.sh` does.

| Before | After |
|---|---|
| All fifteen, with every input and output, are listed once in … (the folder held more than 25 actions by then) | Every action, with its inputs and outputs, is listed once in … |

### 10. Say what a thing does, not what it keeps

Write how to use a helper and what it checks. "Carries", "retains" and "does not prove" describe
evidence; a reader needs the instruction.

| Before | After |
|---|---|
| Windows GPU MSI/MSIX payload checks share the installer extraction and process cleanup helpers; extraction does not prove installation. | The Windows GPU MSI and MSIX payload checks use the shared installer extraction and process cleanup helpers. They read the payload; they do not install it. |

### 11. Use bold for the one thing a reader must not miss

One bold phrase in a section, at most. No capitals for emphasis.

| Before | After |
|---|---|
| **Cause.** **ROOT CAUSE FOUND & FIXED 2026-08-06: the runhcs shim's hardcoded `tearDownTimeout = 30s`** (`cmd/containerd-shim-runhcs-v1/task_hcs.go`) terminates the heavy-churn silo teardown mid-hive-flush (real duration: **117 s measured** for OpenCV) … | Cause: the runhcs shim's hard-coded `tearDownTimeout = 30s` (`task_hcs.go`) ends a heavy silo teardown in the middle of its hive flush. OpenCV's teardown takes about 117 s. |

### 12. Keep a README line short

A README is an overview. One line points to one page.

| Before | After |
|---|---|
| One line that lists every accelerator with its versions, links and caveats. | **Accelerators**: Hailo-10H in `:latest`, CUDA and DeepStream in `:latest-nvidia`, MIGraphX in `:latest-rocm`. See [accelerator images](linux-accelerator-images.md). |

## Templates

### A topic page

```markdown
# <Topic>

<One or two sentences: what this is and when you need it.>

## How to <do the common task>

<The command, where it runs (host or CI image), and what success looks like.>

## Reference

<Options, files and tables. Let a script write what it can.>

## Traps

<Each trap: what goes wrong, why, and what to do instead.>
```

### A failure entry

The heading is the error text, so a search for the message finds it. Keep the entry under about
150 words. History goes to `CHANGELOG.md`.

```markdown
### `<the error text, exactly as printed>`

Symptom: <what you see, and where>.
Cause: <why it happens, in one or two sentences>.
Fix: <the command or change that fixes it>.
```

### A "Common tasks" block for AGENTS.md

It sits near the top of `AGENTS.md`. Each row is an exact command and the place it runs. A command
that needs the CI image says so, through `run-in-ci-image.sh`
([shared-script-libraries.md](shared-script-libraries.md#run-in-ci-imagesh--run-a-command-in-the-ci-image)).
The rows below show the shape for a CMake repo; write the repo's own commands.

```markdown
## Common tasks

| Task | Command | Runs in |
|---|---|---|
| Build | `cmake --build build -j2` | CI image |
| Test | `ctest --test-dir build -j2` | CI image |
| Lint gates | `bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh . --ratchets` | host |
| Docs | `<the repo's docs build>` | <host or CI image> |
```

### A README

Follow [repository-family.md § The README rule](repository-family.md#the-readme-rule).

## How the gate checks it

The `doc-prose` gate measures each page's average sentence length, its share of sentences over 30
words, its dates and decision ids per 1000 words and its bold per 1000 words. A page in the census
may only get better. A page without census rows must stay within 22 words per sentence, 15 % long
sentences and 2 dates or ids per 1000 words. `AGENTS.md` also has a word budget. The details:
[code-quality-tooling.md § Doc prose](code-quality-tooling.md#doc-prose-doc-prose).

# Consumer templates

Copy-and-edit starting points that are not language-specific. (The Windows
PowerShell bootstrap lives in [`../windows/templates/`](../windows/templates/README.md);
the agentic-loop config and runners in [`../agentic-loop/templates/`](../agentic-loop/templates/README.md).)

| File | Copy to | Then |
|---|---|---|
| `AGENTS.md.template` | `<your-repo>/AGENTS.md` | Fill in sections 1, 3, 4 and 5. Leave section 2 as links. |

## What the layout is for

One rule decides where any piece of knowledge goes:

> **Would this still be true in a different project?**
> Yes → ContainerHub owns it; link to it. No → write it out in your repo.

The template's sections encode that split:

- **§1 what this project is** — yours
- **§2 what ContainerHub owns** — *links only*, no procedures
- **§3 project-specific pitfalls** — yours, written out in full
- **§4 build/run/test** — yours
- **§5 docs owned here** — yours

Section 2 being links-only is the load-bearing part. A procedure retyped into a
consumer starts drifting immediately: on 2026-08-11 the Dev Drive filter command
existed in three places and **all three were wrong the same way**, while the
owning document had it right and even warned about that exact mistake. See
[`../../docs/INDEX.md`](../../docs/INDEX.md).

## The one thing not to automate

Do not add a lint that fails a consumer doc for mentioning `wcifs`,
`--isolation process` or similar. A keyword cannot distinguish *restating* an
upstream procedure from *applying* it. OmniAccelerANT's
AddressSanitizer notes discuss image-level runtimes legitimately, because which
ASan runtime a Flutter/COM application survives is a property of that
application. Reviewing this needs a person reading the paragraph.

# Archived probes — RETIRED, do not refill

This directory is empty and should be deleted along with this file. It is kept
here only because removing it needs the owner's sign-off (nothing in the tree
references it).

Its six remaining one-shot probes were deleted — git history is the record for a
probe whose question is settled — and `Test-SccacheWrite.ps1`, which was never
settled, moved back out to `../Test-SccacheWrite.ps1`, where
`Dockerfile.sccache-write-probe` and `Dockerfile.media-builder` now name it.

**Do not re-create the facility.** Its central promise — "still runnable without
restoration" via `Invoke-DiagnosticProbe.ps1 -ProbeScript archive/<name>.ps1` —
was never true. `.dockerignore` carries `**/archive/`, and `Dockerfile.probe`
bind-mounts `windows/scripts/diagnostics` FROM the build context, so an archived
probe is stripped before the build starts. `Invoke-DiagnosticProbe.ps1` checks
the path on the HOST (where it exists) and fails only later, inside the solve.
Archiving a probe here silently made it unrunnable; deleting it says so honestly.

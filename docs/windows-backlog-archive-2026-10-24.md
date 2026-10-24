# Windows backlog archive — 2026-10-24

Moved from [`windows-refactor-backlog.md`](windows-refactor-backlog.md) after the
PowerShell complexity refactor. This records source-level checks, not a new
container-chain build.

- **PowerShell complexity. CLOSED in source 2026-10-24.** The PowerShell 7 AST
  scanner reports 0 findings across 467 tracked files and 2,994 script,
  function and method units. It had 140 findings before this work and 123 after
  the first pass. Windows x64 CI now enforces all tracked PowerShell with
  `Invoke-CodeComplexity.ps1 -Strict` and the unchanged 15/5/80 limits. Focused
  suites cover the refactored production scripts and test harnesses. A local
  `-Path <file-or-dir> -Strict` scan also covers files Git has not tracked yet.

- **PowerShell duplication. CLOSED at a measured budget 2026-10-24.** Real
  copies were given shared owners and 25 existing budgets fell; 30 stale rows
  left the allowlist. The remaining `WindowsBuildSweep.Common.psm1` and
  `WindowsTvm.Common.psm1` overlap is 12 normalized shingles of mandatory
  parameter and list syntax, with a longest identical run of three lines.
  Their container and wheel functions have no shared behavior. The owner
  approved one budget-12 exception; the two-way duplication gate still fails
  if this overlap grows or shrinks without updating its measurement. The
  solve-order test also switched from regex text scans to AST command binding,
  removing its unrelated match with `Invoke-StagedTests.ps1` while detecting
  multiline calls, commented decoys and wrong parents.

# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NOTE ON THE POWERSHELL VERSION: this is the one file in the repo that is NOT
# `#requires -Version 7.0`. It is LAUNCHED with pwsh 7 (see the hook command in
# .claude/settings.json) like everything else, but it is written to run under
# Windows PowerShell 5.1 as well, and the hook falls back to it if pwsh cannot
# start. Reason: a PreToolUse guard that fails to launch fails OPEN - the tool
# call proceeds unguarded. pwsh is an installed program, and installed programs
# are exactly what went missing on 2026-08-21. The always-present 5.1 fallback
# is what makes this guard survive the failure mode it exists to prevent. Keep
# it 5.1-safe: no ternaries, no ??, no pwsh-only cmdlets.
#
# PreToolUse guard: refuses destructive deletes / uninstalls that reach OUTSIDE
# the reclaimable set.
#
# WHY THIS EXISTS (2026-08-21): a "free some disk space" command written by an
# agent did not stop at the container stores - it walked into installed
# programs and the user profile, and every application on the host (editor,
# VCS, GPU driver stack, container runtime) had to be reinstalled by hand. No
# permission prompt stood in the way, because a blanket delete rule had been
# allow-listed. This guard is the mechanical stop that was missing.
#
# It is deliberately BLUNT and FAIL-CLOSED on the protected roots: a delete
# that mentions Program Files, C:\Windows, C:\ProgramData (outside the
# container stores), a user profile, AppData or a drive root is DENIED - not
# "asked". Denied means no prompt can wave it through. If such a delete is
# genuinely wanted, a human runs it themselves, outside the agent.
#
# It guards two vectors, because the 2026-08-21 incident used the second one:
#   1. commands the agent runs   (Bash / PowerShell tool)
#   2. commands the agent WRITES for the user to paste (Write / Edit tool)
#
# Contract: reads the PreToolUse hook payload as JSON on stdin (or -InputJson
# for tests), prints a permission decision on stdout, always exits 0.
# Silence = no opinion, the normal permission flow continues.

[CmdletBinding()]
param([string]$InputJson)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- payload ---
if (-not $InputJson) {
    try { $InputJson = [Console]::In.ReadToEnd() } catch { exit 0 }
}
if ([string]::IsNullOrWhiteSpace($InputJson)) { exit 0 }
try { $ev = $InputJson | ConvertFrom-Json } catch { exit 0 }

function Write-Decision {
    param([ValidateSet('deny', 'ask')][string]$Decision, [string]$Reason)
    $payload = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
    }
    Write-Output ($payload | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

# ------------------------------------------------------------- predicates ---
# Verbs are matched on the text with QUOTED SPANS REMOVED, so that reading
# about a delete (grep 'Remove-Item', a doc quoting a command) is not itself
# treated as one. Paths are matched on the FULL text, because the path of a
# real delete usually lives inside those quotes.

$verbPattern =
    '(?<!git )(?:\bremove-item\b|\bremove-itemproperty\b|\bclear-content\b|' +
    '\brmdir\b|\brd\b|\bdel\b|\berase\b|\bunlink\b|\brm\b|\bri\b|' +
    '\bclear-disk\b|\bremove-partition\b|\bformat-volume\b|\bdiskpart\b|\bsystemreset\b|' +
    '\bremove-appxpackage\b|\buninstall-package\b|\buninstall-module\b|\bmsiexec[^\r\n]*/x|' +
    '\bcipher[^\r\n]*/w|robocopy[^\r\n]*/mir|' +
    '\bwinget\s+uninstall\b|\bchoco\s+uninstall\b|\bscoop\s+uninstall\b|\bnpm\s+uninstall\s+-g\b)'

# Uninstalling the user's software is never the agent's call, whatever the path.
$uninstallPattern =
    '(\bwinget\s+uninstall\b|\bchoco\s+uninstall\b|\bscoop\s+uninstall\b|\buninstall-package\b|' +
    '\bremove-appxpackage\b|\bmsiexec[^\r\n]*/x|\bsystemreset\b)'

# Blanked out BEFORE the protected test: the genuinely reclaimable set.
$reclaimable = @(
    'c:\programdata\containerd'
    'c:\programdata\buildkitd'
    'c:\programdata\docker'
    'c:\programdata\kataglyphis'
    '\appdata\local\temp'
    'c:\windows\temp'
    'c:\temp'
    'c:\bkmnt'
    '$env:temp'
    '%temp%'
    'd:\github\kataglyphis-containerhub'
)

# Any of these under a delete verb = hard stop. Everything a host needs to
# stay a working host, plus the profile that carries the user's settings.
$protectedPatterns = @(
    @{ Rx = 'c:\\program files'; What = 'C:\Program Files' }
    @{ Rx = 'c:\\windows'; What = 'C:\Windows' }
    @{ Rx = 'c:\\programdata'; What = 'C:\ProgramData (outside the container stores)' }
    @{ Rx = 'c:\\users'; What = 'a user profile under C:\Users' }
    @{ Rx = '\\c\\users'; What = 'a user profile (/c/Users)' }
    @{ Rx = '\\c\\program files'; What = '/c/Program Files' }
    @{ Rx = '\$env:userprofile|%userprofile%|\$home'; What = 'the user profile root' }
    @{ Rx = '\$env:appdata|\$env:localappdata|%appdata%|%localappdata%'; What = 'AppData' }
    @{ Rx = '\\appdata\\'; What = 'AppData' }
    @{ Rx = '\\\.vscode|\\scoop|\\\.ssh|\\\.gitconfig|\\\.claude|\\\.aws|\\\.docker'; What = 'a per-user tool or config directory' }
    @{ Rx = '(^|[\s''"=])[a-z]:\\(\*|\s|$|''|")'; What = 'a drive root' }
    @{ Rx = '(^|\s)-(r|rf|fr)\s+\\(\s|$)'; What = 'the filesystem root' }
    # Near = only counts when a delete verb sits within N characters of the
    # match. Every other pattern above is PATH-SHAPED (it carries a `\` or a
    # drive letter), so it cannot collide with prose. This one is bare English
    # words, and the repo's own documentation is full of them: a page that says
    # "an ENABLED AMD RDNA4 dGPU" and, three thousand characters later, shows a
    # `nerdctl run --rm` example was denied, because `--rm` matches \brm\b and
    # the vendor word matched anywhere in the same text. That fired on ordinary
    # docs edits six times on 2026-08-25.
    #
    # Proximity is the right primitive here, NOT same-line matching: a real
    # script assigns the path on one line and deletes on the next, and a
    # line-scoped rule would stop seeing it. 200 characters comfortably spans
    # that shape while excluding unrelated prose. The window is measured on the
    # quote-retaining text, so a QUOTED verb near the token still denies --
    # deliberately the conservative direction for a safety gate.
    @{ Rx = 'nvidia|adrenalin|radeon'; What = 'a GPU driver installation'; Near = 200 }
)

function Test-DestructiveText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $bare = [regex]::Replace($Text, "'[^']*'", ' ')
    $bare = [regex]::Replace($bare, '"[^"]*"', ' ')
    $bare = $bare.ToLowerInvariant()

    $hasVerb = [regex]::IsMatch($bare, $verbPattern)
    $hasUninstall = [regex]::IsMatch($bare, $uninstallPattern)
    if (-not $hasVerb -and -not $hasUninstall) { return $null }

    if ($hasUninstall) {
        return @{ Decision = 'deny'; Reason = 'uninstalls software on this host' }
    }

    # Normalise the FULL text for path matching: lowercase, forward slashes to
    # backslashes, then blank out the reclaimable roots so that a legitimate
    # store cleanup does not read as a profile delete.
    $norm = $Text.ToLowerInvariant().Replace('/', '\')
    foreach ($ok in $reclaimable) { $norm = $norm.Replace($ok.ToLowerInvariant(), ' <reclaimable> ') }

    foreach ($p in $protectedPatterns) {
        if (-not $p.ContainsKey('Near')) {
            if ([regex]::IsMatch($norm, $p.Rx)) {
                return @{ Decision = 'deny'; Reason = ('deletes from ' + $p.What) }
            }
            continue
        }
        # Proximity-scoped pattern: every occurrence is checked, so a token that
        # appears once in prose and once beside a delete still denies.
        foreach ($m in [regex]::Matches($norm, $p.Rx)) {
            $lo = [Math]::Max(0, $m.Index - $p.Near)
            $hi = [Math]::Min($norm.Length, $m.Index + $m.Length + $p.Near)
            if ([regex]::IsMatch($norm.Substring($lo, $hi - $lo), $verbPattern)) {
                return @{ Decision = 'deny'; Reason = ('deletes from ' + $p.What) }
            }
        }
    }

    # Outside the protected roots a recursive/wildcard delete is not forbidden,
    # but it never happens silently either.
    if ([regex]::IsMatch($bare, '(-recurse\b|-force\b|\s-r\b|\s-rf\b|\s-fr\b|/s\b|\*)')) {
        return @{ Decision = 'ask'; Reason = 'is a recursive or wildcard delete' }
    }

    return $null
}

# ------------------------------------------------------------------ route ---
$tool = [string]$ev.tool_name
$in = $ev.tool_input

# Files whose whole job is to describe or test these patterns.
$exemptNames = @('guard-destructive-deletes.ps1', 'guard.destructivedeletes.tests.ps1', 'Clear-DiskSpace.ps1')

switch -Regex ($tool) {
    '^(Bash|PowerShell)$' {
        $verdict = Test-DestructiveText ([string]$in.command)
        if ($verdict) {
            Write-Decision -Decision $verdict.Decision -Reason (
                'Blocked by guard-destructive-deletes: this command ' + $verdict.Reason + '. ' +
                'Host disk reclaim goes through windows\scripts\host\Clear-DiskSpace.ps1 ' +
                '(allowlisted paths, report-only by default). A delete that must reach a ' +
                'protected root is for the user to run themselves, not the agent.')
        }
        break
    }
    '^(Write|Edit|MultiEdit)$' {
        $path = [string]$in.file_path
        $leaf = ''
        if ($path) { $leaf = ([System.IO.Path]::GetFileName($path)).ToLowerInvariant() }
        if ($exemptNames -contains $leaf) { break }

        $body = [string]$in.content
        if (-not $body) { $body = [string]$in.new_string }
        $verdict = Test-DestructiveText $body
        if ($verdict -and $verdict.Decision -eq 'deny') {
            Write-Decision -Decision 'deny' -Reason (
                'Blocked by guard-destructive-deletes: this file content ' + $verdict.Reason + '. ' +
                'Handing the user a script that deletes from a protected root is the exact ' +
                'shape of the 2026-08-21 host wipe. Route the reclaim through ' +
                'windows\scripts\host\Clear-DiskSpace.ps1 instead.')
        }
        break
    }
}

exit 0

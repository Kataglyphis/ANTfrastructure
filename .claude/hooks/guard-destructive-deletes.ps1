# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# PreToolUse delete guard; stays Windows PowerShell 5.1-safe because the hook falls back to 5.1 and a guard that cannot launch fails open.

[CmdletBinding()]
param([string]$InputJson)

$ErrorActionPreference = 'Stop'

# Payload
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
)
# No repo checkout belongs in that list; Guard.DestructiveDeletes.Tests.ps1 makes adding one a deliberate decision.

# A delete verb on any of these is denied outright, never asked.
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
    # Bare words collide with prose, so Near scopes them to N chars around a delete verb (proximity, not same line: scripts assign then delete).
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

    # Blank out the reclaimable roots so a store cleanup does not read as a profile delete.
    $norm = $Text.ToLowerInvariant().Replace('/', '\')
    foreach ($ok in $reclaimable) { $norm = $norm.Replace($ok.ToLowerInvariant(), ' <reclaimable> ') }

    foreach ($p in $protectedPatterns) {
        if (-not $p.ContainsKey('Near')) {
            if ([regex]::IsMatch($norm, $p.Rx)) {
                return @{ Decision = 'deny'; Reason = ('deletes from ' + $p.What) }
            }
            continue
        }
        # Check every occurrence: a token once in prose and once beside a delete still denies.
        foreach ($m in [regex]::Matches($norm, $p.Rx)) {
            $lo = [Math]::Max(0, $m.Index - $p.Near)
            $hi = [Math]::Min($norm.Length, $m.Index + $m.Length + $p.Near)
            if ([regex]::IsMatch($norm.Substring($lo, $hi - $lo), $verbPattern)) {
                return @{ Decision = 'deny'; Reason = ('deletes from ' + $p.What) }
            }
        }
    }

    # Outside the protected roots a recursive or wildcard delete is allowed, but never silently.
    if ([regex]::IsMatch($bare, '(-recurse\b|-force\b|\s-r\b|\s-rf\b|\s-fr\b|/s\b|\*)')) {
        return @{ Decision = 'ask'; Reason = 'is a recursive or wildcard delete' }
    }

    return $null
}

# Route
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

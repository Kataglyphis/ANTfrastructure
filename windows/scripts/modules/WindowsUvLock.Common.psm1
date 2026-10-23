#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest

# Both image assembly and consumer sync must exclude exactly the lock's ORT names.
function Get-OrtLockPackageName {
    param([Parameter(Mandatory)][string]$LockPath, [string]$DiagnosticPrefix = '')
    $text = [System.IO.File]::ReadAllText($LockPath)
    $tables = [regex]::Matches($text, '(?m)^\[\[package\]\]\r?$').Count
    $names = @([regex]::Matches($text, '(?m)^name = "([^"\r\n]*)"\r?$') | ForEach-Object { ($_.Groups[1].Value -replace '[-_.]+', '-').ToLowerInvariant() })
    if (-not $tables -or $names.Count -ne $tables) { throw "${DiagnosticPrefix}cannot read the packages of ${LockPath}: $($names.Count) name(s) for $tables [[package]] table(s)" }
    $ort = @($names | Where-Object { $_ -cmatch '^onnxruntime(-|$)' } | Sort-Object -Unique)
    $bad = @($ort | Where-Object { $_ -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$' })
    if ($bad.Count) { throw "${DiagnosticPrefix}${LockPath} pins an ORT name uv sync cannot be handed: $($bad -join ', ')" }
    return $ort
}

Export-ModuleMember -Function Get-OrtLockPackageName

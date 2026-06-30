# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$versionsFile = Join-Path $env:TEMP_DIR 'versions.env'
if (-not (Test-Path $versionsFile)) {
    Write-Host 'versions.env not found — skipping'
    return
}

Write-Host "Loading versions from: $versionsFile"
Get-Content $versionsFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line -notmatch '^#') {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $name = $parts[0].Trim()
            $value = $parts[1].Trim().Trim('"', "'")
            [Environment]::SetEnvironmentVariable($name, $value, 'Machine')
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            Write-Host "  $name = $value"
        }
    }
}
Write-Host 'versions.env loaded'

# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Enable long paths for deep CMake/npm/cargo dependency trees
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
# Trust all directories as git-safe (suppresses ownership mismatch in container)
git config --global --add safe.directory '*'
if ($LASTEXITCODE -ne 0) { throw "git config --global --add safe.directory '*' failed (exit code $LASTEXITCODE)" }
# Enable git to handle paths >260 characters
git config --global core.longpaths true
if ($LASTEXITCODE -ne 0) { throw "git config --global core.longpaths true failed (exit code $LASTEXITCODE)" }

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0
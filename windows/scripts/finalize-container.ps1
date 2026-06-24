# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Enable long paths for deep CMake/npm/cargo dependency trees
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
# Trust all directories as git-safe (suppresses ownership mismatch in container)
git config --global --add safe.directory '*'
# Enable git to handle paths >260 characters
git config --global core.longpaths true

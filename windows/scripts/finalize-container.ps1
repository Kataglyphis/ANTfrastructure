$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
git config --global --add safe.directory '*'
git config --global core.longpaths true

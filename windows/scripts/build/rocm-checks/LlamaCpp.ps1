# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm-check for llama.cpp's HIP build: pinned bytes and licence, off PATH, linkable against ROCm, runnable.
.DESCRIPTION
    Writes one finding per defect; none is a pass. Needs no GPU: it reads files, PE import and
    export tables and ggml-hip's first offload bundle, then runs llama-server --version, which
    loads no ggml backend. NOT covered: delay-loaded imports, and whether a kernel runs on a
    device. Also run at build time by windows/Dockerfile.rocm-llama. docs/windows-builds.md § ROCm layer.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    File offset of an RVA, over the section table the BCL parsed; throws when no section holds it.
#>
function ConvertTo-PeFileOffset {
    param([Parameter(Mandatory)][System.Reflection.PortableExecutable.PEHeaders]$Headers, [Parameter(Mandatory)][uint32]$Rva)
    foreach ($section in $Headers.SectionHeaders) {
        $span = [Math]::Max($section.VirtualSize, $section.SizeOfRawData)
        if ($Rva -ge $section.VirtualAddress -and $Rva -lt ($section.VirtualAddress + $span)) {
            return [int64]$section.PointerToRawData + ($Rva - $section.VirtualAddress)
        }
    }
    throw ('RVA 0x{0:X} lies in no section' -f $Rva)
}

<#
.SYNOPSIS
    The NUL-terminated ASCII string at a file offset.
#>
function Read-PeString {
    param([Parameter(Mandatory)][System.IO.BinaryReader]$Reader, [Parameter(Mandatory)][int64]$Offset)
    $Reader.BaseStream.Position = $Offset
    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt 65536) {
        $b = $Reader.ReadByte()
        if ($b -eq 0) { break }
        $bytes.Add($b)
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

<#
.SYNOPSIS
    Runs $Action with a seeking reader over a PE and the headers the BCL parsed: ggml-hip.dll is ~1 GB, never read whole.
#>
function Invoke-PeReader {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Action)
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try { & $Action $reader ([System.Reflection.PortableExecutable.PEHeaders]::new($reader.BaseStream)) }
    finally { $reader.Dispose() }
}

<#
.SYNOPSIS
    A PE's static imports (DLL -> names, '#<n>' for an ordinal) and its export names (ordinal-case HashSet), in one open.
#>
function Get-PeSymbolTable {
    param([Parameter(Mandatory)][string]$Path)
    Invoke-PeReader -Path $Path -Action { param($reader, $headers)
        $width = if ($headers.PEHeader.Magic -eq [System.Reflection.PortableExecutable.PEMagic]::PE32Plus) { 8 } else { 4 }
        $imports = [ordered]@{}
        $importRva = $headers.PEHeader.ImportTableDirectory.RelativeVirtualAddress
        $descriptor = if ($importRva) { ConvertTo-PeFileOffset -Headers $headers -Rva $importRva } else { -1 }
        while ($descriptor -ge 0) {
            $reader.BaseStream.Position = $descriptor
            $lookupRva = $reader.ReadUInt32(); [void]$reader.ReadUInt64(); $nameRva = $reader.ReadUInt32(); $iatRva = $reader.ReadUInt32()
            if ($nameRva -eq 0) { break }
            $dll = Read-PeString -Reader $reader -Offset (ConvertTo-PeFileOffset -Headers $headers -Rva $nameRva)
            $thunk = ConvertTo-PeFileOffset -Headers $headers -Rva $(if ($lookupRva) { $lookupRva } else { $iatRva })
            $names = [System.Collections.Generic.List[string]]::new()
            while ($true) {
                $reader.BaseStream.Position = $thunk
                $entry = if ($width -eq 8) { $reader.ReadUInt64() } else { [uint64]$reader.ReadUInt32() }
                if ($entry -eq 0) { break }
                if (($entry -shr ($width * 8 - 1)) -ne 0) { $names.Add('#' + ($entry -band 0xFFFF)) }
                else { $names.Add((Read-PeString -Reader $reader -Offset ((ConvertTo-PeFileOffset -Headers $headers -Rva ([uint32]($entry -band 0x7FFFFFFF))) + 2))) }
                $thunk += $width
            }
            $imports[$dll] = @(if ($imports.Contains($dll)) { $imports[$dll] }) + $names.ToArray()
            $descriptor += 20
        }
        $exports = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $exportRva = $headers.PEHeader.ExportTableDirectory.RelativeVirtualAddress
        if ($exportRva) {
            $directory = ConvertTo-PeFileOffset -Headers $headers -Rva $exportRva
            $reader.BaseStream.Position = $directory + 24
            $count = $reader.ReadUInt32()
            $reader.BaseStream.Position = $directory + 32
            $namesAt = ConvertTo-PeFileOffset -Headers $headers -Rva $reader.ReadUInt32()
            for ($i = 0; $i -lt $count; $i++) {
                $reader.BaseStream.Position = $namesAt + 4 * $i
                [void]$exports.Add((Read-PeString -Reader $reader -Offset (ConvertTo-PeFileOffset -Headers $headers -Rva $reader.ReadUInt32())))
            }
        }
        [pscustomobject]@{ Imports = $imports; Exports = $exports }
    }
}

<#
.SYNOPSIS
    The gfx targets one uncompressed clang offload bundle header names.
#>
function Get-ClangOffloadBundleTarget {
    param([Parameter(Mandatory)][byte[]]$Header)
    $magic = '__CLANG_OFFLOAD_BUNDLE__'
    if ($Header.Length -lt 32 -or [System.Text.Encoding]::ASCII.GetString($Header, 0, 24) -ne $magic) {
        $start = [System.Text.Encoding]::ASCII.GetString($Header, 0, [Math]::Min(4, $Header.Length))
        throw "not an uncompressed clang offload bundle (starts '$start'; 'CCOB' is the compressed form)"
    }
    $count = [BitConverter]::ToUInt64($Header, 24)
    if ($count -gt 4096) { throw "implausible offload bundle entry count $count" }
    $at = 32
    $targets = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        if ($at + 24 -gt $Header.Length) { throw "offload bundle header truncated after $i of $count entries" }
        $idLength = [BitConverter]::ToUInt64($Header, $at + 16)
        $at += 24
        if ($at + $idLength -gt $Header.Length) { throw "offload bundle entry $i runs past the header" }
        $id = [System.Text.Encoding]::ASCII.GetString($Header, $at, [int]$idLength)
        $at += [int]$idLength
        $m = [regex]::Match($id, 'amdgcn-amd-amdhsa-[^-]*-(gfx[0-9a-z]+)')
        if ($m.Success) { $targets.Add($m.Groups[1].Value) }
    }
    return $targets.ToArray()
}

<#
.SYNOPSIS
    gfx targets of a HIP binary's device code, from the first bundle in its .hip_fat section.
#>
function Get-HipOffloadTarget {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxHeaderBytes = 65536)
    Invoke-PeReader -Path $Path -Action { param($reader, $headers)
        $section = @($headers.SectionHeaders | Where-Object { $_.Name -eq '.hip_fat' }) | Select-Object -First 1
        if ($null -eq $section) { throw "$Path has no .hip_fat section (no HIP device code)" }
        $reader.BaseStream.Position = $section.PointerToRawData
        Get-ClangOffloadBundleTarget -Header $reader.ReadBytes([Math]::Min($MaxHeaderBytes, $section.SizeOfRawData))
    }
}

<#
.SYNOPSIS
    The first of the search directories (loader order) that holds the DLL, or $null.
#>
function Resolve-LoaderDll {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SearchDir)
    foreach ($dir in $SearchDir) {
        if (-not $dir) { continue }
        $candidate = [System.IO.Path]::Combine($dir, $Name)
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

<#
.SYNOPSIS
    True when two directory spellings name the same directory.
#>
function Test-SameDirectory {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    return [string]::Equals([System.IO.Path]::GetFullPath($Left).TrimEnd('\'), [System.IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase)
}

<#
.SYNOPSIS
    Walks ggml-hip.dll's static imports through the loader order into ROCm: each must resolve, come
    from where it belongs (or a byte-identical copy), and export every name imported from it.
#>
function Get-LlamaCppHipLinkFinding {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$RocmBin,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SearchDir,
        # The HIP runtime that must load from $Dir; matches Install-LlamaCppHip.ps1's.
        [string]$RuntimePattern = '^(amdhip64_\d+|amd_comgr(_\d+)?|rocm_kpack)\.dll$'
    )
    $findings = [System.Collections.Generic.List[string]]::new()
    # Every PE read once; a file is walked when its table is first read.
    $root = Join-Path $Dir 'ggml-hip.dll'
    $tables = @{ $root = Get-PeSymbolTable -Path $root }
    $walk = [System.Collections.Generic.Queue[string]]::new([string[]]@($root))
    while ($walk.Count -gt 0) {
        $file = $walk.Dequeue()
        $leaf = [System.IO.Path]::GetFileName($file)
        $imports = $tables[$file].Imports
        foreach ($dll in @($imports.Keys)) {
            if ($dll -match '^(api|ext)-ms-') { continue }
            $hit = Resolve-LoaderDll -Name $dll -SearchDir $SearchDir
            if (-not $hit) { $findings.Add("$leaf imports $dll, which nothing on the loader path provides"); continue }
            if ([System.IO.File]::Exists((Join-Path $RocmBin $dll))) {
                $wantDir = if ($dll -match $RuntimePattern) { $Dir } else { $RocmBin }
                $want = Join-Path $wantDir $dll
                if (-not (Test-SameDirectory -Left (Split-Path $hit -Parent) -Right $wantDir) -and
                    (-not [System.IO.File]::Exists($want) -or (Get-FileHash -LiteralPath $hit).Hash -ne (Get-FileHash -LiteralPath $want).Hash)) {
                    $findings.Add("$leaf loads $dll from $hit, not $want")
                }
            }
            $owned = (Test-SameDirectory -Left (Split-Path $hit -Parent) -Right $Dir) -or (Test-SameDirectory -Left (Split-Path $hit -Parent) -Right $RocmBin)
            if (-not $owned) { continue }
            if (-not $tables.ContainsKey($hit)) {
                $tables[$hit] = Get-PeSymbolTable -Path $hit
                $walk.Enqueue($hit)
            }
            $missing = @($imports[$dll] | Where-Object { $_ -notlike '#*' -and -not $tables[$hit].Exports.Contains($_) })
            if ($missing.Count -gt 0) {
                $findings.Add("$leaf needs $($missing.Count) name(s) $hit does not export: $(@($missing | Select-Object -First 5) -join ', ')")
            }
        }
    }
    return $findings.ToArray()
}

<#
.SYNOPSIS
    Every GPU ROCm's rocBLAS ships kernels for must be in ggml-hip's device code.
#>
function Get-LlamaCppHipTargetFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Target,
        [Parameter(Mandatory)][string]$RocblasLibraryDir
    )
    $rocmArch = @(Get-ChildItem -LiteralPath $RocblasLibraryDir -Filter 'TensileLibrary_lazy_gfx*.dat' -File -ErrorAction SilentlyContinue |
        ForEach-Object { [regex]::Match($_.Name, '_(gfx[0-9a-z]+)\.dat$').Groups[1].Value } | Where-Object { $_ } | Sort-Object -Unique)
    if ($rocmArch.Count -eq 0) { return "no TensileLibrary_lazy_gfx*.dat under ${RocblasLibraryDir}: cannot tell which GPUs ROCm's rocBLAS serves" }
    $missing = @($rocmArch | Where-Object { $Target -notcontains $_ })
    if ($missing.Count -gt 0) {
        return "ggml-hip.dll has no device code for $($missing -join ', '), which ROCm's rocBLAS has kernels for (ggml-hip: $($Target -join ','))"
    }
}

<#
.SYNOPSIS
    The shipped files are exactly the pinned zip's plus llama.cpp's LICENSE, as Install-LlamaCppHip.ps1 recorded them.
#>
function Get-LlamaCppHipManifestFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][AllowEmptyString()][string]$Build)
    $path = Join-Path $Dir 'llama-cpp-hip-manifest.json'
    if (-not [System.IO.File]::Exists($path)) { return "no manifest at ${path}: Install-LlamaCppHip.ps1 did not finish" }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $findings = @()
    if ("$($manifest.build)" -ne $Build) { $findings += "the manifest records build '$($manifest.build)', LLAMA_CPP_HIP_BUILD is '$Build'" }
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        [void]$listed.Add($entry.name)
        $file = Join-Path $Dir $entry.name
        if (-not [System.IO.File]::Exists($file)) { $findings += "$($entry.name) is missing"; continue }
        $length = ([System.IO.FileInfo]::new($file)).Length
        if ($length -ne $entry.length) { $findings += "$($entry.name) is $length bytes, not the pinned $($entry.length)"; continue }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) { $findings += "$($entry.name) differs from the pinned bytes" }
    }
    # The zip carries no llama.cpp licence text; MIT requires it beside the binaries.
    foreach ($required in 'ggml-hip.dll', 'llama-server.exe', 'licenses\llama.cpp\LICENSE') {
        if (-not $listed.Contains($required)) { $findings += "the manifest lists no $required" }
    }
    $extra = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -ne 'llama-cpp-hip-manifest.json' -and -not $listed.Contains($_.Name) })
    foreach ($file in $extra) { $findings += "$($file.Name) did not come from the pinned zip" }
    return $findings
}

<#
.SYNOPSIS
    The HIP runtime next to llama-server must be ROCm's own bytes, and nothing else of ROCm's may sit there.
#>
function Get-HipRuntimeIdentityFinding {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$RocmBin,
        [string]$RuntimePattern = '^(amdhip64_\d+|amd_comgr(_\d+)?|rocm_kpack)\.dll$'
    )
    $shared = @(Get-ChildItem -LiteralPath $Dir -Filter '*.dll' -File | Where-Object { [System.IO.File]::Exists((Join-Path $RocmBin $_.Name)) })
    $findings = @()
    if (@($shared | Where-Object { $_.Name -match $RuntimePattern }).Count -eq 0) {
        $findings += "no HIP runtime DLL next to llama-server: a host driver's System32 amdhip64 would win"
    }
    foreach ($dll in $shared) {
        if ($dll.Name -notmatch $RuntimePattern) { $findings += "$($dll.Name) next to llama-server shadows ROCm's own copy"; continue }
        if ((Get-FileHash -LiteralPath $dll.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $RocmBin $dll.Name)).Hash) {
            $findings += "$($dll.Name) next to llama-server is not ROCm's: hipBLAS/rocBLAS would run on a HIP runtime they were not built with"
        }
    }
    return $findings
}

<#
.SYNOPSIS
    The llama directory must not be on PATH, where its HIP runtime would shadow ROCm's for every process.
#>
function Get-LlamaCppHipPathFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue)
    $want = $Dir.TrimEnd('\')
    if (@($PathValue -split ';' | Where-Object { $_.Trim().Trim('"').TrimEnd('\') -ieq $want }).Count -gt 0) {
        return "$Dir is on PATH: its HIP runtime would shadow ROCm's for every process"
    }
}

<#
.SYNOPSIS
    Runs llama-server --version (no backend loads before it exits) and checks it reports the pinned build.
#>
function Get-LlamaServerVersionFinding {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build,
        [string]$Arguments = '--version',
        [int]$TimeoutSeconds = 120
    )
    if (-not [System.IO.File]::Exists($Exe)) { return "$Exe is missing" }
    $start = [System.Diagnostics.ProcessStartInfo]::new($Exe, $Arguments)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            return "$([System.IO.Path]::GetFileName($Exe)) $Arguments did not exit within $TimeoutSeconds s"
        }
        $process.WaitForExit()
        $text = ($stdout.Result + $stderr.Result).Trim()
        Write-Host "  $([System.IO.Path]::GetFileName($Exe)) ${Arguments}: $text"
        if ($process.ExitCode -ne 0) { return ('{0} {1} exited {2} (0x{2:X8}): {3}' -f [System.IO.Path]::GetFileName($Exe), $Arguments, $process.ExitCode, $text) }
        if ($text -notmatch "\(build $([regex]::Escape($Build)),") { return "$([System.IO.Path]::GetFileName($Exe)) $Arguments does not report build ${Build}: $text" }
    } finally { $process.Dispose() }
}

$llamaDir = "$env:LLAMA_CPP_HIP_HOME"
$rocmRoot = @($env:HIP_PATH, $env:ROCM_PATH) | Where-Object { $_ } | Select-Object -First 1
if (-not $llamaDir -or -not [System.IO.Directory]::Exists($llamaDir)) {
    "LLAMA_CPP_HIP_HOME ('$llamaDir') is not a directory: the rocm-llama stage did not run"
    return
}
if (-not $rocmRoot -or -not [System.IO.Directory]::Exists((Join-Path $rocmRoot 'bin'))) {
    "no ROCm bin under HIP_PATH/ROCM_PATH ('$rocmRoot'): nothing for ggml-hip to link against"
    return
}
$rocmBin = Join-Path $rocmRoot 'bin'
$build = "$env:LLAMA_CPP_HIP_BUILD"

Get-LlamaCppHipManifestFinding -Dir $llamaDir -Build $build
Get-LlamaCppHipPathFinding -Dir $llamaDir -PathValue "$env:PATH"
Get-HipRuntimeIdentityFinding -Dir $llamaDir -RocmBin $rocmBin

$ggmlHip = Join-Path $llamaDir 'ggml-hip.dll'
if ([System.IO.File]::Exists($ggmlHip)) {
    # The loader's order for an exe in $llamaDir: its own directory, the system directories, then PATH.
    $windowsDir = $env:SystemRoot
    $searchDir = @($llamaDir, (Join-Path $windowsDir 'System32'), (Join-Path $windowsDir 'System'), $windowsDir) +
        @("$env:PATH" -split ';' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
    try { Get-LlamaCppHipLinkFinding -Dir $llamaDir -RocmBin $rocmBin -SearchDir $searchDir }
    catch { "ggml-hip.dll's import walk failed: $($_.Exception.Message)" }
    try {
        $targets = @(Get-HipOffloadTarget -Path $ggmlHip)
        Write-Host "  ggml-hip.dll device code: $($targets -join ', ')"
        Get-LlamaCppHipTargetFinding -Target $targets -RocblasLibraryDir (Join-Path $rocmBin 'rocblas\library')
    } catch { "ggml-hip.dll's offload bundle is unreadable: $($_.Exception.Message)" }
}
Get-LlamaServerVersionFinding -Exe (Join-Path $llamaDir 'llama-server.exe') -Build $build

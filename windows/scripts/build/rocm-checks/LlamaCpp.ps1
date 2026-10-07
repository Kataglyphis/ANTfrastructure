# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm-check for llama.cpp's HIP and Vulkan builds: pinned bytes and licence, off PATH, linkable, runnable.
.DESCRIPTION
    One finding per defect; none is a pass. GPU-less: no Vulkan instance or HIP device is ever created, HIP is only
    asked for its device count, and no kernel runs. Also run per backend by windows/Dockerfile.rocm-llama.
    docs/windows-rocm.md § llama.cpp HIP and Vulkan.
#>
param(
    # The smoke gate grades both; each Dockerfile.rocm-llama RUN grades the build it just installed.
    [ValidateSet('all', 'hip', 'vulkan')][string]$Backend = 'all'
)

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
    Walks ggml-hip.dll's static imports through the loader order into ROCm: each must resolve, a ROCm one
    from ROCm's bin (or a byte-identical copy), and export every name imported from it.
#>
function Get-LlamaCppHipLinkFinding {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$RocmBin,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SearchDir
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
                $want = Join-Path $RocmBin $dll
                if (-not (Test-SameDirectory -Left (Split-Path $hit -Parent) -Right $RocmBin) -and
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
    Per backend: the env var naming its directory, its manifest, what that must list, why it stays off PATH.
#>
function Get-LlamaCppCheckSpec {
    param([Parameter(Mandatory)][ValidateSet('hip', 'vulkan')][string]$Backend)
    # The zips carry no llama.cpp licence text; MIT requires it beside the binaries.
    $license = 'licenses\llama.cpp\LICENSE'
    $reason = 'its libomp.dll, ggml*.dll and llama.dll would shadow every other copy of those names'
    if ($Backend -eq 'hip') {
        return @{ HomeVar = 'LLAMA_CPP_HIP_HOME'; Manifest = 'llama-cpp-hip-manifest.json'; Required = @('ggml-hip.dll', 'llama-server.exe', 'llama-cli.exe', $license)
            PathReason = $reason }
    }
    return @{ HomeVar = 'LLAMA_CPP_VULKAN_HOME'; Manifest = 'llama-cpp-vulkan-manifest.json'; Required = @('ggml-vulkan.dll', 'llama-server.exe', $license)
        PathReason = $reason }
}

<#
.SYNOPSIS
    The shipped files are exactly what Install-LlamaCpp.ps1 recorded: the pinned zip, HIP's built DLL and llama.cpp's LICENSE.
#>
function Get-LlamaCppManifestFinding {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Build,
        [Parameter(Mandatory)][string]$ManifestName,
        [Parameter(Mandatory)][string[]]$Required
    )
    $path = Join-Path $Dir $ManifestName
    if (-not [System.IO.File]::Exists($path)) { return "no manifest at ${path}: Install-LlamaCpp.ps1 did not finish" }
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
        # An on-access scanner can block the read (Defender flagged b11115's llama-gguf-split.exe on a host).
        try { $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } catch { $findings += "$($entry.name) cannot be read: $($_.Exception.Message)"; continue }
        if ($hash -ne $entry.sha256) { $findings += "$($entry.name) differs from the pinned bytes" }
    }
    foreach ($r in $Required) {
        if (-not $listed.Contains($r)) { $findings += "the manifest lists no $r" }
    }
    $extra = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -ne $ManifestName -and -not $listed.Contains($_.Name) })
    foreach ($file in $extra) { $findings += "$($file.Name) is not in the manifest: it came from neither the pinned zip nor the build" }
    return $findings
}

<#
.SYNOPSIS
    Nothing of ROCm's may sit next to llama-server: ggml-hip links the image's HIP runtime, never a bundled copy.
#>
function Get-LlamaCppRocmShadowFinding {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$RocmBin
    )
    foreach ($dll in @(Get-ChildItem -LiteralPath $Dir -Filter '*.dll' -File | Where-Object { [System.IO.File]::Exists((Join-Path $RocmBin $_.Name)) })) {
        "$($dll.Name) next to llama-server shadows ROCm's own copy: ggml-hip must load the image's HIP runtime and libraries"
    }
}

<#
.SYNOPSIS
    A llama directory must not be on PATH; $Reason says what it would shadow there.
#>
function Get-LlamaCppPathFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue, [Parameter(Mandatory)][string]$Reason)
    $want = $Dir.TrimEnd('\')
    if (@($PathValue -split ';' | Where-Object { $_.Trim().Trim('"').TrimEnd('\') -ieq $want }).Count -gt 0) {
        return "$Dir is on PATH: $Reason"
    }
}

<#
.SYNOPSIS
    The PATH entries, unquoted, in order.
#>
function Get-PathDirectory {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PathValue)
    return @($PathValue -split ';' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}

<#
.SYNOPSIS
    Runs a program with a timeout; ExitCode is $null when it hung and was killed. Output is stdout + stderr.
#>
function Invoke-LlamaCppProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 120
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $ArgumentList) { $start.ArgumentList.Add($a) }
    foreach ($k in $Environment.Keys) { $start.Environment[$k] = $Environment[$k] }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            return [pscustomobject]@{ ExitCode = $null; Text = '' }
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Text = ($stdout.Result + $stderr.Result).Trim() }
    } finally { $process.Dispose() }
}

<#
.SYNOPSIS
    One GPU-less run of a llama.cpp tool: a finding when it is missing, hangs, exits non-zero or prints the wrong answer.
.DESCRIPTION
    version: llama-server --version reports the pinned build; no backend loads before it exits.
    devices: llama-cli --list-devices loads ggml-hip and gets an answer from the HIP runtime, its devices or none. A
    container has no GPU, so HIP reports none; that line still proves the frontend loaded ggml-hip.dll and
    hipGetDeviceCount ran on the image's runtime. ggml-cuda.cu's ggml_cuda_init names GGML_CUDA_NAME, "ROCm" in a HIP build.
#>
function Get-LlamaCppRunFinding {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][ValidateSet('version', 'devices')][string]$Run,
        [AllowEmptyString()][string]$Build = '',
        [int]$TimeoutSeconds = 120
    )
    $arguments, $want, $meaning = switch ($Run) {
        'version' { '--version', "\(build $([regex]::Escape($Build)),", "does not report build $Build" }
        'devices' {
            '--list-devices', 'ggml_cuda_init: (found \d+ ROCm devices|failed to initialize ROCm: no ROCm-capable device is detected)',
            'did not initialise ggml-hip on the HIP runtime'
        }
    }
    $call = "$([System.IO.Path]::GetFileName($Exe)) $arguments"
    if (-not [System.IO.File]::Exists($Exe)) { return "$Exe is missing" }
    $result = Invoke-LlamaCppProcess -FilePath $Exe -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $result.ExitCode) { return "$call did not exit within $TimeoutSeconds s" }
    Write-Host "  ${call}: $($result.Text -replace '\s*\r?\n\s*', ' | ')"
    if ($result.ExitCode -ne 0) { return ('{0} exited {1} (0x{1:X8}): {2}' -f $call, $result.ExitCode, $result.Text) }
    if ($result.Text -notmatch $want) { return "$call ${meaning}: $($result.Text)" }
}

<#
.SYNOPSIS
    ggml-vulkan.dll statically imports vulkan-1.dll: it must resolve, and from System32 or a PATH entry.
#>
function Get-LlamaCppVulkanLoaderFinding {
    param(
        # Where the loader order for an exe in the llama directory finds vulkan-1.dll; '' = nowhere.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Loader,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedDir
    )
    if (-not $Loader) {
        return 'ggml-vulkan.dll imports vulkan-1.dll, which neither System32 nor PATH provides: the image carries no Vulkan loader'
    }
    Write-Host "  vulkan-1.dll: $Loader"
    $from = Split-Path $Loader -Parent
    if (@($AllowedDir | Where-Object { Test-SameDirectory -Left $_ -Right $from }).Count -eq 0) {
        return "vulkan-1.dll resolves to $Loader, which is neither System32 nor on PATH"
    }
}

<#
.SYNOPSIS
    The child's body: load a ggml backend DLL, report where the named modules came from; Vulkan also the loader's API.
.DESCRIPTION
    No backend is initialised. vkEnumerateInstanceVersion is answered by the Vulkan loader itself: no instance, driver or GPU.
#>
function Get-LlamaCppProbeScript {
    return @'
$ErrorActionPreference = 'Stop'
try {
    $h = [System.Runtime.InteropServices.NativeLibrary]::Load($env:LLAMA_CPP_PROBE_DLL)
    $null = [System.Runtime.InteropServices.NativeLibrary]::GetExport($h, 'ggml_backend_init')
    $loaded = @{}
    foreach ($m in [System.Diagnostics.Process]::GetCurrentProcess().Modules) { $loaded[$m.ModuleName.ToLowerInvariant()] = $m.FileName }
    foreach ($n in $env:LLAMA_CPP_PROBE_MODULES -split ',') { "module $n=$($loaded[$n])" }
    if ($env:LLAMA_CPP_PROBE_VULKAN -ne '1') { exit 0 }
    Add-Type -TypeDefinition 'public delegate int LlamaCppVkEnumerateInstanceVersion(out uint apiVersion);'
    $vk = [System.Runtime.InteropServices.NativeLibrary]::Load($loaded['vulkan-1.dll'])
    $fn = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        [System.Runtime.InteropServices.NativeLibrary]::GetExport($vk, 'vkEnumerateInstanceVersion'), [LlamaCppVkEnumerateInstanceVersion])
    $version = [uint32]0
    $rc = $fn.Invoke([ref]$version)
    "vkEnumerateInstanceVersion=$rc,$version"
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
exit 0
'@
}

<#
.SYNOPSIS
    Grades the probe's module lines: each named module must have loaded from the file given for it.
#>
function Get-LlamaCppProbeModuleFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Dll,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Expected
    )
    foreach ($name in $Expected.Keys) {
        $m = [regex]::Match($Text, "(?m)^module $([regex]::Escape($name))=(.*?)\s*$")
        $got = if ($m.Success) { $m.Groups[1].Value } else { '' }
        if (-not $got -or -not [string]::Equals([System.IO.Path]::GetFullPath($got), [System.IO.Path]::GetFullPath($Expected[$name]),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            "$Dll took $name from '$got', not $($Expected[$name])"
        }
    }
}

<#
.SYNOPSIS
    Grades the Vulkan probe's report: ggml-base from the llama dir, vulkan-1 from where the loader order says, API >= 1.2.
#>
function Get-LlamaCppVulkanProbeFinding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Loader,
        # ggml_vk_instance_init refuses an instance below 1.2 (ggml-vulkan.cpp@b11115:4969-4973).
        [version]$MinimumApi = '1.2'
    )
    Get-LlamaCppProbeModuleFinding -Text $Text -Dll 'ggml-vulkan.dll' -Expected ([ordered]@{ 'ggml-base.dll' = (Join-Path $Dir 'ggml-base.dll'); 'vulkan-1.dll' = $Loader })
    $answer = [regex]::Match($Text, '(?m)^vkEnumerateInstanceVersion=(-?\d+),(\d+)\s*$')
    if (-not $answer.Success) { return "the probe reported no vkEnumerateInstanceVersion result: $Text" }
    $raw = [uint32]$answer.Groups[2].Value
    $api = [version]::new(($raw -shr 22) -band 0x7F, ($raw -shr 12) -band 0x3FF, $raw -band 0xFFF)
    Write-Host "  Vulkan loader API: $api"
    if ($answer.Groups[1].Value -ne '0') { "vkEnumerateInstanceVersion returned VkResult $($answer.Groups[1].Value)" }
    elseif ($api -lt $MinimumApi) { "the Vulkan loader reports API $api; ggml-vulkan registers no device below $MinimumApi" }
}

<#
.SYNOPSIS
    Loads a backend DLL in a child pwsh (a crash stays there) with this process's PATH; .Finding is set when it did not load.
#>
function Invoke-LlamaCppLoadProbe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Module,
        [switch]$Vulkan,
        [int]$TimeoutSeconds = 120
    )
    $run = Invoke-LlamaCppProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', (Get-LlamaCppProbeScript) `
        -Environment @{ LLAMA_CPP_PROBE_DLL = $Path; LLAMA_CPP_PROBE_MODULES = ($Module -join ','); LLAMA_CPP_PROBE_VULKAN = $(if ($Vulkan) { '1' } else { '0' }) } `
        -TimeoutSeconds $TimeoutSeconds
    $leaf = [System.IO.Path]::GetFileName($Path)
    $finding = if ($null -eq $run.ExitCode) { "loading $leaf did not finish within $TimeoutSeconds s" }
    elseif ($run.ExitCode -ne 0) { "$leaf does not load from $([System.IO.Path]::GetDirectoryName($Path)): $($run.Text)" }
    else { $null }
    return [pscustomobject]@{ Finding = $finding; Text = "$($run.Text)" }
}

<#
.SYNOPSIS
    Loads ggml-vulkan.dll in a child pwsh, then grades the report.
#>
function Get-LlamaCppVulkanLoadFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Loader, [int]$TimeoutSeconds = 120)
    $probe = Invoke-LlamaCppLoadProbe -Path (Join-Path $Dir 'ggml-vulkan.dll') -Module 'ggml-base.dll', 'vulkan-1.dll' -Vulkan -TimeoutSeconds $TimeoutSeconds
    if ($probe.Finding) { return $probe.Finding }
    Get-LlamaCppVulkanProbeFinding -Text $probe.Text -Dir $Dir -Loader $Loader
}

<#
.SYNOPSIS
    Loads ggml-hip.dll in a child pwsh: ggml-base must come from the llama dir, each ROCm DLL it imports from ROCm's bin.
.DESCRIPTION
    Loading starts no HIP device: ggml_backend_init is resolved, never called.
#>
function Get-LlamaCppHipLoadFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$RocmBin, [int]$TimeoutSeconds = 120)
    $dll = Join-Path $Dir 'ggml-hip.dll'
    $expected = [ordered]@{ 'ggml-base.dll' = (Join-Path $Dir 'ggml-base.dll') }
    foreach ($name in @((Get-PeSymbolTable -Path $dll).Imports.Keys)) {
        if ([System.IO.File]::Exists((Join-Path $RocmBin $name))) { $expected[$name.ToLowerInvariant()] = Join-Path $RocmBin $name }
    }
    $probe = Invoke-LlamaCppLoadProbe -Path $dll -Module @($expected.Keys) -TimeoutSeconds $TimeoutSeconds
    if ($probe.Finding) { return $probe.Finding }
    Write-Host "  ggml-hip.dll loaded; graded: $(@($expected.Keys) -join ', ')"
    Get-LlamaCppProbeModuleFinding -Text $probe.Text -Dll 'ggml-hip.dll' -Expected $expected
}

<#
.SYNOPSIS
    The loader's order for an exe in $Dir: its own directory, the system directories, then PATH.
#>
function Get-LlamaCppSearchDir {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$WindowsDir, [Parameter(Mandatory)][AllowEmptyString()][string]$PathValue)
    return @($Dir, (Join-Path $WindowsDir 'System32'), (Join-Path $WindowsDir 'System'), $WindowsDir) + @(Get-PathDirectory -PathValue $PathValue)
}

<#
.SYNOPSIS
    The HIP build beyond the shared checks: no ROCm copy beside it, the import walk into ROCm, the load, the device code.
#>
function Get-LlamaCppHipFinding {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$RocmBin)
    Get-LlamaCppRocmShadowFinding -Dir $Dir -RocmBin $RocmBin
    $ggmlHip = Join-Path $Dir 'ggml-hip.dll'
    if (-not [System.IO.File]::Exists($ggmlHip)) { return }
    $searchDir = Get-LlamaCppSearchDir -Dir $Dir -WindowsDir $env:SystemRoot -PathValue "$env:PATH"
    $walk = @(try { Get-LlamaCppHipLinkFinding -Dir $Dir -RocmBin $RocmBin -SearchDir $searchDir }
        catch { "ggml-hip.dll's import walk failed: $($_.Exception.Message)" })
    $walk
    # A load is only worth grading once every import resolves to the right file.
    if ($walk.Count -eq 0) {
        Get-LlamaCppHipLoadFinding -Dir $Dir -RocmBin $RocmBin
        Get-LlamaCppRunFinding -Exe (Join-Path $Dir 'llama-cli.exe') -Run devices
    }
    try {
        $targets = @(Get-HipOffloadTarget -Path $ggmlHip)
        Write-Host "  ggml-hip.dll device code: $($targets -join ', ')"
        Get-LlamaCppHipTargetFinding -Target $targets -RocblasLibraryDir (Join-Path $RocmBin 'rocblas\library')
    } catch { "ggml-hip.dll's offload bundle is unreadable: $($_.Exception.Message)" }
}

<#
.SYNOPSIS
    The Vulkan build beyond the shared checks: its loader from System32 or PATH, ggml-vulkan.dll loadable against it.
#>
function Get-LlamaCppVulkanFinding {
    param([Parameter(Mandatory)][string]$Dir)
    $loader = "$(Resolve-LoaderDll -Name 'vulkan-1.dll' -SearchDir (Get-LlamaCppSearchDir -Dir $Dir -WindowsDir $env:SystemRoot -PathValue "$env:PATH"))"
    $allowed = @(Join-Path $env:SystemRoot 'System32') + @(Get-PathDirectory -PathValue "$env:PATH")
    $loaderFinding = @(Get-LlamaCppVulkanLoaderFinding -Loader $loader -AllowedDir $allowed)
    $loaderFinding
    if ($loaderFinding.Count -eq 0 -and [System.IO.File]::Exists((Join-Path $Dir 'ggml-vulkan.dll'))) {
        Get-LlamaCppVulkanLoadFinding -Dir $Dir -Loader $loader
    }
}

# LLAMA_CPP_HIP_BUILD is the one build pin: both zips are the same llama.cpp tag.
$build = "$env:LLAMA_CPP_HIP_BUILD"
$rocmRoot = @($env:HIP_PATH, $env:ROCM_PATH) | Where-Object { $_ } | Select-Object -First 1
foreach ($b in @(if ($Backend -eq 'all') { 'hip', 'vulkan' } else { $Backend })) {
    $spec = Get-LlamaCppCheckSpec -Backend $b
    $dir = "$([Environment]::GetEnvironmentVariable($spec.HomeVar))"
    if (-not $dir -or -not [System.IO.Directory]::Exists($dir)) {
        "$($spec.HomeVar) ('$dir') is not a directory: the rocm-llama stage did not run"
        continue
    }
    if ($b -eq 'hip' -and (-not $rocmRoot -or -not [System.IO.Directory]::Exists((Join-Path $rocmRoot 'bin')))) {
        "no ROCm bin under HIP_PATH/ROCM_PATH ('$rocmRoot'): nothing for ggml-hip to link against"
        continue
    }
    Get-LlamaCppManifestFinding -Dir $dir -Build $build -ManifestName $spec.Manifest -Required $spec.Required
    Get-LlamaCppPathFinding -Dir $dir -PathValue "$env:PATH" -Reason $spec.PathReason
    if ($b -eq 'hip') { Get-LlamaCppHipFinding -Dir $dir -RocmBin (Join-Path $rocmRoot 'bin') } else { Get-LlamaCppVulkanFinding -Dir $dir }
    Get-LlamaCppRunFinding -Exe (Join-Path $dir 'llama-server.exe') -Run version -Build $build
}

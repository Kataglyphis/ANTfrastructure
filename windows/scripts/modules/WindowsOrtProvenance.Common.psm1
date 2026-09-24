#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# ORT census (owner rule 2026-09-23): every ONNX Runtime binary in a tree is the chain build and every
# importer resolves to it. docs/windows-build-invariants.md § ONNX Runtime has exactly one source.
# Does NOT cover header-only provenance: a consumer compiled against foreign headers ships no foreign bytes.

Set-StrictMode -Version Latest

# Optional at load, so a lone copy of this file imports. The census asserts it (Assert-OrtCensusDependency).
$script:OrtTargetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (-not (Get-Command -Name 'Get-PeExportNames' -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $script:OrtTargetArchPath -PathType Leaf)) {
    Import-Module $script:OrtTargetArchPath -DisableNameChecking
}

$script:OrtAbiMarker = @('OrtGetApiBase', 'CreateEpFactories', 'RegisterCustomOps')
# A whole ORT source-file path ending in NUL, as __FILE__ puts it into every ORT build. A consumer that
# names the chain DIRECTORY as data is not ORT: docs/onnxruntime-single-source.md#what-the-chain-ort-is
$script:OrtPathMarker = [regex]::new('onnxruntime[\\/](?:core|contrib_ops)[\\/][A-Za-z0-9_.+\\/-]*?\.(?:cc|cpp|cxx|c|h|hpp|inc|cu|cuh)(?:\x00|\z)')
$script:OrtInstancePattern = [regex]::new(
    '^(?:lib)?onnxruntime(?:_providers_[a-z0-9_]+)?\.(?:dll|so(?:\.[0-9]+)*)$|^onnxruntime_pybind11_state[^\\/]*\.(?:pyd|so)$',
    'IgnoreCase')
$script:OrtBinaryExtension = @('.dll', '.pyd', '.exe', '.so')
$script:OrtArchiveExtension = @('.whl', '.zip', '.nupkg')
$script:OrtFatalVerdict = @('NONE', 'EXEMPT-STALE', 'FOREIGN', 'STALE', 'UNPROVEN', 'ELSEWHERE', 'UNRESOLVED',
    'UNREGISTERED', 'STAMP', 'DIST', 'INBOX')

function Assert-OrtCensusDependency {
    # Throws, so a census never scans import-blind: WindowsTargetArch.Common supplies the PE imports, exports and the arch.
    foreach ($cmd in 'Get-PeImportNames', 'Get-PeExportNames', 'Get-WindowsTargetArch') {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            throw "ORT census: $cmd is unavailable; import WindowsTargetArch.Common.psm1 first (none at $script:OrtTargetArchPath)"
        }
    }
}

function Get-OrtChainSourceRoot {
    # Build-OnnxFromSource.ps1's -SourceDir; verify-critical-fixes.sh pins the two equal.
    return @('C:\temp\onnx-src')
}

function Get-OrtChainPrefix {
    param([AllowEmptyString()][string]$OnnxRoot = [Environment]::GetEnvironmentVariable('ONNX_ROOT'))
    if ([string]::IsNullOrWhiteSpace($OnnxRoot)) { return 'C:\runtime\lib\onnxruntime-source' }
    return $OnnxRoot.TrimEnd('\')
}

function Get-OrtConsumerContract {
    # THE list of image components allowed to use ORT: anything else carrying the ORT ABI is UNREGISTERED.
    # G2 (Assert-ChainOrtOnly, WindowsOrtProvenance.Build) writes one stamp per entry, at Get-OrtStampPath -Consumer <Name>.
    return @(
        [pscustomobject]@{ Name = 'opencv'; Pattern = @('opencv_dnn*.dll', 'opencv_gapi*.dll', 'cv2*.pyd') }
        [pscustomobject]@{ Name = 'gstreamer'; Pattern = @('gstonnx*.dll') }
        [pscustomobject]@{ Name = 'ffmpeg'; Pattern = @('avfilter-*.dll') }
        [pscustomobject]@{ Name = 'genai'; Pattern = @('onnxruntime-genai*.dll', 'onnxruntime_genai*.pyd') }
        [pscustomobject]@{ Name = 'amdgpu-ep'; Pattern = @('migraphx-ep.dll') }
    )
}

function Get-OrtStampPath {
    param([Parameter(Mandatory)][string]$Consumer, [string]$StampDir = 'C:\runtime\share\ort-provenance')
    return (Join-Path $StampDir "$Consumer.json")
}

function Test-OrtInstanceName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    return $script:OrtInstancePattern.IsMatch($Name)
}

function ConvertTo-OrtSourceRoot {
    # One printable run before a path marker -> the build root it names; '' = relative, $null = a URL.
    param([AllowEmptyString()][string]$Run)
    if ($Run -match '[A-Za-z][A-Za-z0-9+.-]*://') { return $null }
    $drives = [regex]::Matches($Run, '[A-Za-z]:[\\/]')
    if ($drives.Count -gt 0) { return $Run.Substring($drives[$drives.Count - 1].Index).Replace('/', '\').TrimEnd('\') }
    if ($Run.StartsWith('/')) { return $Run.TrimEnd('/') }
    return ''
}

function Get-OrtSourceRoot {
    # Build roots named by ORT source paths in Latin-1 text; matches ending before -MinEnd were already read.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$MinEnd = 0)
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $script:OrtPathMarker.Matches($Text)) {
        if ($m.Index + $m.Length -le $MinEnd) { continue }
        $start = $m.Index
        $floor = [Math]::Max(0, $m.Index - 400)
        while ($start -gt $floor) {
            $c = [int]$Text[$start - 1]
            if ($c -lt 0x20 -or $c -gt 0x7E) { break }
            $start--
        }
        $root = ConvertTo-OrtSourceRoot -Run $Text.Substring($start, $m.Index - $start)
        if ($null -ne $root -and -not $roots.Contains($root)) { $roots.Add($root) }
    }
    return $roots.ToArray()
}

function Read-OrtStreamMarker {
    # One pass: sha256, size, the first bytes, the ABI markers and the ORT source roots of a stream.
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $buf = [byte[]]::new(8MB)
    $roots = [System.Collections.Generic.List[string]]::new()
    $abi = [System.Collections.Generic.List[string]]::new()
    $carry = ''
    $size = [long]0
    $ortText = $false
    $head = ''
    try {
        while (($n = $Stream.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($size -eq 0) { $head = [System.Text.Encoding]::Latin1.GetString($buf, 0, [Math]::Min(4, $n)) }
            $hash.AppendData($buf, 0, $n)
            $size += $n
            $text = $carry + [System.Text.Encoding]::Latin1.GetString($buf, 0, $n)
            foreach ($marker in $script:OrtAbiMarker) {
                if (-not $abi.Contains($marker) -and $text.Contains($marker)) { $abi.Add($marker) }
            }
            if ($text.Contains('onnxruntime')) {
                $ortText = $true
                foreach ($r in (Get-OrtSourceRoot -Text $text -MinEnd $carry.Length)) { if (-not $roots.Contains($r)) { $roots.Add($r) } }
            }
            $carry = $text.Substring([Math]::Max(0, $text.Length - 512))
        }
        $sha = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose() }
    return [pscustomobject]@{ Sha256 = $sha; Size = $size; Head = $head; Roots = $roots.ToArray(); Abi = $abi.ToArray(); OrtText = $ortText }
}

function New-OrtFact {
    param([string]$Path, [string]$Container = '', [AllowNull()][object]$Scan = $null, [string]$ErrorText = '')
    $name = ($Path -split '[\\/!]')[-1]
    $roots = [string[]]@(if ($Scan) { $Scan.Roots })
    return [pscustomobject]@{
        Path       = $Path
        Name       = $name
        Container  = $Container
        Sha256     = $(if ($Scan) { $Scan.Sha256 } else { '' })
        Size       = $(if ($Scan) { $Scan.Size } else { [long]0 })
        Roots      = $roots
        Abi        = [string[]]@(if ($Scan) { $Scan.Abi })
        OrtText    = $(if ($Scan) { [bool]$Scan.OrtText } else { $false })
        IsPe       = [bool]($Scan -and $Scan.Head.StartsWith('MZ'))
        IsInstance = (Test-OrtInstanceName -Name $name) -or $roots.Count -gt 0
        Defines    = $false
        Imports    = [string[]]@()
        Error      = $ErrorText
    }
}

function Get-OrtBinaryFact {
    # Facts about one file (or one archive member via -Stream): hash, ORT source roots, ABI markers, PE imports.
    # Archive members get no imports: nothing loads them from inside the archive, so only their bytes count.
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Stream')][System.IO.Stream]$Stream,
        [Parameter(Mandatory, ParameterSetName = 'Stream')][string]$Label,
        [string]$Container = ''
    )
    if ($PSCmdlet.ParameterSetName -eq 'Stream') { return New-OrtFact -Path $Label -Container $Container -Scan (Read-OrtStreamMarker -Stream $Stream) }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try { $scan = Read-OrtStreamMarker -Stream $fs } finally { $fs.Dispose() }
    } catch { return New-OrtFact -Path $Path -Container $Container -ErrorText $_.Exception.Message }
    $fact = New-OrtFact -Path $Path -Container $Container -Scan $scan
    if ($fact.IsPe -and -not $fact.IsInstance -and ($fact.OrtText -or $fact.Abi.Count -gt 0)) {
        Assert-OrtCensusDependency
        try { $fact.Imports = [string[]]@(Get-PeImportNames -Path $Path -IncludeDelayLoad) } catch { $fact.Imports = [string[]]@() }
        # An ORT under another name with its fingerprints stripped still exports its entry point.
        if ($fact.Abi -contains 'OrtGetApiBase') {
            try { $fact.Defines = @(Get-PeExportNames -Path $Path) -ccontains 'OrtGetApiBase' } catch { $fact.Defines = $false }
            $fact.IsInstance = $fact.Defines
        }
    }
    return $fact
}

function Test-OrtBinaryName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    return ($script:OrtBinaryExtension -contains $ext) -or (Test-OrtInstanceName -Name $Name) -or ($Name -match '\.so\.[0-9]')
}

function Test-OrtPeMagic {
    # A PE under any other extension (a renamed ORT) is scanned too; files under 1 KiB cannot be one.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try { return ($fs.Length -ge 1024 -and $fs.ReadByte() -eq 0x4D -and $fs.ReadByte() -eq 0x5A) } finally { $fs.Dispose() }
    } catch { return $false }
}

function Get-OrtArchiveFact {
    # Facts for every native member of a .whl/.zip/.nupkg; an unreadable archive is one fact with Error set.
    param([Parameter(Mandatory)][string]$Path)
    $facts = [System.Collections.Generic.List[object]]::new()
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($Path) } catch { return New-OrtFact -Path $Path -ErrorText $_.Exception.Message }
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name -or -not (Test-OrtBinaryName -Name $entry.Name)) { continue }
            $s = $entry.Open()
            try { $facts.Add((Get-OrtBinaryFact -Stream $s -Label "$Path!$($entry.FullName)" -Container $Path)) } finally { $s.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $facts.ToArray()
}

function Find-OrtFile {
    # Every file under $Root matching $Pattern. Directory junctions are not followed (.NET's recursion would loop).
    param([Parameter(Mandatory)][string]$Root, [string]$Pattern = '*', [AllowEmptyCollection()][string[]]$Exclude = @())
    $opt = [System.IO.EnumerationOptions]::new()
    $opt.IgnoreInaccessible = $true
    $opt.AttributesToSkip = [System.IO.FileAttributes]0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, $Pattern, $opt)) { $f }
            foreach ($sub in [System.IO.DirectoryInfo]::new($dir).EnumerateDirectories('*', $opt)) {
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or (Test-OrtUnderRoot -Path $sub.FullName -Prefix $Exclude)) { continue }
                $stack.Push($sub.FullName)
            }
        } catch [System.IO.IOException], [System.UnauthorizedAccessException] { continue }
    }
}

function Select-OrtExistingDir {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Dir)
    return @($Dir | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
}

function Get-OrtTreeFact {
    # Content facts for every binary and archive under -ContentRoot, plus every ORT-named file under -NameRoot.
    param(
        [AllowEmptyCollection()][string[]]$ContentRoot = @(),
        [AllowEmptyCollection()][string[]]$NameRoot = @(),
        [AllowEmptyCollection()][string[]]$ExtraFile = @(),
        [AllowEmptyCollection()][string[]]$ExcludeRoot = @()
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $facts = [System.Collections.Generic.List[object]]::new()
    $take = {
        param([string]$File)
        if (-not $seen.Add($File)) { return }
        $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
        if ($script:OrtArchiveExtension -contains $ext) { foreach ($f in (Get-OrtArchiveFact -Path $File)) { $facts.Add($f) } }
        elseif ((Test-OrtBinaryName -Name ([System.IO.Path]::GetFileName($File))) -or (Test-OrtPeMagic -Path $File)) { $facts.Add((Get-OrtBinaryFact -Path $File)) }
    }
    foreach ($root in (Select-OrtExistingDir $ContentRoot)) {
        foreach ($file in (Find-OrtFile -Root $root)) { & $take $file }
    }
    foreach ($root in (Select-OrtExistingDir $NameRoot)) {
        foreach ($file in (Find-OrtFile -Root $root -Pattern '*onnxruntime*' -Exclude $ExcludeRoot)) {
            if (Test-OrtInstanceName -Name ([System.IO.Path]::GetFileName($file))) { & $take $file }
        }
    }
    foreach ($file in @($ExtraFile | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) { & $take $file }
    return $facts.ToArray()
}

function Get-OrtSitePackageOwner {
    # Distributions whose RECORD installs the `onnxruntime` import package into one site-packages dir.
    param([Parameter(Mandatory)][string]$SitePackages, [string]$Package = 'onnxruntime')
    $prefix = "$Package/"
    $owners = foreach ($info in @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue)) {
        $record = Join-Path $info.FullName 'RECORD'
        if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { continue }
        if (@([System.IO.File]::ReadLines($record) | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1).Count -gt 0) {
            (($info.Name -replace '-[^-]+\.dist-info$', '') -replace '[-_.]+', '-').ToLowerInvariant()
        }
    }
    return @($owners | Sort-Object -Unique)
}

function Find-OrtSitePackage {
    param([Parameter(Mandatory)][string]$Root)
    $opt = [System.IO.EnumerationOptions]::new()
    $opt.IgnoreInaccessible = $true
    $opt.RecurseSubdirectories = $true
    $opt.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
    return @([System.IO.Directory]::EnumerateDirectories($Root, 'site-packages', $opt))
}

function Get-OrtChainWheel {
    # The chain ORT wheel(s) in a wheel store; normalised names, so onnxruntime_gpu matches too. GenAI never does.
    param([AllowEmptyString()][string]$WheelDir, [AllowEmptyString()][string]$OrtVersion = '')
    if (-not $WheelDir -or -not (Test-Path -LiteralPath $WheelDir -PathType Container)) { return @() }
    $ver = if ($OrtVersion) { [regex]::Escape($OrtVersion.TrimStart('v')) } else { '[^-]+' }
    $pattern = "^onnxruntime(?:[_-](?!genai)[a-z0-9]+)?-$ver-.*\.whl$"
    return @(Get-ChildItem -LiteralPath $WheelDir -Filter '*.whl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $pattern } | ForEach-Object FullName)
}

function Test-OrtUnderRoot {
    param([AllowEmptyString()][string]$Path, [AllowEmptyCollection()][string[]]$Prefix)
    if (-not $Path) { return $false }
    foreach ($p in $Prefix) {
        $q = "$p".TrimEnd('\', '/')
        if (-not $q) { continue }
        if ($Path.Equals($q, [StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith("$q\", [StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith("$q/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function New-OrtFinding {
    param([string]$Verdict, [string]$Path, [string]$Detail)
    return [pscustomobject]@{ Verdict = $Verdict; Path = $Path; Detail = $Detail; Fatal = ($script:OrtFatalVerdict -contains $Verdict) }
}

function Get-OrtBytesVerdict {
    # A non-chain ORT instance: FOREIGN (another build root), STALE (the chain's root, other bytes), UNPROVEN (no fingerprint).
    param([Parameter(Mandatory)][object]$Fact, [Parameter(Mandatory)][string[]]$ChainRoot)
    $foreign = @($Fact.Roots | Where-Object { $_ -ne '' -and -not (Test-OrtUnderRoot -Path $_ -Prefix $ChainRoot) })
    $chain = @($Fact.Roots | Where-Object { Test-OrtUnderRoot -Path $_ -Prefix $ChainRoot })
    if ($foreign.Count -gt 0) { return New-OrtFinding 'FOREIGN' $Fact.Path "built under $($foreign -join ', '), not the chain ($($ChainRoot -join ', '))" }
    if ($chain.Count -gt 0) { return New-OrtFinding 'STALE' $Fact.Path 'a chain-rooted build whose bytes match no file of this chain ORT (older or patched)' }
    if (@($Fact.Roots).Count -gt 0) { return New-OrtFinding 'FOREIGN' $Fact.Path 'built with relative (remapped) source paths, which the chain never does' }
    if ($Fact.Defines) { return New-OrtFinding 'UNPROVEN' $Fact.Path 'an ORT under another name (it exports OrtGetApiBase) with no source fingerprint that matches no file of the chain ORT' }
    return New-OrtFinding 'UNPROVEN' $Fact.Path 'an ORT-named binary with no source fingerprint that matches no file of the chain ORT'
}

function Test-OrtAllowedHome {
    param([Parameter(Mandatory)][object]$Fact, [AllowEmptyCollection()][string[]]$AllowedHome)
    $where = if ($Fact.Container) { $Fact.Container } else { $Fact.Path }
    if (Test-OrtUnderRoot -Path $where -Prefix $AllowedHome) { return $true }
    return ($Fact.Path -match '[\\/]site-packages[\\/]onnxruntime[\\/]capi[\\/][^\\/!]+$')
}

function Get-OrtByteFinding {
    param([object[]]$Reference, [object[]]$Candidate, [string[]]$ChainRoot, [AllowNull()][string[]]$AllowedHome,
        [System.Collections.Generic.HashSet[string]]$RefSha)
    foreach ($r in $Reference) {
        if (@($r.Roots).Count -gt 0 -and @($r.Roots | Where-Object { Test-OrtUnderRoot -Path $_ -Prefix $ChainRoot }).Count -eq 0) {
            New-OrtFinding 'FOREIGN' $r.Path "the chain reference itself was built under $($r.Roots -join ', ')"
        }
    }
    foreach ($c in $Candidate) {
        $archive = $script:OrtArchiveExtension -contains [System.IO.Path]::GetExtension($c.Path).ToLowerInvariant()
        if ($c.Error) {
            # A corrupt archive nothing ORT-named can install is not an ORT finding.
            if (($archive -and $c.Name -match 'onnxruntime') -or (Test-OrtInstanceName -Name $c.Name)) { New-OrtFinding 'UNPROVEN' $c.Path "unreadable: $($c.Error)" }
            continue
        }
        if (-not $c.IsInstance) { continue }
        if (-not $RefSha.Contains($c.Sha256)) { Get-OrtBytesVerdict -Fact $c -ChainRoot $ChainRoot; continue }
        if ($null -ne $AllowedHome -and -not (Test-OrtAllowedHome -Fact $c -AllowedHome $AllowedHome)) {
            New-OrtFinding 'ELSEWHERE' $c.Path 'a chain ORT copy outside the chain prefix, the wheel store and */site-packages/onnxruntime/capi'
        }
    }
}

function Test-OrtConsumer {
    param([Parameter(Mandatory)][object]$Fact)
    if ($Fact.IsInstance -or $Fact.Error) { return $false }
    if (@($Fact.Abi).Count -gt 0) { return $true }
    return @($Fact.Imports | Where-Object { Test-OrtInstanceName -Name $_ }).Count -gt 0
}

function Get-OrtLoaderDir {
    # -ClientHost: the app-local dirs a loader searches before System32, one list per exe that could host $Importer.
    # An .exe gets its own dir, a .pyd its own then the host's (DLL_LOAD_DIR), any other DLL only the host's.
    param([string]$Importer, [AllowEmptyCollection()][string[]]$AppDir, [switch]$ClientHost)
    $own = Split-Path -Parent $Importer
    $exeDirs = @($AppDir | Where-Object { $_ })
    $out = [System.Collections.Generic.List[string[]]]::new()
    # Image mode keeps the importer's dir: its hosts are unknown, and a chain copy beside it is ELSEWHERE anyway.
    if (-not $ClientHost) { $out.Add([string[]](@($own) + $exeDirs)); return , $out }
    $ext = [System.IO.Path]::GetExtension($Importer).ToLowerInvariant()
    if ($ext -eq '.exe') { $out.Add([string[]]@($own)); return , $out }
    # Exes at or above it host it; with none there (a bin\ + lib\ layout), any exe of the tree may.
    $hosts = @($exeDirs | Where-Object { Test-OrtUnderRoot -Path $own -Prefix @($_) })
    if ($hosts.Count -eq 0) { $hosts = $exeDirs }
    $lead = @(if ($ext -eq '.pyd') { $own })
    if ($hosts.Count -eq 0) { $out.Add([string[]]$lead) }
    foreach ($h in $hosts) { $out.Add([string[]]@(@($lead) + @($h) | Select-Object -Unique)) }
    return , $out
}

function Resolve-OrtImport {
    # First search-order hit for $Name: the loader's app-local dirs, System32 (or its assumed Windows ML copy), PATH.
    param([string]$Name, [hashtable]$Index, [AllowEmptyCollection()][string[]]$Dir, [string]$System32, [string[]]$SearchPath)
    foreach ($d in @($Dir) + @($System32) + @($SearchPath)) {
        if (-not $d) { continue }
        if ($d -eq '::system32::') { return $d }
        $dir = $d.Trim('"').TrimEnd('\')
        if (-not [System.IO.Path]::IsPathRooted($dir)) { continue }
        # Path.Combine, not Join-Path: a PATH entry on a drive the container lacks must not throw.
        $key = [System.IO.Path]::Combine($dir, $Name).ToLowerInvariant()
        if ($Index.ContainsKey($key)) { return $key }
    }
    return ''
}

function Get-OrtResolutionFinding {
    param([object[]]$Candidate, [System.Collections.Generic.HashSet[string]]$RefSha, [string[]]$AppDir, [string]$System32,
        [switch]$AssumeSystemOrt, [string[]]$SearchPath)
    $index = @{}
    foreach ($c in $Candidate) { if (-not $c.Container -and -not $c.Error) { $index[$c.Path.ToLowerInvariant()] = $c } }
    $sys = if ($AssumeSystemOrt) { '::system32::' } else { $System32 }
    foreach ($c in @($Candidate | Where-Object { -not $_.Container -and (Test-OrtConsumer -Fact $_) })) {
        $wanted = @($c.Imports | Where-Object { Test-OrtInstanceName -Name $_ })
        if ($wanted.Count -eq 0 -and @($c.Abi) -contains 'OrtGetApiBase') { $wanted = @('onnxruntime.dll') }
        # Every possible host must land on the chain ORT; one finding per distinct reason.
        $loaders = Get-OrtLoaderDir -Importer $c.Path -AppDir $AppDir -ClientHost:$AssumeSystemOrt
        $said = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($name in $wanted) {
            foreach ($dirs in $loaders) {
                $hit = Resolve-OrtImport -Name $name -Index $index -Dir $dirs -System32 $sys -SearchPath $SearchPath
                $where = if ($dirs.Count -gt 0) { $dirs -join ' or ' } else { 'no host exe dir (none in the tree)' }
                $why = if ($hit -eq '::system32::') { "$name is not in $where, so a client host loads System32's Windows ML copy" }
                elseif (-not $hit) { "no $name on its search path" }
                elseif (-not $RefSha.Contains($index[$hit].Sha256)) { "$name resolves to $($index[$hit].Path), which is not the chain ORT" }
                else { '' }
                if ($why -and $said.Add($why)) { New-OrtFinding 'UNRESOLVED' $c.Path $why }
            }
        }
    }
}

function Get-OrtInboxFinding {
    # INBOX: an ORT instance or ABI user in the OS's own Windows dir. servercore:ltsc2025 ships none (probed 2026-09-23),
    # so one means the base moved: keep the previous WINDOWS_BASE_DIGEST. App-local chain copies cannot clear it today.
    param([object[]]$Candidate, [AllowEmptyCollection()][string[]]$InboxRoot)
    $roots = @($InboxRoot | Where-Object { $_ })
    if ($roots.Count -eq 0) { return }
    foreach ($c in $Candidate) {
        $where = if ($c.Container) { $c.Container } else { $c.Path }
        if (-not (Test-OrtUnderRoot -Path $where -Prefix $roots)) { continue }
        if (-not $c.IsInstance -and -not (Test-OrtConsumer -Fact $c)) { continue }
        New-OrtFinding 'INBOX' $c.Path 'an ONNX Runtime in the OS''s Windows dir (the base image moved): keep the previous WINDOWS_BASE_DIGEST; never exempt, delete or patch it. docs/onnxruntime-single-source.md#the-in-box-onnx-runtime-windows-ml'
    }
}

function Test-OrtStampCurrent {
    # A stamp names its consumer and the current chain core-lib sha256 (under any key: G2 owns the schema).
    param([AllowNull()][string]$Text, [string]$Consumer, [AllowEmptyCollection()][string[]]$CoreSha256)
    if (-not $Text) { return $false }
    try { $json = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return $false }
    if ($json -isnot [hashtable] -or "$($json['consumer'])" -ne $Consumer) { return $false }
    foreach ($v in $json.Values) { if ($CoreSha256 -contains "$v".ToLowerInvariant()) { return $true } }
    return $false
}

function Get-OrtContractFinding {
    param([object[]]$Candidate, [object[]]$Contract, [AllowNull()][hashtable]$Stamp, [switch]$RequireStamp, [string[]]$CoreSha256)
    $present = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @($Candidate | Where-Object { Test-OrtConsumer -Fact $_ })) {
        $entry = @($Contract | Where-Object { $e = $_; @($e.Pattern | Where-Object { $c.Name -like $_ }).Count -gt 0 }) | Select-Object -First 1
        if ($entry) { if (-not $present.Contains($entry.Name)) { $present.Add($entry.Name) }; continue }
        $uses = @($c.Abi) + @($c.Imports | Where-Object { Test-OrtInstanceName -Name $_ })
        New-OrtFinding 'UNREGISTERED' $c.Path "uses the ORT ABI ($($uses -join ', ')) but no Get-OrtConsumerContract entry covers it"
    }
    if (-not $RequireStamp) { return }
    foreach ($name in $present) {
        $text = if ($Stamp -and $Stamp.ContainsKey($name)) { $Stamp[$name] } else { $null }
        if (-not (Test-OrtStampCurrent -Text $text -Consumer $name -CoreSha256 $CoreSha256)) {
            New-OrtFinding 'STAMP' (Get-OrtStampPath -Consumer $name) "missing, or not naming this image's chain core lib ($($CoreSha256 -join ', '))"
        }
    }
}

function Get-OrtExemptedFinding {
    # '<arch>:<path>:<reason>' waives every finding on that path; an entry that waives nothing is itself fatal.
    param([object[]]$Finding, [AllowEmptyCollection()][string[]]$Exemption, [string]$Arch)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Finding) { $out.Add($f) }
    foreach ($e in $Exemption) {
        if ($e -notmatch '^(?<arch>[^:]+):(?<path>.+):(?<reason>[^:]+)$') { $out.Add((New-OrtFinding 'EXEMPT-STALE' $e 'malformed; expected <arch>:<path>:<reason>')); continue }
        $want = $Matches['arch']; $path = $Matches['path']; $reason = $Matches['reason']
        if ($want -ne '*' -and $want -ne $Arch) { continue }
        $hits = @($out | Where-Object { $_.Fatal -and $_.Path -eq $path })
        if ($hits.Count -eq 0) { $out.Add((New-OrtFinding 'EXEMPT-STALE' $path "the exemption '$reason' matches no finding any more: delete it")); continue }
        # An in-box path waives nothing: the OS's copy is not ours to vouch for (owner rule: no System32 ORT).
        if (@($hits | Where-Object Verdict -eq 'INBOX').Count -gt 0) { $out.Add((New-OrtFinding 'EXEMPT-STALE' $path "the exemption '$reason' names an in-box ORT, which is never exempted")); continue }
        foreach ($h in $hits) { $h.Verdict = 'EXEMPT'; $h.Fatal = $false; $h.Detail = "$($h.Detail) [exempt: $reason]" }
    }
    return $out.ToArray()
}

function Get-OrtCensusFinding {
    # PURE: facts in, findings out (none fatal = pass). A $null -AllowedHome/-Contract/-Distribution turns that arm off.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Reference = @(),
        [AllowEmptyCollection()][object[]]$Candidate = @(),
        [Parameter(Mandatory)][string[]]$ChainRoot,
        [AllowNull()][string[]]$AllowedHome = $null,
        [AllowNull()][object[]]$Contract = $null,
        [AllowNull()][hashtable]$Stamp = $null,
        [switch]$RequireStamp,
        [AllowEmptyCollection()][string[]]$CoreSha256 = @(),
        [AllowEmptyCollection()][string[]]$AppDir = @(),
        [AllowEmptyCollection()][string[]]$SearchPath = @(),
        [AllowEmptyString()][string]$System32 = '',
        [switch]$AssumeSystemOrt,
        [AllowEmptyCollection()][string[]]$InboxRoot = @(),
        [AllowNull()][hashtable]$Distribution = $null,
        [AllowEmptyCollection()][string[]]$Exemption = @(),
        [string]$Arch = 'amd64'
    )
    $refSha = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Reference) { if ($r.Sha256) { [void]$refSha.Add($r.Sha256) } }
    $findings = [System.Collections.Generic.List[object]]::new()
    if ($refSha.Count -eq 0) { $findings.Add((New-OrtFinding 'NONE' '-' 'no chain ORT reference was found, so nothing can be proven')) }
    if (@($Candidate | Where-Object IsInstance).Count -eq 0) { $findings.Add((New-OrtFinding 'NONE' '-' 'the scan found no ORT binary at all: a vacuous pass, not a clean tree')) }
    foreach ($f in @(Get-OrtByteFinding -Reference $Reference -Candidate $Candidate -ChainRoot $ChainRoot -AllowedHome $AllowedHome -RefSha $refSha)) { $findings.Add($f) }
    foreach ($f in @(Get-OrtResolutionFinding -Candidate $Candidate -RefSha $refSha -AppDir $AppDir -System32 $System32 -AssumeSystemOrt:$AssumeSystemOrt -SearchPath $SearchPath)) { $findings.Add($f) }
    foreach ($f in @(Get-OrtInboxFinding -Candidate $Candidate -InboxRoot $InboxRoot)) { $findings.Add($f) }
    if ($null -ne $Contract) {
        foreach ($f in @(Get-OrtContractFinding -Candidate $Candidate -Contract $Contract -Stamp $Stamp -RequireStamp:$RequireStamp -CoreSha256 $CoreSha256)) { $findings.Add($f) }
    }
    if ($null -ne $Distribution) {
        foreach ($site in $Distribution.Keys) {
            $owners = @($Distribution[$site])
            if ($owners.Count -gt 1) { $findings.Add((New-OrtFinding 'DIST' $site "the onnxruntime import package is owned by $($owners -join ', ')")) }
        }
    }
    return Get-OrtExemptedFinding -Finding $findings.ToArray() -Exemption $Exemption -Arch $Arch
}

function Invoke-OrtCensus {
    # Scan (impure), then Get-OrtCensusFinding (pure) with -Verdict splatted into it (ChainRoot, AllowedHome,
    # Contract, RequireStamp, SearchPath, System32, AssumeSystemOrt, InboxRoot, Exemption, Arch). Write-OrtCensusReport prints it.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$ContentRoot = @(),
        [AllowEmptyCollection()][string[]]$NameRoot = @(),
        [AllowEmptyCollection()][string[]]$ExtraFile = @(),
        [AllowEmptyCollection()][string[]]$ExcludeRoot = @(),
        [AllowEmptyCollection()][string[]]$ReferenceDir = @(),
        [AllowEmptyCollection()][string[]]$ReferenceWheel = @(),
        [string]$StampDir = 'C:\runtime\share\ort-provenance',
        [AllowEmptyString()][string]$CoreLib = '',
        [switch]$TreeAppDir,
        [switch]$NoDistribution,
        [hashtable]$Verdict = @{}
    )
    Assert-OrtCensusDependency
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $v = @{ ChainRoot = (Get-OrtChainSourceRoot) }
    foreach ($k in $Verdict.Keys) { $v[$k] = $Verdict[$k] }
    $v['Reference'] = @(Get-OrtTreeFact -ContentRoot $ReferenceDir) + @($ReferenceWheel | Where-Object { $_ } | ForEach-Object { Get-OrtArchiveFact -Path $_ })
    $v['Candidate'] = @(Get-OrtTreeFact -ContentRoot $ContentRoot -NameRoot $NameRoot -ExtraFile $ExtraFile -ExcludeRoot $ExcludeRoot)
    $v['CoreSha256'] = @($v['Reference'] | Where-Object { $CoreLib -and $_.Path -eq $CoreLib } | ForEach-Object Sha256)
    $v['Stamp'] = @{}
    foreach ($e in @($v['Contract'] | Where-Object { $_ })) {
        $p = Get-OrtStampPath -Consumer $e.Name -StampDir $StampDir
        $v['Stamp'][$e.Name] = if (Test-Path -LiteralPath $p -PathType Leaf) { Get-Content -LiteralPath $p -Raw } else { $null }
    }
    if (-not $NoDistribution) {
        $v['Distribution'] = @{}
        foreach ($root in (Select-OrtExistingDir $ContentRoot)) {
            foreach ($site in @(Find-OrtSitePackage -Root $root)) { $v['Distribution'][$site] = Get-OrtSitePackageOwner -SitePackages $site }
        }
    }
    if ($TreeAppDir) { $v['AppDir'] = @($v['Candidate'] | Where-Object { -not $_.Container -and $_.Name -like '*.exe' } | ForEach-Object { Split-Path -Parent $_.Path } | Sort-Object -Unique) }
    $findings = Get-OrtCensusFinding @v
    return [pscustomobject]@{
        Reference = $v['Reference']; Candidate = $v['Candidate']; Findings = @($findings); CoreSha256 = $v['CoreSha256']
        StampArmed = [bool]$v['RequireStamp']; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Write-OrtCensusReport {
    param([Parameter(Mandatory)][object]$Census, [string]$Title = 'ORT census')
    $inst = @($Census.Candidate | Where-Object IsInstance)
    $cons = @($Census.Candidate | Where-Object { Test-OrtConsumer -Fact $_ })
    Write-Host ('  {0}: {1} reference file(s), {2} binaries scanned, {3} ORT instance(s), {4} consumer(s), {5}s' -f `
            $Title, @($Census.Reference).Count, @($Census.Candidate).Count, $inst.Count, $cons.Count, $Census.Seconds)
    foreach ($f in @($Census.Findings)) {
        Write-Host ('    {0,-12} {1} -- {2}' -f $f.Verdict, $f.Path, $f.Detail) -ForegroundColor $(if ($f.Fatal) { 'Red' } else { 'DarkYellow' })
    }
}

function Invoke-OrtImageCensus {
    # G1 over a Windows image. -CrossTarget: the base image's Windows dir is not the device's, so it is neither scanned nor modeled.
    [CmdletBinding()]
    param(
        [string]$Arch = '',
        [switch]$CrossTarget,
        [AllowEmptyString()][string]$OrtVersion = '',
        [switch]$RequireStamp,
        [AllowEmptyCollection()][string[]]$Exemption = @()
    )
    Assert-OrtCensusDependency
    if (-not $Arch) { $Arch = Get-WindowsTargetArch }
    $prefix = Get-OrtChainPrefix
    $wheelDir = if ($env:PYTHON_WHEELS) { $env:PYTHON_WHEELS } else { 'C:\runtime\wheels' }
    $winDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $drive = [System.IO.Path]::GetPathRoot($winDir)
    # The Windows dir is scanned by ORT name only; Windows ML's API DLL carries the ORT ABI under another name.
    $inboxFile = @(if (-not $CrossTarget) { foreach ($d in 'System32', 'SysWOW64') { "$winDir\$d\onnxruntime.dll"; "$winDir\$d\Windows.AI.MachineLearning.dll" } })
    return Invoke-OrtCensus -ContentRoot @('C:\runtime', 'C:\temp\cpython', 'C:\opt', 'C:\Users') -NameRoot @($drive) `
        -ExtraFile $inboxFile `
        -ExcludeRoot @(if ($CrossTarget) { $winDir }) `
        -ReferenceDir @("$prefix\bin", "$prefix\lib") -ReferenceWheel @(Get-OrtChainWheel -WheelDir $wheelDir -OrtVersion $OrtVersion) `
        -CoreLib "$prefix\bin\onnxruntime.dll" -Verdict @{
            AllowedHome = @($prefix, $wheelDir); Contract = (Get-OrtConsumerContract); RequireStamp = [bool]$RequireStamp
            SearchPath = @("$env:PATH" -split ';' | Where-Object { $_ }); Exemption = $Exemption; Arch = $Arch
            System32 = $(if ($CrossTarget) { '' } else { Join-Path $winDir 'System32' })
            InboxRoot = @(if (-not $CrossTarget) { $winDir })
        }
}

function Test-OrtProvenanceTree {
    # G6, for consumer CI: every ORT binary under -Root is the image's chain ORT, and every importer finds it app-locally.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$ReferenceDir = @(),
        [AllowEmptyCollection()][string[]]$ReferenceWheel = @(),
        [string[]]$ChainRoot = (Get-OrtChainSourceRoot),
        [AllowEmptyCollection()][string[]]$Exemption = @(),
        [switch]$PassThru
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Test-OrtProvenanceTree: $Root is not a directory" }
    Assert-OrtCensusDependency
    if ($ReferenceDir.Count -eq 0 -and $ReferenceWheel.Count -eq 0) {
        $prefix = Get-OrtChainPrefix
        $ReferenceDir = @("$prefix\bin", "$prefix\lib")
        $ReferenceWheel = @(Get-OrtChainWheel -WheelDir $(if ($env:PYTHON_WHEELS) { $env:PYTHON_WHEELS } else { 'C:\runtime\wheels' }))
    }
    $census = Invoke-OrtCensus -ContentRoot @($Root) -ReferenceDir $ReferenceDir -ReferenceWheel $ReferenceWheel -TreeAppDir `
        -Verdict @{ ChainRoot = $ChainRoot; AssumeSystemOrt = $true; Exemption = $Exemption; Arch = (Get-WindowsTargetArch) }
    Write-OrtCensusReport -Census $census -Title "ORT provenance of $Root"
    if ($PassThru) { return $census }
    return (@($census.Findings | Where-Object Fatal).Count -eq 0)
}

Export-ModuleMember -Function @(
    'Get-OrtChainSourceRoot', 'Get-OrtChainPrefix', 'Get-OrtConsumerContract', 'Get-OrtStampPath', 'Test-OrtInstanceName',
    'Get-OrtSourceRoot', 'Get-OrtBinaryFact', 'Get-OrtArchiveFact', 'Get-OrtTreeFact', 'Get-OrtSitePackageOwner',
    'Get-OrtChainWheel', 'Test-OrtStampCurrent', 'Get-OrtCensusFinding', 'Invoke-OrtCensus', 'Write-OrtCensusReport',
    'Invoke-OrtImageCensus', 'Test-OrtProvenanceTree'
)

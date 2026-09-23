#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# G2 (owner rule 2026-09-23): a consumer's build tree (links followed), records, logs and fetch caches hold no ORT but the chain's; a
# pass stamps it for G1. Imports nothing. NOT covered: an ORT under a non-ORT name, pip's pre-23.3 http cache, what loads at run time.

Set-StrictMode -Version Latest

# ORT headers and binaries, compared byte for byte by name (.pc/.cmake metadata is not ORT code).
$script:OrtGateCodeName = [regex]::new('^(?:lib)?onnxruntime[^\\/]*\.(?:h|hpp|inc|lib|dll|pyd|a|so(?:\.[0-9]+)*)$|_provider_factory\.h$|^onnxruntime_pybind11_state', 'IgnoreCase')
# Any ORT library: the core, a provider, a static component (onnxruntime_session.lib), the pybind module; GenAI's and extensions' are not ORT.
$script:OrtGateBinaryName = [regex]::new('^(?:lib)?onnxruntime(?:_(?!genai|extensions)[a-z0-9_]+)?\.(?:dll|lib|a|so(?:\.[0-9]+)*)$|^onnxruntime_pybind11_state[^\\/]*\.(?:pyd|so)$', 'IgnoreCase')
$script:OrtGateArchive = [regex]::new('onnxruntime(?![_.-]?(?:genai|extensions))[^\\/]*\.(?:zip|nupkg|tgz|txz|tar|gz|xz|bz2|7z|whl|aar)$|\.tar\.lzma2$', 'IgnoreCase')
$script:OrtGateFetchedDir = [regex]::new('^(?:(?:ortlib|onnxruntime)-(?:src|subbuild|build)|ort\.pyke\.io|microsoft\.ml\.onnxruntime(?!genai)[a-z0-9.]*|(?:microsoft\.ml\.)?onnxruntime(?:[.-][a-z0-9]+)*-(?:win|linux|osx|android)-.+)$', 'IgnoreCase')
# A fetch names a download host, a package id, a release archive, or has ORT as a fetch verb's object.
$script:OrtGateFetchLine = [regex]::new('github\.com/microsoft/onnxruntime(?:-genai)?/releases/download|pkgs\.dev\.azure\.com|nuget\.org/\S*onnxruntime|microsoft\.ml\.onnxruntime(?!genai)|microsoft\.(?:windows\.)?ai\.machinelearning|(?:cdn|ort)\.pyke\.io|(?:pythonhosted|pypi)\.org/\S*onnxruntime|onnxruntime-(?:win|linux|osx|android)-[a-z0-9_]+-[0-9]|(?<![\w-])(?:collecting|downloading|fetching|extracting|populating)\s+(?:onnx runtime|onnxruntime|ortlib)(?![ _.-]?(?:genai|extensions))|\bapt(?:-get)?\s+install\b.*\blibonnxruntime', 'IgnoreCase')
# A quoted path in record text (flag prefix allowed), kept whole: `-I"C:/Program Files/x"`.
$script:OrtGateQuotedPath = [regex]::new('"(?:-I|-L|-isystem|/I|[-/]libpath:)?((?:[A-Za-z]:[\\/]|/[A-Za-z]/)[^"\r\n]*)"', 'IgnoreCase')

function Get-OrtGateStampPath {
    # One file per consumer; WindowsOrtProvenance.Common's Get-OrtStampPath reads the same path (a suite pins them equal).
    param([Parameter(Mandatory)][string]$Consumer, [string]$StampDir = 'C:\runtime\share\ort-provenance')
    return (Join-Path $StampDir "$Consumer.json")
}

function Get-OrtGateDefaultCache {
    # NuGet, pyke's ORT download, pip (built wheels + HTTP bodies) and uv, at each tool's override or its default under the profile.
    # The env spelling first (what a container sets, what a test redirects); the known folder only when it is unset.
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
    $user = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    $nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } elseif ($user) { Join-Path $user '.nuget\packages' }
    $uv = if ($env:UV_CACHE_DIR) { $env:UV_CACHE_DIR } elseif ($local) { Join-Path $local 'uv\cache' }
    $pip = if ($env:PIP_CACHE_DIR) { $env:PIP_CACHE_DIR } elseif ($local) { Join-Path $local 'pip\cache' }
    $pyke = if ($local) { Join-Path $local 'ort.pyke.io' }
    return @(@($nuget, $pyke, $pip, $uv) | Where-Object { $_ })
}

function ConvertTo-OrtGatePath {
    param([AllowEmptyString()][string]$Path)
    return $Path.Trim().Trim('"').Replace('\', '/').TrimEnd('/')
}

function Test-OrtGateUnder {
    param([AllowEmptyString()][string]$Path, [AllowEmptyCollection()][string[]]$Root)
    $p = ConvertTo-OrtGatePath $Path
    foreach ($raw in $Root) {
        if (-not $raw) { continue }
        $r = ConvertTo-OrtGatePath $raw
        if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith("$r/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-OrtGateSha {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return 'unreadable' }
}

function Add-OrtGateSha {
    param([hashtable]$Index, [string]$Leaf, [string]$Sha)
    if (-not $Index.Sha.ContainsKey($Leaf)) { $Index.Sha[$Leaf] = [System.Collections.Generic.HashSet[string]]::new() }
    [void]$Index.Sha[$Leaf].Add($Sha)
}

function Get-OrtGateChainWheel {
    # The chain ORT wheels of this version in the wheel store (normalised names; GenAI and extensions never match).
    param([AllowEmptyString()][string]$WheelDir, [AllowEmptyString()][string]$OrtVersion)
    if (-not $WheelDir -or -not $OrtVersion -or -not (Test-Path -LiteralPath $WheelDir -PathType Container)) { return @() }
    $pattern = "^onnxruntime(?:[_-](?!genai|extensions)[a-z0-9]+)?-$([regex]::Escape($OrtVersion.TrimStart('v')))-.*\.whl$"
    return @(Get-ChildItem -LiteralPath $WheelDir -Filter '*.whl' -File | Where-Object { $_.Name -match $pattern } | ForEach-Object FullName)
}

function Get-OrtGateChainIndex {
    # leaf -> the SHA256s the chain ships under that name (its install tree and its wheels), the anchors G1 reads, and gaps.
    param([Parameter(Mandatory)][string]$OrtRoot, [AllowEmptyCollection()][string[]]$ChainWheel = @())
    $index = @{
        Sha = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
        Archive = [System.Collections.Generic.HashSet[string]]::new(); Finding = [System.Collections.Generic.List[string]]::new(); Core = ''; CApi = ''
    }
    $walk = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; AttributesToSkip = [System.IO.FileAttributes]0 }
    foreach ($sub in 'include', 'lib', 'bin') {
        $dir = Join-Path $OrtRoot $sub
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, '*', $walk)) {
            $leaf = [System.IO.Path]::GetFileName($f)
            if (-not $script:OrtGateCodeName.IsMatch($leaf)) { continue }
            $sha = Get-OrtGateSha -Path $f
            Add-OrtGateSha -Index $index -Leaf $leaf -Sha $sha
            if ($sub -eq 'bin' -and $leaf -eq 'onnxruntime.dll') { $index.Core = $sha }
            if ($leaf -eq 'onnxruntime_c_api.h' -and -not $index.CApi) { $index.CApi = $sha }
        }
    }
    foreach ($wheel in $ChainWheel) {
        [void]$index.Archive.Add((Get-OrtGateSha -Path $wheel))
        $zip = [System.IO.Compression.ZipFile]::OpenRead($wheel)
        try {
            foreach ($e in @($zip.Entries | Where-Object { $_.Name -and $script:OrtGateCodeName.IsMatch($_.Name) })) {
                $s = $e.Open()
                try { Add-OrtGateSha -Index $index -Leaf $e.Name -Sha ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant()) } finally { $s.Dispose() }
            }
        } finally { $zip.Dispose() }
    }
    foreach ($anchor in 'onnxruntime_c_api.h', 'onnxruntime.lib', 'onnxruntime.dll') {
        if (-not $index.Sha.ContainsKey($anchor)) { $index.Finding.Add("the chain ONNX Runtime at $OrtRoot has no $anchor to compare against") }
    }
    if (-not $index.Core) { $index.Finding.Add("the chain ONNX Runtime at $OrtRoot has no bin\onnxruntime.dll, the core lib a stamp names") }
    return $index
}

function Get-OrtGateNameFinding {
    # One ORT-named file: chain bytes under a chain name; any other ORT binary name is foreign by definition.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Index, [hashtable]$Count)
    $leaf = [System.IO.Path]::GetFileName($Path)
    if ($script:OrtGateArchive.IsMatch($leaf)) {
        if (-not $Index.Archive.Contains((Get-OrtGateSha -Path $Path))) { "an ONNX Runtime archive: $Path" }
        return
    }
    if ($Index.Sha.ContainsKey($leaf)) {
        if ($Count) { $Count.Compared++ }
        if (-not $Index.Sha[$leaf].Contains((Get-OrtGateSha -Path $Path))) { "$Path is not the chain's $leaf (foreign ONNX Runtime bytes)" }
    } elseif ($script:OrtGateBinaryName.IsMatch($leaf)) {
        "$Path is an ONNX Runtime binary the chain does not build"
    }
}

function Get-OrtGateWheelBodyFinding {
    # pip's HTTP cache keeps a downloaded wheel as a hash-named body: a zip whose members sit under onnxruntime/. No zip, no wheel.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Index)
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($Path) } catch [System.IO.InvalidDataException] { return } catch { return "cannot read the cached file ${Path}: $($_.Exception.Message)" }
    try { $ort = @($zip.Entries | Where-Object { $_.FullName.StartsWith('onnxruntime/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 } finally { $zip.Dispose() }
    if ($ort -and -not $Index.Archive.Contains((Get-OrtGateSha -Path $Path))) { "pip's HTTP cache holds an ONNX Runtime wheel: $Path" }
}

function Get-OrtGateLinkTarget {
    # A directory link's (junction's) final target; $null for a reparse point that is no link, which is entered like any dir.
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    $t = [System.IO.Directory]::ResolveLinkTarget($Item.FullName, $true)
    if ($null -eq $t) { return $null }
    return $t.FullName
}

function Get-OrtGateTreeFinding {
    # Every file and dir under each root, hidden ones too. A dir link whose target leaves the roots, -Allowed (the chain and its
    # shims) and the OS dir is walked as well, and each link lands in -Link for the record paths spelled through it.
    param([AllowEmptyCollection()][string[]]$Root, [Parameter(Mandatory)][hashtable]$Index, [hashtable]$Count, [switch]$Cache,
        [AllowEmptyCollection()][string[]]$Allowed = @(), [System.Collections.IDictionary]$Link)
    $opt = [System.IO.EnumerationOptions]@{ AttributesToSkip = [System.IO.FileAttributes]0; IgnoreInaccessible = $false }
    $roots = @($Root | Where-Object { $_ })
    $stay = @($roots) + @($Allowed) + @([Environment]::GetFolderPath('Windows') | Where-Object { $_ })
    $walked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $stack = [System.Collections.Generic.Stack[object[]]]::new()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) {
            if (-not $Cache) { "no tree at $r to check" }
            continue
        }
        $stack.Push(@($r, '', ($Cache -and [System.IO.Path]::GetFileName($r.TrimEnd('\', '/')) -eq 'ort.pyke.io')))
    }
    while ($stack.Count -gt 0) {
        $dir, $via, $pyke = $stack.Pop()
        $sfx = if ($via) { " (through the link $via)" } else { '' }
        try { $entries = @([System.IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos('*', $opt)) } catch { "cannot read ${dir}: $($_.Exception.Message)"; continue }
        foreach ($e in $entries) {
            if ($e -is [System.IO.DirectoryInfo]) {
                if ($script:OrtGateFetchedDir.IsMatch($e.Name)) { "fetched ONNX Runtime content at $($e.FullName)$sfx" }
                $target = $null
                if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    try { $target = Get-OrtGateLinkTarget -Item $e } catch { "cannot resolve the link $($e.FullName)$($sfx): $($_.Exception.Message)"; continue }
                }
                if ($null -eq $target) { $stack.Push(@($e.FullName, $via, $pyke)); continue }
                if ($Link) { $Link[(ConvertTo-OrtGatePath $e.FullName)] = ConvertTo-OrtGatePath $target }
                if (-not (Test-Path -LiteralPath $target -PathType Container) -or (Test-OrtGateUnder -Path $target -Root $stay)) { continue }
                if (@($roots | Where-Object { Test-OrtGateUnder -Path $_ -Root @($target) }).Count -gt 0) { "the link $($e.FullName) points at $target, which holds the tree itself"; continue }
                if ($walked.Add((ConvertTo-OrtGatePath $target))) { $stack.Push(@($target, $e.FullName, $pyke)) }
                continue
            }
            if ($Count -and -not $Cache) { $Count.Files++ }
            if ($pyke) { "pyke's ORT download cache holds $($e.FullName)$sfx"; continue }
            if ($e.Name -match 'onnxruntime|_provider_factory\.h$|\.tar\.lzma2$') {
                Get-OrtGateNameFinding -Path $e.FullName -Index $Index -Count $Count | ForEach-Object { "$_$sfx" }
            } elseif ($Cache -and $e.FullName -match '[\\/]http-v2[\\/]') {
                Get-OrtGateWheelBodyFinding -Path $e.FullName -Index $Index
            }
        }
    }
}

function Resolve-OrtGateLinkedPath {
    # A path spelled through a dir link the tree walk met, rewritten to its target (a link inside the target resolves in turn).
    param([Parameter(Mandatory)][string]$Path, [System.Collections.IDictionary]$Link)
    $p = ConvertTo-OrtGatePath $Path
    if (-not $Link -or $Link.Count -eq 0) { return $p }
    for ($i = 0; $i -lt 16; $i++) {
        $hit = @($Link.Keys | Where-Object { Test-OrtGateUnder -Path $p -Root @($_) } | Sort-Object Length -Descending | Select-Object -First 1)
        if ($hit.Count -eq 0) { return $p }
        $p = $Link[$hit[0]] + $p.Substring($hit[0].Length)
    }
    return $p
}

function Get-OrtGateArgPath {
    # One argument that may be a single path (a cache value, a JSON element, a quoted span): an absolute one is kept whole.
    param([AllowEmptyString()][string]$Arg)
    $a = $Arg.Trim().Trim('"') -replace '^(?i:-I|-L|-isystem|-idirafter|-iquote|/I|[-/]libpath:|-Wl,-rpath,)', ''
    if ($a -match '\s[-/][A-Za-z]') { return @(Get-OrtGatePathToken -Text $Arg) }
    if ($a -match '^[A-Za-z]:[\\/]') { return @(ConvertTo-OrtGatePath $a) }
    if ($a -match '^/([A-Za-z])/(.*)$') { return @(ConvertTo-OrtGatePath "$($Matches[1]):/$($Matches[2])") }
    return @(Get-OrtGatePathToken -Text $Arg)
}

function Get-OrtGatePathToken {
    # The absolute paths in record text: drive and MSYS /c/ paths, ninja's escapes read (`$ ` stays in the path), a quoted one whole.
    param([AllowEmptyString()][string]$Text)
    $t = $Text.Replace('$$', "`u{2}").Replace("`$`r`n", "`r`n").Replace("`$`n", "`n").Replace('$ ', "`u{1}").Replace('$:', ':')
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $restore = { param([string]$s) $s.Replace("`u{1}", ' ').Replace("`u{2}", '$') }
    foreach ($m in $script:OrtGateQuotedPath.Matches($t)) { foreach ($p in @(Get-OrtGateArgPath -Arg (& $restore $m.Groups[1].Value))) { [void]$seen.Add($p) } }
    $t = $script:OrtGateQuotedPath.Replace($t, ' ')
    $tail = [char[]]@(')', ']', '.')
    foreach ($m in [regex]::Matches($t, '(?<![A-Za-z0-9][A-Za-z0-9])[A-Za-z]:[\\/](?![\\/])[^\s"''<>|;,*?]*')) { [void]$seen.Add((ConvertTo-OrtGatePath (& $restore $m.Value.TrimEnd($tail)))) }
    foreach ($m in [regex]::Matches($t, '(?m)(?<=^|[\s"''=(,;]|-I|-L|(?<![A-Za-z])[A-Za-z]{3,}:)/([A-Za-z])/([^\s"''<>|;,*?]*)')) {
        $rest = (& $restore $m.Groups[2].Value).TrimEnd($tail)
        [void]$seen.Add((ConvertTo-OrtGatePath ($m.Groups[1].Value + ':/' + $rest)))
    }
    return @($seen)
}

function Get-OrtGateRecordToken {
    # A record's paths in its own format: CMakeCache values whole (split on ';'), every string of a meson JSON whole, else text.
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $values = [System.Collections.Generic.List[string]]::new()
    if ([System.IO.Path]::GetFileName($Path) -eq 'CMakeCache.txt') {
        foreach ($m in [regex]::Matches($text, '(?m)^(?!//|#)[^:=\r\n]+:[A-Za-z_]+=(.*?)\r?$')) { $values.AddRange([string[]]$m.Groups[1].Value.Split(';')) }
    } elseif ($Path -match '\.json$') {
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push((ConvertFrom-Json -InputObject $text -AsHashtable))
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -is [string]) { $values.Add($n) }
            elseif ($n -is [System.Collections.IDictionary]) { foreach ($v in $n.Values) { $stack.Push($v) } }
            elseif ($n -is [System.Collections.IEnumerable]) { foreach ($v in $n) { $stack.Push($v) } }
        }
    } else {
        foreach ($p in (Get-OrtGatePathToken -Text $text)) { [void]$seen.Add($p) }
    }
    foreach ($a in $values) { foreach ($p in @(Get-OrtGateArgPath -Arg $a)) { [void]$seen.Add($p) } }
    return @($seen)
}

function Get-OrtGateRecordFinding {
    # A record may name ORT only under the chain, a shim or the tree (read through the tree's links); a foreign include or lib dir
    # holding ORT is a finding. The Windows dir is the OS's, not a build input: which ORT loads from System32 is G1's question.
    param([AllowEmptyCollection()][string[]]$Record, [Parameter(Mandatory)][hashtable]$Index, [string[]]$ChainRoot, [string[]]$Allowed, [hashtable]$Count,
        [System.Collections.IDictionary]$Link)
    $os = @([Environment]::GetFolderPath('Windows') | Where-Object { $_ })
    $segment = [regex]::new('/(?:onnxruntime|ortlib-src|ort\.pyke\.io|microsoft\.ml\.onnxruntime(?!genai)[^/]*|(?:microsoft\.ml\.)?onnxruntime(?:[.-][a-z0-9]+)*-(?:win|linux|osx|android)-[^/]+|onnxruntime-(?:src|build|subbuild))(?:/|$)', 'IgnoreCase')
    foreach ($rec in @($Record | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $rec -PathType Leaf)) { "the build record $rec is missing"; continue }
        try { $tokens = @(Get-OrtGateRecordToken -Path $rec) } catch { "the build record $rec cannot be read: $($_.Exception.Message)"; continue }
        foreach ($tok in $tokens) {
            if ($Count) { $Count.Tokens++ }
            $real = Resolve-OrtGateLinkedPath -Path $tok -Link $Link
            if ((Test-OrtGateUnder -Path $tok -Root $ChainRoot) -or (Test-OrtGateUnder -Path $real -Root $ChainRoot)) { if ($Count) { $Count.ChainRefs++ }; continue }
            $leaf = ($real -split '/')[-1]
            $ortLeaf = $Index.Sha.ContainsKey($leaf) -or $script:OrtGateBinaryName.IsMatch($leaf)
            if (Test-OrtGateUnder -Path $real -Root $Allowed) {
                if ($ortLeaf -and (Test-Path -LiteralPath $real -PathType Leaf)) { Get-OrtGateNameFinding -Path $real -Index $Index | ForEach-Object { "${rec}: $_" } }
                continue
            }
            $named = if ($real -ne $tok) { "$tok (= $real)" } else { $tok }
            if ($ortLeaf) {
                if (Test-Path -LiteralPath $real -PathType Leaf) { Get-OrtGateNameFinding -Path $real -Index $Index | ForEach-Object { "${rec}: $_" } }
                else { "${rec} names $named, an ONNX Runtime file outside the chain (not on disk to compare)" }
            } elseif ($segment.IsMatch($real)) {
                "${rec} names an ONNX Runtime path outside the chain: $named"
            } elseif (-not (Test-OrtGateUnder -Path $real -Root $os) -and (Test-Path -LiteralPath $real -PathType Container)) {
                foreach ($d in @($real, "$real/onnxruntime", "$real/onnxruntime/core/session") | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) {
                    foreach ($f in @([System.IO.Directory]::EnumerateFiles($d, '*onnxruntime*')) + @([System.IO.Directory]::EnumerateFiles($d, '*_provider_factory.h'))) {
                        Get-OrtGateNameFinding -Path $f -Index $Index | ForEach-Object { "${rec} searches ${d}: $_" }
                    }
                }
            }
        }
    }
}

function Get-OrtGateLogFinding {
    # Download, FetchContent, NuGet, pip and apt traces of an ORT in the configure/build logs.
    param([AllowEmptyCollection()][string[]]$Log)
    foreach ($l in @($Log | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $l -PathType Leaf)) { "the build log $l is missing"; continue }
        $n = 0
        foreach ($line in [System.IO.File]::ReadLines($l)) {
            $n++
            if ($script:OrtGateFetchLine.IsMatch($line)) { "${l}:${n} fetches an ONNX Runtime: $($line.Trim())" }
        }
    }
}

function Assert-ChainOrtOnly {
    # G2: throws on any finding (its own or -Finding from the consumer's gate); on a pass writes the G1 stamp.
    # -Shim: a dir the consumer built from the chain (a header or ORT_HOME copy). -TreeRoot: source + build trees. -Log: at least one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string]$Consumer,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TreeRoot,
        [AllowEmptyCollection()][string[]]$Record = @(),
        [AllowEmptyCollection()][string[]]$Log = @(),
        [AllowEmptyCollection()][string[]]$Shim = @(),
        [AllowEmptyCollection()][string[]]$CacheRoot = (Get-OrtGateDefaultCache),
        [AllowEmptyCollection()][string[]]$Finding = @(),
        [string]$OrtRoot = $(if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { 'C:\runtime\lib\onnxruntime-source' }),
        [AllowEmptyString()][string]$WheelDir = $(if ($env:PYTHON_WHEELS) { $env:PYTHON_WHEELS } else { 'C:\runtime\wheels' }),
        [AllowEmptyString()][string]$OrtVersion = "$env:ONNXRUNTIME_VERSION",
        [string]$StampDir = 'C:\runtime\share\ort-provenance'
    )
    $stamp = Get-OrtGateStampPath -Consumer $Consumer -StampDir $StampDir
    if (Test-Path -LiteralPath $stamp) { Remove-Item -LiteralPath $stamp -Force }
    $index = Get-OrtGateChainIndex -OrtRoot $OrtRoot -ChainWheel (Get-OrtGateChainWheel -WheelDir $WheelDir -OrtVersion $OrtVersion)
    $count = @{ Files = 0; Compared = 0; Tokens = 0; ChainRefs = 0 }
    $refs = @(@($OrtRoot) + @($Shim) | Where-Object { $_ })
    $given = @(@($TreeRoot) + @($Shim) | Where-Object { $_ } | ForEach-Object { ConvertTo-OrtGatePath $_ } | Select-Object -Unique)
    $trees = @($given | Where-Object { $t = $_; -not @($given | Where-Object { $_ -ne $t -and (Test-OrtGateUnder -Path $t -Root @($_)) }) })
    $link = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $logs = @($Log | Where-Object { $_ })
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @($Finding | Where-Object { $_ })) { $all.Add("consumer gate: $f") }
    foreach ($f in $index.Finding) { $all.Add($f) }
    if ($trees.Count -eq 0) { $all.Add('no source or build tree was given, so nothing was checked') }
    foreach ($f in @(Get-OrtGateTreeFinding -Root $trees -Index $index -Count $count -Allowed $refs -Link $link)) { $all.Add($f) }
    if ($trees.Count -gt 0 -and $count.Files -eq 0) { $all.Add("the tree(s) $($trees -join ', ') hold no files: a vacuous scan, not a clean build") }
    foreach ($f in @(Get-OrtGateTreeFinding -Root $CacheRoot -Index $index -Cache -Allowed $refs)) { $all.Add($f) }
    foreach ($f in @(Get-OrtGateRecordFinding -Record $Record -Index $index -ChainRoot $refs -Allowed $trees -Count $count -Link $link)) { $all.Add($f) }
    if ($count.ChainRefs -eq 0) { $all.Add("no build record names the chain ONNX Runtime at $OrtRoot or a shim of it, so nothing proves the build used it") }
    if ($logs.Count -eq 0) { $all.Add('no build log was given, so no configure or build step was checked for an ONNX Runtime fetch') }
    foreach ($f in @(Get-OrtGateLogFinding -Log $logs)) { $all.Add($f) }
    if ($all.Count -gt 0) {
        foreach ($f in ($all | Select-Object -First 200)) { Write-Host "  ORT gate ($Consumer) FAIL: $f" -ForegroundColor Red }
        throw "ORT gate ($Consumer): $($all.Count) finding(s), the build reached an ONNX Runtime other than the chain's at ${OrtRoot}: $(($all | Select-Object -First 10) -join ' | ')"
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp)
    $json = [ordered]@{
        consumer = $Consumer; gate = 'Assert-ChainOrtOnly'; ortRoot = $OrtRoot; coreLibSha256 = $index.Core; cApiHeaderSha256 = $index.CApi
        treeFiles = "$($count.Files)"; ortFilesCompared = "$($count.Compared)"; recordPaths = "$($count.Tokens)"; chainReferences = "$($count.ChainRefs)"
    }
    [System.IO.File]::WriteAllText($stamp, ($json | ConvertTo-Json) + "`n")
    Write-Host ("ORT gate ($Consumer) OK: $($count.Files) file(s) in $($trees.Count) tree(s), $($count.Compared) ORT file(s) byte-identical to the chain, " +
        "$($count.Tokens) record path(s) ($($count.ChainRefs) naming the chain), $($logs.Count) log(s); stamp $stamp")
}

Export-ModuleMember -Function @(
    'Get-OrtGateStampPath', 'Get-OrtGateDefaultCache', 'Get-OrtGateChainIndex', 'Get-OrtGateTreeFinding', 'Get-OrtGatePathToken',
    'Get-OrtGateRecordToken', 'Get-OrtGateRecordFinding', 'Get-OrtGateLogFinding', 'Assert-ChainOrtOnly'
)

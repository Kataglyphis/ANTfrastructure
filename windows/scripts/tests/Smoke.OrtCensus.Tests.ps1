#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Smoke §25 (G1) and Test-OrtProvenanceTree (G6): the ORT census over synthetic PE trees, one verdict per case.
# NOT covered: a real image or ORT build; the fingerprint strings are the shapes measured on 2026-09-23.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1') -Force -DisableNameChecking

$script:ChainSrc = 'C:\temp\onnx-src\onnxruntime\core\session\inference_session.cc'
# The string Windows ML's in-box onnxruntime.dll 1.17 carries (measured on this host's System32 copy).
$script:ForeignSrc = 'C:\__w\1\s\onnxruntime\core\session\inference_session.cc'
$script:SmokeScript = 'windows\scripts\build\Test-Container.ps1'

# A PE32+ with one section holding an import table for -Import and each -Text as a NUL-bounded string.
function New-OrtTestPe {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Import = @(), [string[]]$Text = @())
    $rva = 0x1000
    $descSize = 20 * ($Import.Count + 1)
    $names = [System.Collections.Generic.List[byte]]::new()
    $body = [System.Collections.Generic.List[byte]]::new()
    $nameAt = foreach ($i in $Import) { $descSize + $names.Count; $names.AddRange([System.Text.Encoding]::ASCII.GetBytes("$i`0")) }
    foreach ($at in @($nameAt)) { $d = [byte[]]::new(20); [BitConverter]::GetBytes([uint32]($rva + $at)).CopyTo($d, 12); $body.AddRange($d) }
    $body.AddRange([byte[]]::new(20))
    $body.AddRange($names)
    foreach ($t in $Text) { $body.Add(0); $body.AddRange([System.Text.Encoding]::ASCII.GetBytes($t)); $body.Add(0) }
    $raw = $body.ToArray()
    $h = [byte[]]::new(0x200)
    $h[0] = 0x4D; $h[1] = 0x5A; $h[0x40] = 0x50; $h[0x41] = 0x45
    [BitConverter]::GetBytes([uint32]0x40).CopyTo($h, 0x3C)
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($h, 0x44)
    [BitConverter]::GetBytes([uint16]1).CopyTo($h, 0x46)
    [BitConverter]::GetBytes([uint16]0xF0).CopyTo($h, 0x54)
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($h, 0x58)
    [BitConverter]::GetBytes([uint32]16).CopyTo($h, 0x58 + 108)
    [BitConverter]::GetBytes([uint32]$rva).CopyTo($h, 0x58 + 120)
    [BitConverter]::GetBytes([uint32]$descSize).CopyTo($h, 0x58 + 124)
    [System.Text.Encoding]::ASCII.GetBytes('.rdata').CopyTo($h, 0x148)
    [BitConverter]::GetBytes([uint32]$raw.Length).CopyTo($h, 0x148 + 8)
    [BitConverter]::GetBytes([uint32]$rva).CopyTo($h, 0x148 + 12)
    [BitConverter]::GetBytes([uint32]$raw.Length).CopyTo($h, 0x148 + 16)
    [BitConverter]::GetBytes([uint32]0x200).CopyTo($h, 0x148 + 20)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    [System.IO.File]::WriteAllBytes($Path, [byte[]]($h + $raw + [byte[]]::new([Math]::Max(0, 2048 - $h.Length - $raw.Length))))
}

function New-OrtTestWheel {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Member)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($name in $Member.Keys) {
            $s = $zip.CreateEntry($name).Open()
            try { $bytes = [System.IO.File]::ReadAllBytes($Member[$name]); $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function New-OrtTestDist {
    param([Parameter(Mandatory)][string]$Site, [Parameter(Mandatory)][string]$Dist)
    $info = Join-Path $Site "$Dist.dist-info"
    $null = New-Item -ItemType Directory -Force -Path $info
    Set-Content -LiteralPath (Join-Path $info 'RECORD') "onnxruntime/__init__.py,sha256=x,1`nonnxruntime/capi/onnxruntime.dll,sha256=y,2" -Encoding ASCII
}

# A healthy image-shaped tree: the chain prefix, a venv copy in capi, a registered consumer, one wheel store.
function New-OrtTestImage {
    param([Parameter(Mandatory)][string]$Dir)
    $chain = Join-Path $Dir 'runtime\lib\onnxruntime-source'
    New-OrtTestPe -Path "$chain\bin\onnxruntime.dll" -Text @($script:ChainSrc, 'OrtGetApiBase', 'CreateEpFactories')
    New-OrtTestPe -Path "$chain\bin\onnxruntime_providers_shared.dll" -Text @('provider bridge')
    $capi = Join-Path $Dir 'opt\venv\Lib\site-packages\onnxruntime\capi'
    $null = New-Item -ItemType Directory -Force -Path $capi
    Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll" -Destination $capi
    New-OrtTestDist -Site (Join-Path $Dir 'opt\venv\Lib\site-packages') -Dist 'onnxruntime-1.30.0'
    New-OrtTestPe -Path (Join-Path $Dir 'runtime\lib\gstreamer-1.0\gstonnx.dll') -Import @('onnxruntime.dll', 'KERNEL32.dll') -Text @('OrtGetApiBase')
    New-OrtTestWheel -Path (Join-Path $Dir 'runtime\wheels\onnxruntime-1.30.0-cp314-cp314-win_amd64.whl') -Member @{ 'onnxruntime/capi/onnxruntime.dll' = "$chain\bin\onnxruntime.dll" }
    return $chain
}

# The image-mode census over $Dir, with the knobs Invoke-OrtImageCensus passes; -Set overrides any of them.
function Invoke-OrtTestCensus {
    param([Parameter(Mandatory)][string]$Dir, [hashtable]$Set = @{})
    $chain = Join-Path $Dir 'runtime\lib\onnxruntime-source'
    $wheels = Join-Path $Dir 'runtime\wheels'
    $p = @{
        ContentRoot = @((Join-Path $Dir 'runtime'), (Join-Path $Dir 'opt')); ReferenceDir = @("$chain\bin", "$chain\lib")
        ReferenceWheel = @(Get-OrtChainWheel -WheelDir $wheels -OrtVersion 'v1.30.0')
        StampDir = (Join-Path $Dir 'runtime\share\ort-provenance'); CoreLib = "$chain\bin\onnxruntime.dll"
        Verdict = @{ AllowedHome = @($chain, $wheels); Contract = (Get-OrtConsumerContract); SearchPath = @("$chain\bin"); System32 = (Join-Path $Dir 'System32') }
    }
    $scan = (Get-Command Invoke-OrtCensus).Parameters.Keys
    foreach ($k in $Set.Keys) { if ($scan -contains $k) { $p[$k] = $Set[$k] } else { $p.Verdict[$k] = $Set[$k] } }
    return Invoke-OrtCensus @p
}

function Get-OrtTestFatal {
    param([Parameter(Mandatory)][object]$Census, [string]$Verdict = '')
    return @($Census.Findings | Where-Object { $_.Fatal -and (-not $Verdict -or $_.Verdict -eq $Verdict) })
}

# A G6 tree from a layout, then its census: 'host' = an exe, 'import' = a PE importing onnxruntime.dll, 'chain' = the chain copy.
function Invoke-OrtLoaderTree {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Chain, [Parameter(Mandatory)][System.Collections.IDictionary]$Layout)
    foreach ($rel in $Layout.Keys) {
        $p = Join-Path $Root $rel
        switch ($Layout[$rel]) {
            'host' { New-OrtTestPe -Path $p -Text @('host') }
            'import' { New-OrtTestPe -Path $p -Import @('onnxruntime.dll') -Text @('OrtGetApiBase') }
            'chain' { $null = New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent); Copy-Item -LiteralPath "$Chain\bin\onnxruntime.dll" -Destination $p }
            default { throw "Invoke-OrtLoaderTree: unknown kind '$_'" }
        }
    }
    return Test-OrtProvenanceTree -Root $Root -ReferenceDir @("$Chain\bin") -PassThru
}

Describe 'ORT census: source fingerprints' {
    It 'reads the build root off Windows, POSIX and forward-slash paths, and skips URLs' {
        $t = "x`0ZvC:\__w\1\s\onnxruntime\core\a.cc`0/opt/onnxruntime/onnxruntime/contrib_ops/b.cc`0C:/temp/onnx-src/include/onnxruntime/core/c.h`0"
        $t += "https://github.com/microsoft/onnxruntime/blob/main/onnxruntime/core/d.cc`0build/onnxruntime/core/e.cc"
        Assert-Equal 'C:\__w\1\s|/opt/onnxruntime|C:\temp\onnx-src\include|' ((Get-OrtSourceRoot -Text $t) -join '|') 'garbage before the drive, POSIX, slashes, URL skipped, relative = empty'
    }

    It 'finds a fingerprint whole across the 8 MiB read boundary, wherever the boundary falls' {
        Invoke-InTestDir { param($dir)
            foreach ($cut in 3, 20) {
                $bytes = [byte[]]::new(8MB + 64)
                $src = [System.Text.Encoding]::ASCII.GetBytes('C:\legacy-root\onnxruntime\core\a.cc')
                $src.CopyTo($bytes, 8MB - $cut)
                $f = Join-Path $dir "cut$cut.bin"
                [System.IO.File]::WriteAllBytes($f, $bytes)
                $fact = Get-OrtBinaryFact -Path $f
                Assert-Equal 'C:\legacy-root' ($fact.Roots -join '|') "boundary $cut bytes into the string"
                Assert-True $fact.IsInstance 'a fingerprint makes an instance, whatever the name'
            }
        }
    }

    It 'facts carry the file hash, ABI markers and PE imports, and name-only instances' {
        Invoke-InTestDir { param($dir)
            New-OrtTestPe -Path "$dir\c.dll" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            $c = Get-OrtBinaryFact -Path "$dir\c.dll"
            Assert-Equal (Get-FileHash -LiteralPath "$dir\c.dll" -Algorithm SHA256).Hash.ToLowerInvariant() $c.Sha256 'sha256'
            Assert-Equal 'OrtGetApiBase' ($c.Abi -join ',') 'ABI marker'
            Assert-Equal 'onnxruntime.dll' ($c.Imports -join ',') 'import table read'
            Assert-False $c.IsInstance 'a consumer is not an instance'
            Set-Content -LiteralPath "$dir\onnxruntime_providers_webgpu.dll" 'random' -Encoding ASCII
            Assert-True (Get-OrtBinaryFact -Path "$dir\onnxruntime_providers_webgpu.dll").IsInstance 'ORT-named = instance'
            Assert-False (Test-OrtInstanceName -Name 'onnxruntime-genai.dll') 'GenAI is a consumer, never an instance'
        }
    }
}

Describe 'ORT census: verdicts (image mode)' {
    It 'a healthy tree has no fatal finding' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            $c = Invoke-OrtTestCensus -Dir $dir
            Assert-Equal '' ((Get-OrtTestFatal $c | ForEach-Object { "$($_.Verdict) $($_.Path)" }) -join '; ') 'clean'
            Assert-True (@($c.Candidate | Where-Object IsInstance).Count -ge 4) 'chain dlls, capi copy and the wheel member were all seen'
        }
    }

    It 'FOREIGN: Windows ML-built bytes under the ORT name and renamed (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\opt\x\onnxruntime.dll" -Text @($script:ForeignSrc)
            New-OrtTestPe -Path "$dir\opt\x\innocent.dll" -Text @($script:ForeignSrc)
            New-OrtTestPe -Path "$dir\opt\x\payload.bin" -Text @($script:ForeignSrc)
            # An ELF shared object in a Windows tree (a staged Linux/Android SDK) is read by extension, not MZ.
            [System.IO.File]::WriteAllBytes("$dir\opt\x\libvendor.so", [byte[]](@(0x7F, 0x45, 0x4C, 0x46) + @(0) * 60 +
                    [System.Text.Encoding]::ASCII.GetBytes("`0/home/runner/ort/onnxruntime/core/session/x.cc`0")))
            $f = Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'FOREIGN'
            Assert-Equal 4 $f.Count 'all four, by content, whatever the name, extension or format'
            Assert-Match 'C:\\__w\\1\\s' ($f[0].Detail) 'names the foreign build root'
        }
    }

    It 'STALE: a chain-rooted build whose bytes are not this chain (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\runtime\bin\onnxruntime.dll" -Text @($script:ChainSrc, 'FileVersion 1.27.0')
            Assert-Equal "$dir\runtime\bin\onnxruntime.dll" ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'STALE').Path -join ',') 'stale copy'
        }
    }

    It 'UNPROVEN: an ORT-named binary with no fingerprint and foreign bytes (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\opt\venv\Lib\site-packages\ep\onnxruntime_providers_webgpu.dll" -Text @('prebuilt plugin EP')
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'UNPROVEN').Count 'unproven'
            Set-Content -LiteralPath "$dir\opt\scipy-1.18.0-cp314-cp314-win_amd64.whl" 'not a zip' -Encoding ASCII
            Set-Content -LiteralPath "$dir\opt\onnxruntime-1.27.0-cp314-cp314-win_amd64.whl" 'not a zip' -Encoding ASCII
            $u = @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'UNPROVEN' | ForEach-Object { Split-Path $_.Path -Leaf })
            Assert-Equal 2 $u.Count "the EP and the unreadable ORT archive, not the corrupt scipy wheel (got: $($u -join ', '))"
            Assert-True ($u -contains 'onnxruntime-1.27.0-cp314-cp314-win_amd64.whl') 'an unreadable ORT archive cannot be proven'
        }
    }

    It 'ELSEWHERE: a chain-identical copy outside its homes; capi and the wheel store are homes (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            $bin = Join-Path $dir 'runtime\lib\opencv5\x64\vc18\bin'
            $null = New-Item -ItemType Directory -Force -Path $bin
            Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll" -Destination $bin
            Assert-Equal "$bin\onnxruntime.dll" ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'ELSEWHERE').Path -join ',') 'the opencv5 bin copy'
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ AllowedHome = $null }) 'ELSEWHERE').Count 'arm off in tree mode'
        }
    }

    It 'UNREGISTERED: an ORT ABI user outside the contract; contract entries pass (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\opt\app\mystery.dll" -Text @('OrtGetApiBase')
            New-OrtTestPe -Path "$dir\runtime\bin\avfilter-11.dll" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            $f = Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'UNREGISTERED'
            Assert-Equal "$dir\opt\app\mystery.dll" ($f.Path -join ',') 'only the stranger'
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ Contract = $null }) 'UNREGISTERED').Count 'arm off without a contract'
        }
    }

    It 'STAMP: armed, a present consumer needs a stamp naming the chain core sha (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            $core = (Get-FileHash -LiteralPath "$chain\bin\onnxruntime.dll" -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'STAMP').Count 'unarmed = no verdict'
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ RequireStamp = $true }) 'STAMP').Count 'missing stamp'
            $stampDir = Join-Path $dir 'runtime\share\ort-provenance'
            $null = New-Item -ItemType Directory -Force -Path $stampDir
            Set-Content -LiteralPath "$stampDir\gstreamer.json" (@{ consumer = 'gstreamer'; ortCoreSha256 = ('0' * 64) } | ConvertTo-Json) -Encoding ASCII
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ RequireStamp = $true }) 'STAMP').Count 'a stamp from another ORT'
            Set-Content -LiteralPath "$stampDir\gstreamer.json" (@{ consumer = 'gstreamer'; ortCoreSha256 = $core.ToUpperInvariant() } | ConvertTo-Json) -Encoding ASCII
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ RequireStamp = $true }) 'STAMP').Count 'current stamp'
            Assert-False (Test-OrtStampCurrent -Text (@{ consumer = 'opencv'; x = $core } | ConvertTo-Json) -Consumer 'gstreamer' -CoreSha256 @($core)) 'another consumer''s stamp'
        }
    }

    It 'DIST: two distributions own the onnxruntime import package (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            $site = Join-Path $dir 'opt\venv\Lib\site-packages'
            New-OrtTestDist -Site $site -Dist 'onnxruntime_gpu-1.30.0'
            New-OrtTestDist -Site $site -Dist 'onnxruntime_genai-0.15.2'
            Set-Content -LiteralPath (Join-Path $site 'onnxruntime_genai-0.15.2.dist-info\RECORD') 'onnxruntime_genai/__init__.py,,' -Encoding ASCII
            Assert-Equal 'onnxruntime,onnxruntime-gpu' ((Get-OrtSitePackageOwner -SitePackages $site) -join ',') 'genai owns onnxruntime_genai, not onnxruntime'
            Assert-Equal $site ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'DIST').Path -join ',') 'dist'
        }
    }

    It 'NONE: an empty reference, and a scan that found no ORT binary (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            Assert-True (@(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ ReferenceDir = @("$dir\nothing"); ReferenceWheel = @() }) 'NONE').Count -ge 1) 'no reference'
            Assert-True (@(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ ContentRoot = @("$dir\runtime\lib\gstreamer-1.0") }) 'NONE').Count -ge 1) 'nothing found'
        }
    }

    It 'UNRESOLVED: no copy on the path, and a System32 copy that shadows PATH (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            $f = Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ SearchPath = @() }) 'UNRESOLVED'
            Assert-Match 'no onnxruntime\.dll on its search path' ($f.Detail -join ';') 'nothing to load'
            $chainBin = Join-Path $dir 'runtime\lib\onnxruntime-source\bin'
            $odd = Invoke-OrtTestCensus -Dir $dir -Set @{ SearchPath = @('Q:\no-such-drive', '"relative"', "`"$chainBin\`"") }
            Assert-Equal 0 @(Get-OrtTestFatal $odd 'UNRESOLVED').Count 'a missing drive, a relative entry and a quoted one on PATH are all survivable'
            New-OrtTestPe -Path "$dir\System32\onnxruntime.dll" -Text @($script:ForeignSrc)
            $c = Invoke-OrtTestCensus -Dir $dir -Set @{ ExtraFile = @("$dir\System32\onnxruntime.dll") }
            Assert-Match 'System32\\onnxruntime\.dll, which is not the chain ORT' ((Get-OrtTestFatal $c 'UNRESOLVED').Detail -join ';') 'System32 wins over PATH'
            Assert-Equal "$dir\System32\onnxruntime.dll" ((Get-OrtTestFatal $c 'FOREIGN').Path -join ',') 'and is itself foreign'
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ System32 = ''; ExtraFile = @("$dir\System32\onnxruntime.dll") }) 'UNRESOLVED').Count 'cross lane: System32 not modeled'
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ NameRoot = @($dir) }) 'FOREIGN').Count 'the whole-drive name scan finds the System32 copy'
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ NameRoot = @($dir); ExcludeRoot = @("$dir\System32") }) 'FOREIGN').Count 'cross lane: the base image''s Windows dir is not scanned'
        }
    }

    It 'FOREIGN: the chain reference itself built elsewhere (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$chain\lib\onnxruntime_providers_cuda.dll" -Text @($script:ForeignSrc)
            Assert-Match 'the chain reference itself' ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'FOREIGN').Detail -join ';') 'reference self-check'
        }
    }

    It 'archives: a foreign wheel in a cache is FOREIGN; only the chain wheel is reference (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\tmp\pypi.dll" -Text @($script:ForeignSrc)
            New-OrtTestWheel -Path "$dir\opt\cache\onnxruntime-1.27.0-cp314-cp314-win_amd64.whl" -Member @{ 'onnxruntime/capi/onnxruntime.dll' = "$dir\tmp\pypi.dll" }
            $f = Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir) 'FOREIGN'
            Assert-Match '1\.27\.0-cp314-cp314-win_amd64\.whl!onnxruntime/capi/onnxruntime\.dll$' ($f.Path -join ',') 'member path'
            foreach ($n in 'onnxruntime_gpu-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime_genai-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime-1.29.0-cp314-cp314-win_amd64.whl') {
                Set-Content -LiteralPath "$dir\runtime\wheels\$n" 'x' -Encoding ASCII
            }
            $w = @(Get-OrtChainWheel -WheelDir "$dir\runtime\wheels" -OrtVersion 'v1.30.0' | ForEach-Object { Split-Path $_ -Leaf })
            Assert-Equal 2 $w.Count "gpu in, genai and old versions out (got: $($w -join ', '))"
            Assert-True ($w -contains 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl' -and $w -contains 'onnxruntime_gpu-1.30.0-cp314-cp314-win_amd64.whl') 'the two 1.30.0 ORT wheels'
        }
    }

    It 'exemptions waive one path, and fail when stale, malformed or foreign-arch (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-OrtTestImage -Dir $dir
            New-OrtTestPe -Path "$dir\opt\x\onnxruntime.dll" -Text @($script:ForeignSrc)
            $x = "$dir\opt\x\onnxruntime.dll"
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ Exemption = @("amd64:${x}:reviewed") })).Count 'waived'
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ Exemption = @("arm64:${x}:reviewed") }) 'FOREIGN').Count 'another arch waives nothing'
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ Exemption = @("amd64:${x}:reviewed", "amd64:${dir}\gone.dll:old") }) 'EXEMPT-STALE').Count 'stale entry'
            Assert-Equal 1 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ Exemption = @("amd64:${x}:reviewed", 'no-colons') }) 'EXEMPT-STALE').Count 'malformed entry'
        }
    }

    It 'INBOX: any ORT or Windows ML in the OS''s Windows dir is fatal, whoever built it, and never exempted (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            $win = Join-Path $dir 'Windows'
            $set = @{ InboxRoot = @($win); NameRoot = @($dir); System32 = "$win\System32" }
            New-OrtTestPe -Path "$win\System32\kernel32.dll" -Text @('kernel')
            Assert-Equal '' ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) | ForEach-Object Verdict) -join ',') 'the probed servercore: an OS dir without ORT is clean'
            $sys = "$win\System32\onnxruntime.dll"
            New-OrtTestPe -Path $sys -Text @($script:ForeignSrc)
            Assert-Equal $sys ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) 'INBOX').Path -join ',') 'Windows ML''s copy, found by the name scan'
            $ex = @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set ($set + @{ Exemption = @("amd64:${sys}:reviewed") })))
            Assert-Equal 'EXEMPT-STALE,FOREIGN,INBOX' ((@($ex | Where-Object Path -eq $sys).Verdict | Sort-Object) -join ',') 'an in-box exemption waives nothing and is itself refused'
            Assert-Match 'never exempted' ((@($ex | Where-Object Verdict -eq 'EXEMPT-STALE').Detail) -join ';') 'and says why'
            $said = (@(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) 'INBOX').Detail) -join ';'
            $anchor = 'docs/onnxruntime-single-source.md#the-in-box-onnx-runtime-windows-ml'
            Assert-True ($said.Contains('keep the previous WINDOWS_BASE_DIGEST') -and $said.Contains($anchor)) "the remedy is the digest pin, and the doc (got: $said)"
            Assert-Match '(?m)^## The in-box ONNX Runtime \(Windows ML\)\r?$' ([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'docs\onnxruntime-single-source.md'))) 'the anchor it names exists'
            # The doc says a chain copy beside each exe cannot clear an in-box ORT today; if this goes green, rewrite that section.
            New-OrtTestPe -Path "$dir\runtime\bin\gst-launch-1.0.exe" -Text @('host')
            Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll" -Destination "$dir\runtime\bin"
            $staged = @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) | ForEach-Object Verdict | Sort-Object -Unique) -join ','
            Assert-Equal 'ELSEWHERE,FOREIGN,INBOX,UNRESOLVED' $staged 'staging the chain DLL beside the exes stays red on bytes, placement and in-box'
            Remove-Item -LiteralPath "$dir\runtime\bin" -Recurse -Force
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set @{ InboxRoot = @(); ExtraFile = @($sys) }) 'INBOX').Count 'cross lane: no Windows dir is modeled'
            Remove-Item -LiteralPath $sys
            $sxs = "$win\WinSxS\amd64_ai-machinelearning\onnxruntime.dll"
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $sxs -Parent)
            Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll" -Destination $sxs
            Assert-Equal $sxs ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) 'INBOX').Path -join ',') 'chain bytes copied into the OS dir are in-box too'
            Remove-Item -LiteralPath $sxs
            $api = "$win\System32\Windows.AI.MachineLearning.dll"
            New-OrtTestPe -Path $api -Text @('OrtGetApiBase')
            Assert-Equal 0 @(Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set $set) 'INBOX').Count 'the Windows ML API DLL has no ORT name, so the name scan misses it'
            Assert-Equal $api ((Get-OrtTestFatal (Invoke-OrtTestCensus -Dir $dir -Set ($set + @{ ExtraFile = @($api) })) 'INBOX').Path -join ',') 'which is why the image census names it'
        }
    }
}

Describe 'ORT census: Test-OrtProvenanceTree (G6, consumer bundles)' {
    It 'passes a flat runner with the chain ORT beside its importers; fails a stale DLL, a System32 fall-through, no reference (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            $run = Join-Path $dir 'runner'
            New-OrtTestPe -Path "$run\app.exe" -Text @('app')
            New-OrtTestPe -Path "$run\AccelerANTgine.dll" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            New-OrtTestPe -Path "$run\oxidant.dll" -Text @('OrtGetApiBase')
            Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll", "$chain\bin\onnxruntime_providers_shared.dll" -Destination $run
            Assert-True (Test-OrtProvenanceTree -Root $run -ReferenceDir @("$chain\bin")) 'green'
            New-OrtTestPe -Path "$run\onnxruntime.dll" -Text @($script:ChainSrc, 'FileVersion 1.27.0')
            $c = Test-OrtProvenanceTree -Root $run -ReferenceDir @("$chain\bin") -PassThru
            Assert-Equal 'STALE,UNRESOLVED,UNRESOLVED' (((Get-OrtTestFatal $c).Verdict | Sort-Object) -join ',') 'the 1.27 runner DLL, and both importers landing on it'
            $bin = Join-Path $run 'bin'
            New-OrtTestPe -Path "$bin\helper.dll" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            $null = New-Item -ItemType Directory -Force -Path "$dir\solo"
            Move-Item -LiteralPath $bin -Destination "$dir\solo"
            Copy-Item -LiteralPath "$chain\bin\onnxruntime.dll" -Destination "$dir\solo"
            $c = Test-OrtProvenanceTree -Root "$dir\solo" -ReferenceDir @("$chain\bin") -PassThru
            Assert-Match 'Windows ML' ((Get-OrtTestFatal $c 'UNRESOLVED').Detail -join ';') 'no exe dir holds it, so System32 would win'
            Assert-False (Test-OrtProvenanceTree -Root "$dir\solo" -ReferenceDir @("$dir\none")) 'no reference = NONE = red'
        }
    }

    It 'models a client loader: host exe dirs for a DLL, its own dir first for a .pyd, only itself for an .exe, every host (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-OrtTestImage -Dir $dir
            $winMl = "so a client host loads System32's Windows ML copy"
            $cases = @(
                @{ N = 'plug'; Want = 'UNRESOLVED'; Detail = "not in $([regex]::Escape("$dir\plug")), $winMl"; Why = 'LoadLibrary searches app.exe''s dir, never the plugin''s'
                    L = [ordered]@{ 'app.exe' = 'host'; 'plugins\consumer.dll' = 'import'; 'plugins\onnxruntime.dll' = 'chain' } }
                @{ N = 'py'; Want = ''; Why = 'a .pyd loads with DLL_LOAD_DIR: its own dir first'
                    L = [ordered]@{ 'py\python.exe' = 'host'; 'py\Lib\site-packages\pkg\ext.cp314-win_amd64.pyd' = 'import'; 'py\Lib\site-packages\pkg\onnxruntime.dll' = 'chain' } }
                @{ N = 'fhs'; Want = ''; Why = 'bin\ + lib\: no exe above the plugin, so bin\''s exe hosts it'
                    L = [ordered]@{ 'bin\app.exe' = 'host'; 'bin\onnxruntime.dll' = 'chain'; 'lib\gstreamer-1.0\gstonnx.dll' = 'import' } }
                @{ N = 'sib'; Want = ''; Why = 'a sibling subtree''s exe does not host app\x.dll'
                    L = [ordered]@{ 'app\app.exe' = 'host'; 'app\x.dll' = 'import'; 'app\onnxruntime.dll' = 'chain'; 'tools\t.exe' = 'host' } }
                @{ N = 'sib2'; Want = 'UNRESOLVED'; Why = 'nor does a sibling subtree''s copy serve app\x.dll'
                    L = [ordered]@{ 'app\app.exe' = 'host'; 'app\x.dll' = 'import'; 'tools\t.exe' = 'host'; 'tools\onnxruntime.dll' = 'chain' } }
                @{ N = 'self'; Want = ''; Why = 'an .exe resolves from its own dir, whatever exe sits above it'
                    L = [ordered]@{ 'app.exe' = 'host'; 'tools\t.exe' = 'import'; 'tools\onnxruntime.dll' = 'chain' } }
                @{ N = 'all'; Want = 'UNRESOLVED'; Detail = "not in $([regex]::Escape("$dir\all\sub")), $winMl"; Why = 'app.exe finds the copy, sub\tool.exe would not'
                    L = [ordered]@{ 'app.exe' = 'host'; 'onnxruntime.dll' = 'chain'; 'sub\tool.exe' = 'host'; 'sub\x.dll' = 'import' } }
            )
            foreach ($k in $cases) {
                $f = @(Get-OrtTestFatal (Invoke-OrtLoaderTree -Root "$dir\$($k.N)" -Chain $chain -Layout $k.L))
                Assert-Equal $k.Want (@($f | ForEach-Object Verdict) -join ',') "$($k.N): $($k.Why)"
                if ($k['Detail']) { Assert-Match $k['Detail'] (@($f | ForEach-Object Detail) -join ';') "$($k.N): names the host dir it checked" }
            }
        }
    }
}

Describe 'ORT census: loading' {
    It 'loads alone, as G2''s per-file bind mount ships it, and the census then throws instead of scanning import-blind (mutation)' {
        Invoke-InTestDir { param($dir)
            $null = New-Item -ItemType Directory -Force -Path "$dir\ortmods"
            Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1') -Destination "$dir\ortmods"
            New-OrtTestPe -Path "$dir\c.dll" -Import @('onnxruntime.dll') -Text @('OrtGetApiBase')
            # A fresh runspace: this session already holds WindowsTargetArch.Common, which would hide the gap.
            $ps = [powershell]::Create()
            try {
                $null = $ps.AddScript({
                        param($Module, $Pe)
                        $ErrorActionPreference = 'Stop'  # as every consumer builder runs
                        $r = [ordered]@{ Load = 'ok'; Pure = ''; Census = 'no throw' }
                        try { Import-Module $Module -DisableNameChecking -ErrorAction Stop } catch { $r.Load = "threw: $($_.Exception.Message)" }
                        try { $r.Pure = Get-OrtStampPath -Consumer 'opencv' } catch { $r.Pure = "threw: $($_.Exception.Message)" }
                        try { $null = Get-OrtBinaryFact -Path $Pe } catch { $r.Census = "threw: $($_.Exception.Message)" }
                        [pscustomobject]$r
                    }).AddArgument("$dir\ortmods\WindowsOrtProvenance.Common.psm1").AddArgument("$dir\c.dll")
                $r = @($ps.Invoke())[0]
            } finally { $ps.Dispose() }
            Assert-Equal 'ok' $r.Load 'no WindowsTargetArch.Common beside it is not a load error'
            Assert-Equal 'C:\runtime\share\ort-provenance\opencv.json' $r.Pure 'the helpers G2 needs work'
            Assert-Match 'Get-PeImportNames is unavailable' $r.Census 'a consumer PE cannot be read without its imports'
        }
    }
}
Describe 'ORT census: wiring' {
    $path = Join-Path (Get-RepoRoot) $script:SmokeScript
    $text = [System.IO.File]::ReadAllText($path)

    It 'section 25 runs the image census between Hailo and the summary, on every lane (mutation)' {
        $s25 = $text.IndexOf("Write-TestHeader '25. ONNX Runtime single source'")
        $s24 = $text.IndexOf("Write-TestHeader '24.")
        $sum = $text.IndexOf("Write-TestHeader '== SUMMARY =='")
        Assert-True ($s24 -ge 0 -and $s24 -lt $s25 -and $s25 -lt $sum) 'section 25 sits after 24, before the summary'
        $body = $text.Substring($s25, $sum - $s25)
        Assert-Match 'Invoke-OrtImageCensus -Arch \(Get-WindowsTargetArch\) -CrossTarget:\$smokeCross' $body 'the image census, cross-aware'
        Assert-Match '-RequireStamp:\$ortStampArmed' $body 'STAMP follows the arming'
        Assert-Match "Get-Command -Name 'Assert-ChainOrtOnly'" $body 'armed by G2''s presence'
        Assert-Equal 4 ([regex]::Matches($body, "@\{ G = '(run|bytes|placement|consumers)'; Name = ").Count) 'four always-on assertions'
        Assert-Match "\+ @\('run'\) \| Select-Object -First 1" $body 'an unknown verdict falls into an asserted group'
        Assert-False ($body -match '(?m)^if \(\$smokeCross\)') 'not skipped on the cross lane'
    }

    It 'the floor row carries section 25 on all three lanes (mutation)' {
        $row = [regex]::Match($text, "'25' = @\{ Gpu = (\d+); Cpu = (\d+); Arm64 = (\d+) \}")
        Assert-True $row.Success 'row present'
        foreach ($i in 1..3) { Assert-True ([int]$row.Groups[$i].Value -ge 4) "column $i floors the four assertions" }
        foreach ($i in 1..2) { Assert-True ([int]$row.Groups[$i].Value -ge 5) "amd64 column $i floors the in-box assertion too" }
    }

    It 'section 25 asserts no in-box ORT on amd64, skips it only on cross, and the image census models the Windows dir (mutation)' {
        $s25 = $text.IndexOf("Write-TestHeader '25. ONNX Runtime single source'")
        $body = $text.Substring($s25, $text.IndexOf("Write-TestHeader '== SUMMARY =='") - $s25)
        Assert-Match "inbox = @\('INBOX'\)" $body 'INBOX has its own group'
        Assert-Match "(?s)\`$ortLines = @\(\`$ortFail\['inbox'\]\)\s+if \(-not \`$smokeCross\) \{\s+Assert-Test -Name 'ORT in-box: " $body 'asserted on every amd64 lane'
        Assert-Match "(?s)Assert-Test -Name 'ORT in-box: .+?\} else \{\s+Skip-Test 'ORT in-box \(cross lane" $body 'skipped, never passed, on cross'
        $list = [regex]::Match($body, '(?m)^\$ortCensusExemption = @\((.*?)\)\s*#')
        Assert-True $list.Success 'the exemption list is where section 25 keeps it'
        Assert-False ($list.Groups[1].Value -match '(?i)\\Windows\\|System32|SysWOW64') 'no exemption names the OS''s Windows dir'
        $mod = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1'))
        foreach ($lit in @('InboxRoot = @(if (-not $CrossTarget) { $winDir })', '"$winDir\$d\onnxruntime.dll"; "$winDir\$d\Windows.AI.MachineLearning.dll"',
                "foreach (`$d in 'System32', 'SysWOW64')", '-ExtraFile $inboxFile')) {
            Assert-True $mod.Contains($lit) "Invoke-OrtImageCensus carries: $lit"
        }
    }

    It 'the declared chain root is Build-OnnxFromSource.ps1''s SourceDir, and the image census scans the whole drive by name' {
        $onnx = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1'))
        $src = [regex]::Match($onnx, '\[string\]\$SourceDir\s*=\s*''([^'']+)''').Groups[1].Value
        Assert-Equal $src ((Get-OrtChainSourceRoot) -join ',') 'fingerprint root = build dir'
        $mod = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1'))
        Assert-Match "-ContentRoot @\('C:\\runtime', 'C:\\temp\\cpython', 'C:\\opt', 'C:\\Users'\) -NameRoot @\(\`$drive\)" $mod 'content roots + a whole-drive name scan'
        Assert-Match "System32 = \`$\(if \(\`$CrossTarget\) \{ '' \} else \{ Join-Path \`$winDir 'System32' \}\)" $mod 'System32 modeled on amd64'
        Assert-Match "-ExcludeRoot @\(if \(\`$CrossTarget\) \{ \`$winDir \}\)" $mod 'the Windows dir skipped only on the cross lane'
    }
}

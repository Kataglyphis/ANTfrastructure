#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# G2 (Assert-ChainOrtOnly) over fixture trees, its stamp as G1 reads it, and its wiring into the five consumer builds.
# NOT covered: a real consumer build, record formats beyond the shapes written here, what loads at run time.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Build.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1') -Force -DisableNameChecking

$script:GateConsumerScript = [ordered]@{
    opencv = 'Build-OpencvFromSource.ps1'; genai = 'Build-OnnxGenaiFromSource.ps1'; ffmpeg = 'Build-FfmpegFromSource.ps1'
    gstreamer = 'Build-GstreamerFromSource.ps1'; 'amdgpu-ep' = 'Build-OrtAmdgpuEpFromSource.ps1'
}
$script:GateMount = 'source=windows/scripts/modules/WindowsOrtProvenance.Build.psm1,target=C:\bkmnt\ortmods\WindowsOrtProvenance.Build.psm1'

function Set-OrtGateText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    [System.IO.File]::WriteAllText($Path, $Text)
}

# A chain install (flat headers, lib\, bin\), its wheel, and an OpenCV-shaped tree built through a nested header shim.
function New-OrtGateFixture {
    param([Parameter(Mandatory)][string]$Dir)
    $chain = Join-Path $Dir 'runtime\lib\onnxruntime-source'
    foreach ($f in @{ 'include\onnxruntime\onnxruntime_c_api.h' = 'chain c api'; 'include\onnxruntime\dml_provider_factory.h' = 'chain dml'
            'lib\onnxruntime.lib' = 'chain implib'; 'bin\onnxruntime.dll' = 'chain dll'; 'bin\onnxruntime_providers_shared.dll' = 'chain shared'
            'lib\pkgconfig\libonnxruntime.pc' = 'Libs: -lonnxruntime' }.GetEnumerator()) { Set-OrtGateText -Path (Join-Path $chain $f.Key) -Text $f.Value }
    $wheels = Join-Path $Dir 'runtime\wheels'
    Set-OrtGateText -Path (Join-Path $Dir 'pyd.bin') -Text 'chain pyd'
    $null = New-Item -ItemType Directory -Force -Path $wheels
    $zip = [System.IO.Compression.ZipFile]::Open((Join-Path $wheels 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl'), 'Create')
    try {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$chain\bin\onnxruntime.dll", 'onnxruntime/capi/onnxruntime.dll')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $Dir 'pyd.bin'), 'onnxruntime/capi/onnxruntime_pybind11_state.pyd')
    } finally { $zip.Dispose() }
    $tree = Join-Path $Dir 'temp\opencv-src'
    $shim = Join-Path $tree 'ort-nested'
    Set-OrtGateText -Path (Join-Path $tree 'opencv\modules\dnn\src\net.cpp') -Text 'int main() {}'
    Copy-Item -LiteralPath "$chain\include\onnxruntime\onnxruntime_c_api.h" -Destination (New-Item -ItemType Directory -Force -Path "$shim\include\onnxruntime\core\session").FullName
    $fwd = $chain.Replace('\', '/')
    Set-OrtGateText -Path (Join-Path $tree 'build\CMakeCache.txt') -Text "ONNXRT_ROOT_DIR:PATH=$($shim.Replace('\', '/'))`nCMAKE_LIBRARY_PATH:PATH=$fwd/lib`n"
    Set-OrtGateText -Path (Join-Path $tree 'build\build.ninja') -Text "build modules/dnn/opencv_dnn.dll: CXX_LINKER`n  LINK_LIBRARIES = $($fwd.Replace(':', '$:'))/lib/onnxruntime.lib`n"
    Set-OrtGateText -Path (Join-Path $tree 'configure.log') -Text "-- DNN: ONNX Runtime enabled`n"
    return [pscustomobject]@{ Chain = $chain; Wheels = $wheels; Tree = $tree; Shim = $shim; Stamp = (Join-Path $Dir 'runtime\share\ort-provenance') }
}

# Assert-ChainOrtOnly over the fixture with -Set overriding any argument ($null drops it); returns the verdict and the stamp it left.
function Invoke-OrtGateCase {
    param([Parameter(Mandatory)][object]$Fx, [hashtable]$Set = @{})
    $p = @{
        Consumer = 'opencv'; TreeRoot = @($Fx.Tree); Shim = @($Fx.Shim); OrtRoot = $Fx.Chain; WheelDir = $Fx.Wheels; OrtVersion = 'v1.30.0'
        Record = @((Join-Path $Fx.Tree 'build\CMakeCache.txt'), (Join-Path $Fx.Tree 'build\build.ninja')); Log = @(Join-Path $Fx.Tree 'configure.log')
        CacheRoot = @(); StampDir = $Fx.Stamp
    }
    foreach ($k in $Set.Keys) { if ($null -eq $Set[$k]) { $p.Remove($k) } else { $p[$k] = $Set[$k] } }
    $err = ''
    try { Assert-ChainOrtOnly @p 6>$null } catch { $err = $_.Exception.Message }
    $stamp = Join-Path $Fx.Stamp "$($p.Consumer).json"
    return [pscustomobject]@{ Failed = [bool]$err; Message = $err; Stamp = $(if (Test-Path -LiteralPath $stamp) { Get-Content -LiteralPath $stamp -Raw }) }
}

# A zip at -Path holding one member, the shape of a wheel pip keeps as a hash-named HTTP body.
function New-OrtGateZip {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Member)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try { $w = [System.IO.StreamWriter]::new($zip.CreateEntry($Member).Open()); try { $w.Write('x') } finally { $w.Dispose() } } finally { $zip.Dispose() }
}

# The calls to -Name in a script's text, by AST: a comment or a string naming it is no call.
function Get-OrtGateCommandAst {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
}

# The argument text one call passes after -Parameter; $null when it passes none.
function Get-OrtGateCallArg {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Call, [Parameter(Mandatory)][string]$Parameter)
    $i = [array]::IndexOf(@($Call.CommandElements | ForEach-Object { "$_" }), $Parameter)
    if ($i -lt 0) { return $null }
    return "$($Call.CommandElements[$i + 1])"
}

# A junction at -Path to -Target, removed as a link (never recursed into) by the caller's finally.
function New-OrtGateJunction {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path)
    return (New-Item -ItemType Junction -Path $Path -Target $Target).FullName
}

Describe 'ORT gate (G2): a clean consumer build' {
    It 'passes the chain through its shim and stamps the chain core sha, which G1 accepts (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $r = Invoke-OrtGateCase -Fx $fx
            Assert-False $r.Failed "clean tree: $($r.Message)"
            $core = (Get-FileHash -LiteralPath "$($fx.Chain)\bin\onnxruntime.dll" -Algorithm SHA256).Hash.ToLowerInvariant()
            $json = $r.Stamp | ConvertFrom-Json -AsHashtable
            Assert-Equal 'opencv' $json['consumer']
            Assert-Equal $core $json['coreLibSha256'] 'the stamp names the chain core lib'
            Assert-True ([int]$json['ortFilesCompared'] -ge 1) 'the shim header was compared, not skipped'
            Assert-True (Test-OrtStampCurrent -Text $r.Stamp -Consumer 'opencv' -CoreSha256 @($core)) 'G1 reads the stamp as current'
            Assert-False (Test-OrtStampCurrent -Text $r.Stamp -Consumer 'opencv' -CoreSha256 @('0' * 64)) 'G1 refuses it for another chain'
        }
    }

    It 'a chain-identical copy in the FFmpeg compat\onnx shape and a chain wheel copy in a cache pass (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $compat = New-Item -ItemType Directory -Force -Path (Join-Path $fx.Tree 'ffmpeg\compat\onnx')
            Copy-Item -LiteralPath "$($fx.Chain)\include\onnxruntime\onnxruntime_c_api.h", "$($fx.Chain)\include\onnxruntime\dml_provider_factory.h" -Destination $compat.FullName
            $uv = Join-Path $dir 'cache\uv\archive-v0\abc\onnxruntime\capi'
            Set-OrtGateText -Path (Join-Path $uv 'onnxruntime_pybind11_state.pyd') -Text 'chain pyd'
            Copy-Item -LiteralPath (Join-Path $fx.Wheels 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl') -Destination (Join-Path $dir 'cache\uv')
            $r = Invoke-OrtGateCase -Fx $fx -Set @{ CacheRoot = @(Join-Path $dir 'cache\uv') }
            Assert-False $r.Failed "chain bytes everywhere: $($r.Message)"
        }
    }
}

Describe 'ORT gate (G2): foreign ORT in the build inputs' {
    $red = {
        param([object]$Fx, [string]$Want, [hashtable]$Set = @{})
        $r = Invoke-OrtGateCase -Fx $Fx -Set $Set
        Assert-True $r.Failed "expected a finding matching /$Want/"
        Assert-Match $Want $r.Message
        Assert-Null $r.Stamp 'no stamp on a fail'
    }

    It 'another onnxruntime_c_api.h under build\3rdparty\onnxruntime (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\3rdparty\onnxruntime\include\onnxruntime_c_api.h') -Text 'ort 1.25.1 c api'
            & $red $fx 'onnxruntime_c_api\.h is not the chain''s onnxruntime_c_api\.h'
        }
    }

    It 'an ORT binary the chain does not build, and foreign bytes under a hidden dir (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\bin\onnxruntime_providers_openvino.dll') -Text 'x'
            & $red $fx 'onnxruntime_providers_openvino\.dll is an ONNX Runtime binary the chain does not build'
            Remove-Item -LiteralPath (Join-Path $fx.Tree 'build\bin\onnxruntime_providers_openvino.dll')
            $hidden = New-Item -ItemType Directory -Force -Path (Join-Path $fx.Tree '.cache')
            $hidden.Attributes = $hidden.Attributes -bor [System.IO.FileAttributes]::Hidden
            Set-OrtGateText -Path (Join-Path $hidden.FullName 'onnxruntime.dll') -Text 'pypi dll'
            & $red $fx 'onnxruntime\.dll is not the chain''s'
        }
    }

    It 'an ORT archive (.nupkg, .tar.lzma2, a foreign wheel) in _deps or a user cache; GenAI''s own wheel is not ORT (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\_deps\microsoft.ml.onnxruntime.directml.1.24.4.nupkg') -Text 'nupkg'
            & $red $fx 'an ONNX Runtime archive: .*directml\.1\.24\.4\.nupkg'
            Remove-Item -LiteralPath (Join-Path $fx.Tree 'build\_deps') -Recurse
            Set-OrtGateText -Path (Join-Path $fx.Tree 'dist\onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl') -Text 'genai wheel'
            Assert-False (Invoke-OrtGateCase -Fx $fx).Failed 'the GenAI wheel is not an ORT archive'
            Set-OrtGateText -Path (Join-Path $dir 'cache\pyke\ort.pyke.io\dfbin\x86_64-pc-windows-msvc\ab12.tar.lzma2') -Text 'pyke'
            & $red $fx 'an ONNX Runtime archive: .*ab12\.tar\.lzma2' @{ CacheRoot = @(Join-Path $dir 'cache\pyke') }
            Set-OrtGateText -Path (Join-Path $dir 'cache\pip\onnxruntime-1.27.0-cp314-cp314-win_amd64.whl') -Text 'pypi wheel'
            & $red $fx 'an ONNX Runtime archive: .*onnxruntime-1\.27\.0' @{ CacheRoot = @(Join-Path $dir 'cache\pip') }
        }
    }

    It 'a FetchContent ORT dir, a NuGet ORT package dir, and anything in pyke''s cache (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $fx.Tree 'build\_deps\ortlib-src')
            & $red $fx 'fetched ONNX Runtime content at .*ortlib-src'
            Remove-Item -LiteralPath (Join-Path $fx.Tree 'build\_deps') -Recurse
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'nuget\microsoft.ml.onnxruntime.directml\1.24.4')
            & $red $fx 'fetched ONNX Runtime content at .*microsoft\.ml\.onnxruntime\.directml' @{ CacheRoot = @(Join-Path $dir 'nuget') }
            Set-OrtGateText -Path (Join-Path $dir 'local\ort.pyke.io\dfbin\x\libonnxruntime.a') -Text 'pyke static'
            & $red $fx 'pyke''s ORT download cache holds' @{ CacheRoot = @(Join-Path $dir 'local\ort.pyke.io') }
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'nuget2\microsoft.ml.onnxruntimegenai.directml\0.9.0')
            Assert-False (Invoke-OrtGateCase -Fx $fx -Set @{ CacheRoot = @(Join-Path $dir 'nuget2') }).Failed 'the GenAI NuGet package is not ORT'
        }
    }

    It 'a record naming ORT outside the chain, spaces and all: CMakeCache, build.ninja (`$ `), meson intro-dependencies (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $cache = Join-Path $fx.Tree 'build\CMakeCache.txt'
            $foreign = (Join-Path $dir 'Program Files\onnxruntime-win-x64-1.25.1').Replace('\', '/')
            $want = "$([regex]::Escape($foreign))/lib/onnxruntime\.lib is not the chain's onnxruntime\.lib"
            Set-OrtGateText -Path "$foreign/lib/onnxruntime.lib" -Text 'foreign implib'
            Add-Content -LiteralPath $cache "ORT_LIB:FILEPATH=$foreign/lib/onnxruntime.lib"
            & $red $fx "CMakeCache\.txt: $want"
            Set-OrtGateText -Path $cache -Text "ONNXRT_ROOT_DIR:PATH=$($fx.Shim.Replace('\', '/'))`nORT_INCLUDE:PATH=D:/My Tools/onnxruntime/include`n"
            & $red $fx 'names an ONNX Runtime path outside the chain: D:/My Tools/onnxruntime/include'
            $deep = (Join-Path $dir 'ext\inc').Replace('\', '/')
            Set-OrtGateText -Path "$deep/onnxruntime/core/session/onnxruntime_c_api.h" -Text 'older install layout'
            Set-OrtGateText -Path $cache -Text "ONNXRT_ROOT_DIR:PATH=$($fx.Shim.Replace('\', '/'))`nEXTRA_INC:PATH=$deep`n"
            & $red $fx "CMakeCache\.txt searches $([regex]::Escape($deep))/onnxruntime/core/session: "
            Set-OrtGateText -Path $cache -Text "ONNXRT_ROOT_DIR:PATH=$($fx.Shim.Replace('\', '/'))`n"
            $ninja = Join-Path $fx.Tree 'build\build.ninja'
            $plain = (Join-Path $dir 'deps\plain lib').Replace('\', '/')
            Set-OrtGateText -Path "$plain/onnxruntime.lib" -Text 'foreign implib'
            Add-Content -LiteralPath $ninja "  LINK_PATH = -LIBPATH:$($plain.Replace(':', '$:').Replace(' ', '$ '))"
            & $red $fx "build\.ninja searches $([regex]::Escape($plain)): .*onnxruntime\.lib is not the chain's"
            Set-OrtGateText -Path $ninja -Text "build x.dll: LINK`n  LINK_LIBRARIES = $($fx.Chain.Replace('\', '/').Replace(':', '$:'))/lib/onnxruntime.lib`n"
            $intro = Join-Path $fx.Tree 'build\meson-info\intro-dependencies.json'
            # Backslashes, which JSON escapes: only a JSON reader spells the path back.
            Set-OrtGateText -Path $intro -Text (@(@{ name = 'libonnxruntime'; version = '1.25.1'; link_args = @("$($foreign.Replace('/', '\'))\lib\onnxruntime.lib") }) | ConvertTo-Json -Depth 4)
            & $red $fx "intro-dependencies\.json: $want" @{ Record = @($cache, $ninja, $intro) }
        }
    }

    It 'a configure or build log that downloaded ORT; GenAI''s own package is not ORT (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $log = Join-Path $fx.Tree 'configure.log'
            Add-Content -LiteralPath $log '-- DNN: Downloading ONNX Runtime from https://github.com/microsoft/onnxruntime/releases/download/v1.25.1/onnxruntime-win-x64-1.25.1.zip'
            & $red $fx 'configure\.log:2 fetches an ONNX Runtime'
            Set-OrtGateText -Path $log -Text "-- Using ONNX Runtime package Microsoft.ML.OnnxRuntime.DirectML version 1.24.4`n"
            & $red $fx 'configure\.log:1 fetches'
            Set-OrtGateText -Path $log -Text "Collecting onnxruntime==1.27.0`n"
            & $red $fx 'configure\.log:1 fetches'
            Set-OrtGateText -Path $log -Text "-- Downloading onnxruntime-genai extensions headers`nCollecting onnxruntime_genai==0.15.2`n-- Using ONNX Runtime from: C:/x [absolute]`n"
            Assert-False (Invoke-OrtGateCase -Fx $fx).Failed 'GenAI and extensions downloads, and a plain mention, are not ORT fetches'
        }
    }

    It 'fails closed: no chain reference, a missing record or log, an empty tree, a chain without its anchors (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\CMakeCache.txt') -Text "WITH_ONNXRUNTIME:BOOL=OFF`n"
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\build.ninja') -Text "build x.dll: LINK`n"
            & $red $fx 'no build record names the chain ONNX Runtime'
            $fx = New-OrtGateFixture -Dir (Join-Path $dir 'b')
            & $red $fx 'the build record .*nope\.ninja is missing' @{ Record = @((Join-Path $fx.Tree 'build\CMakeCache.txt'), (Join-Path $fx.Tree 'nope.ninja')) }
            & $red $fx 'the build log .*nope\.log is missing' @{ Log = @(Join-Path $fx.Tree 'nope.log') }
            & $red $fx 'no build log was given, so no configure or build step was checked' @{ Log = @() }
            & $red $fx 'no tree at' @{ TreeRoot = @(Join-Path $dir 'absent'); Shim = @() }
            $empty = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'empty')
            & $red $fx 'hold no files' @{ TreeRoot = @($empty.FullName); Shim = @() }
            Remove-Item -LiteralPath "$($fx.Chain)\bin\onnxruntime.dll"
            & $red $fx 'has no bin\\onnxruntime\.dll, the core lib a stamp names'
        }
    }

    It 'folds the consumer''s own gate in, and leaves no stale stamp behind a fail (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            Assert-False (Invoke-OrtGateCase -Fx $fx).Failed 'first a pass'
            Assert-True (Test-Path -LiteralPath (Join-Path $fx.Stamp 'opencv.json')) 'stamped'
            & $red $fx 'consumer gate: ortlib\.cmake took ORT_HOME' @{ Finding = @('ortlib.cmake took ORT_HOME x') }
            Assert-False (Test-Path -LiteralPath (Join-Path $fx.Stamp 'opencv.json')) 'the earlier stamp is gone'
        }
    }

    It 'the OS dir is not a build input it grades' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $win = [Environment]::GetFolderPath('Windows').Replace('\', '/')
            Add-Content -LiteralPath (Join-Path $fx.Tree 'build\CMakeCache.txt') "SYSDIR:PATH=$win/System32"
            Assert-False (Invoke-OrtGateCase -Fx $fx).Failed 'System32 (Windows ML''s ORT on a client) is G1''s, not a consumer input'
        }
    }

    It 'a quoted include path is read whole, and an MSYS path after -libpath: is read at all (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $inc = (Join-Path $dir 'My Deps\inc').Replace('\', '/')
            Set-OrtGateText -Path "$inc/onnxruntime_c_api.h" -Text 'foreign c api'
            Add-Content -LiteralPath (Join-Path $fx.Tree 'build\build.ninja') "  FLAGS = -I`"$inc`" /DX"
            & $red $fx "build\.ninja searches $([regex]::Escape($inc)):"
            $msys = Join-Path $dir 'msys\lib'
            Set-OrtGateText -Path "$msys\onnxruntime.lib" -Text 'foreign implib'
            $mak = Join-Path $fx.Tree 'ffbuild\config.mak'
            Set-OrtGateText -Path $mak -Text "LDFLAGS= -libpath:/$($msys.Substring(0, 1).ToLower())$($msys.Substring(2).Replace('\', '/'))`n"
            & $red $fx 'config\.mak searches .*msys/lib: .*onnxruntime\.lib is not the chain''s' @{ Record = @((Join-Path $fx.Tree 'build\CMakeCache.txt'), $mak) }
        }
    }

    It 'a dir link (junction) in the tree is walked and read through when it leaves the tree and the chain (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $cache = Join-Path $fx.Tree 'build\CMakeCache.txt'
            $foreign = Join-Path $dir 'deps\ort-1.25.1'
            Set-OrtGateText -Path "$foreign\lib\onnxruntime.lib" -Text 'foreign implib'
            Set-OrtGateText -Path "$foreign\include\onnxruntime_c_api.h" -Text 'foreign c api'
            $links = @()
            try {
                $links += ($j = New-OrtGateJunction -Path "$($fx.Tree)\build\3rdparty\ort" -Target $foreign)
                & $red $fx 'onnxruntime\.lib is not the chain''s onnxruntime\.lib \(foreign ONNX Runtime bytes\) \(through the link .*3rdparty\\ort\)'
                $f = [regex]::Escape($foreign.Replace('\', '/'))
                Add-Content -LiteralPath $cache "ORT_INC:PATH=$($j.Replace('\', '/'))/include`nORT_LIB:FILEPATH=$($j.Replace('\', '/'))/lib/onnxruntime.lib"
                $r = Invoke-OrtGateCase -Fx $fx
                Assert-Match "CMakeCache\.txt: $f/lib/onnxruntime\.lib is not the chain's" $r.Message 'a record path through the link is read at its target'
                Assert-Match "CMakeCache\.txt searches $f/include: " $r.Message 'an include dir through the link is searched'
                [System.IO.Directory]::Delete($j)
                $links += ($h = New-OrtGateJunction -Path "$($fx.Tree)\ort-home" -Target $fx.Chain)
                $links += New-OrtGateJunction -Path "$($fx.Tree)\alias" -Target "$($fx.Tree)\opencv"
                $hf = $h.Replace('\', '/')
                Set-OrtGateText -Path $cache -Text "ORT_HOME:PATH=$hf`n"
                Set-OrtGateText -Path (Join-Path $fx.Tree 'build\build.ninja') -Text "build x.dll: LINK`n  LINK_LIBRARIES = $($hf.Replace(':', '$:'))/lib/onnxruntime.lib`n"
                $r = Invoke-OrtGateCase -Fx $fx -Set @{ Shim = @() }
                Assert-False $r.Failed "links into the chain and into the tree pass: $($r.Message)"
                Assert-Equal '2' (($r.Stamp | ConvertFrom-Json -AsHashtable)['chainReferences']) 'a record naming the chain through an in-tree link counts'
                $links += New-OrtGateJunction -Path "$($fx.Tree)\up" -Target $dir
                & $red $fx 'the link .*\\up points at .*, which holds the tree itself'
            } finally { foreach ($l in $links) { if (Test-Path -LiteralPath $l) { [System.IO.Directory]::Delete($l) } } }
        }
    }

    It 'a static ORT built inside the tree (onnxruntime_session.lib and kin) fails, found and named; GenAI''s and extensions'' libs do not (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $ortb = Join-Path $fx.Tree 'third_party\ort\build\Release'
            foreach ($l in 'onnxruntime_session.lib', 'onnxruntime_providers.lib', 'libonnxruntime_mlas.a') { Set-OrtGateText -Path "$ortb\$l" -Text "static $l" }
            Add-Content -LiteralPath (Join-Path $fx.Tree 'build\build.ninja') "  LINK_LIBRARIES = $($ortb.Replace('\', '/').Replace(':', '$:'))/onnxruntime_session.lib"
            $r = Invoke-OrtGateCase -Fx $fx
            Assert-True $r.Failed 'a static ORT in the tree'
            foreach ($l in 'onnxruntime_session\.lib', 'onnxruntime_providers\.lib', 'libonnxruntime_mlas\.a') { Assert-Match "Release\\$l is an ONNX Runtime binary the chain does not build" $r.Message }
            Assert-Match 'build\.ninja: .*Release/onnxruntime_session\.lib is an ONNX Runtime binary' $r.Message 'an in-tree record path with an ORT name is graded'
            Remove-Item -LiteralPath (Join-Path $fx.Tree 'third_party') -Recurse
            Set-OrtGateText -Path (Join-Path $fx.Tree 'build\build.ninja') -Text "build x.dll: LINK`n  LINK_LIBRARIES = $($fx.Chain.Replace('\', '/').Replace(':', '$:'))/lib/onnxruntime.lib`n"
            foreach ($l in 'onnxruntime_extensions.lib', 'onnxruntime_extensions.dll', 'onnxruntime_genai.lib', 'onnxruntime-genai.dll') { Set-OrtGateText -Path "$($fx.Tree)\build\bin\$l" -Text 'not ort' }
            $r = Invoke-OrtGateCase -Fx $fx
            Assert-False $r.Failed "GenAI's and extensions' own libs are not ORT: $($r.Message)"
        }
    }

    It 'with no -CacheRoot, the profile''s NuGet, pyke, uv and pip caches (HTTP bodies too) are read, each tool''s override honoured (mutation)' {
        Invoke-InTestDir { param($dir)
            $fx = New-OrtGateFixture -Dir $dir
            $user = Join-Path $dir 'profile'
            $local = Join-Path $user 'AppData\Local'
            $dflt = @{ CacheRoot = $null }
            $vars = @{ LOCALAPPDATA = $local; USERPROFILE = $user; NUGET_PACKAGES = $null; UV_CACHE_DIR = $null; PIP_CACHE_DIR = $null }
            Invoke-WithEnv -Vars $vars {
                Assert-Equal "$user\.nuget\packages|$local\ort.pyke.io|$local\pip\cache|$local\uv\cache" ((Get-OrtGateDefaultCache) -join '|')
                Assert-False (Invoke-OrtGateCase -Fx $fx -Set $dflt).Failed 'nothing cached yet'
                $plant = @(
                    @{ Root = "$user\.nuget"; File = 'packages\microsoft.ml.onnxruntime\1.24.4\microsoft.ml.onnxruntime.1.24.4.nupkg'; Want = 'fetched ONNX Runtime content at .*microsoft\.ml\.onnxruntime' }
                    @{ Root = "$local\ort.pyke.io"; File = 'dfbin\x86_64-pc-windows-msvc\ab12\onnxruntime.dll'; Want = 'pyke''s ORT download cache holds' }
                    @{ Root = "$local\uv"; File = 'cache\archive-v0\h1\onnxruntime\capi\onnxruntime_pybind11_state.pyd'; Want = 'onnxruntime_pybind11_state\.pyd is not the chain''s' })
                foreach ($p in $plant) {
                    Set-OrtGateText -Path (Join-Path $p.Root $p.File) -Text 'foreign'
                    & $red $fx $p.Want $dflt
                    Remove-Item -LiteralPath $p.Root -Recurse
                }
                $body = "$local\pip\cache\http-v2\a\b\c\d\e\0123abcd.body"
                New-OrtGateZip -Path $body -Member 'onnxruntime/capi/__init__.py'
                & $red $fx 'pip''s HTTP cache holds an ONNX Runtime wheel: .*0123abcd\.body' $dflt
                Remove-Item -LiteralPath $body
                New-OrtGateZip -Path $body -Member 'onnxruntime_genai/__init__.py'
                Set-OrtGateText -Path "$local\pip\cache\http-v2\a\b\c\d\e\0123abcd" -Text 'cache-control metadata'
                Assert-False (Invoke-OrtGateCase -Fx $fx -Set $dflt).Failed 'a GenAI wheel body and a metadata file are not ORT'
            }
            $vars = @{ LOCALAPPDATA = $local; USERPROFILE = $user; NUGET_PACKAGES = "$dir\nug"; UV_CACHE_DIR = "$dir\uvc"; PIP_CACHE_DIR = "$dir\pipc" }
            Invoke-WithEnv -Vars $vars {
                Assert-Equal "$dir\nug|$local\ort.pyke.io|$dir\pipc|$dir\uvc" ((Get-OrtGateDefaultCache) -join '|')
                New-OrtGateZip -Path "$dir\pipc\http-v2\f\0\0\d\9\99ff.body" -Member 'onnxruntime/__init__.py'
                & $red $fx 'pip''s HTTP cache holds an ONNX Runtime wheel: .*99ff\.body' $dflt
            }
        }
    }
}

Describe 'ORT gate (G2): record path tokens' {
    It 'reads ninja-escaped, flag-prefixed, MSYS and quoted paths whole, and no URL (mutation)' {
        $text = "-IC`$:/temp/a -LIBPATH:C:\temp\b `"D:/c d`" -libpath:E:/e/lib -I/c/temp/ffmpeg/compat/onnx https://github.com/x x/y/z FOO:PATH=F:/f)`n" +
            "  LINK = G`$:/Program`$ Files/o/x.lib -libpath:/h/msys/lib -LIBPATH:C:/a/b -I`"J:/My Deps/inc`"`n"
        $got = (Get-OrtGatePathToken -Text $text | Sort-Object) -join ','
        Assert-Equal 'C:/a/b,C:/temp/a,C:/temp/b,c:/temp/ffmpeg/compat/onnx,D:/c d,E:/e/lib,F:/f,G:/Program Files/o/x.lib,h:/msys/lib,J:/My Deps/inc' $got
    }

    It 'reads each record in its own format: CMakeCache values and meson JSON strings whole, flags inside them as text (mutation)' {
        Invoke-InTestDir { param($dir)
            $cache = Join-Path $dir 'CMakeCache.txt'
            Set-OrtGateText -Path $cache -Text ("//comment C:/no/x`nORT:FILEPATH=C:/Program Files/o/x.lib`nPFX:STRING=D:/a b;E:/c`n" +
                "FLAGS:STRING=/DWIN32 -IF:/f/inc -I`"G:/g h/inc`"`nEMPTY:PATH=`n")
            Assert-Equal 'C:/Program Files/o/x.lib,D:/a b,E:/c,F:/f/inc,G:/g h/inc' ((Get-OrtGateRecordToken -Path $cache | Sort-Object) -join ',')
            $json = Join-Path $dir 'intro-dependencies.json'
            Set-OrtGateText -Path $json -Text (@(@{ name = 'x'; compile_args = @('-IC:/Program Files/o/include', '-DX'); link_args = @('/c/msys root/lib/x.lib') }) | ConvertTo-Json -Depth 4)
            Assert-Equal 'c:/msys root/lib/x.lib,C:/Program Files/o/include' ((Get-OrtGateRecordToken -Path $json | Sort-Object) -join ',')
        }
    }
}

Describe 'ORT gate (G2): the link to G1' {
    It 'writes where the census reads, for every contract consumer' {
        foreach ($e in (Get-OrtConsumerContract)) {
            Assert-Equal (Get-OrtStampPath -Consumer $e.Name) (Get-OrtGateStampPath -Consumer $e.Name) $e.Name
        }
    }

    It 'every contract consumer calls Assert-ChainOrtOnly exactly once under its own name, and nothing else does (mutation)' {
        $build = Join-Path (Get-RepoRoot) 'windows\scripts\build'
        $calls = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $build -Filter '*.ps1' -File)) {
            foreach ($c in (Get-OrtGateCommandAst -Text ([System.IO.File]::ReadAllText($f.FullName)) -Name 'Assert-ChainOrtOnly')) {
                $name = "$(Get-OrtGateCallArg -Call $c -Parameter '-Consumer')".Trim("'", '"')
                $calls["$($f.Name)|$name"] = 1 + $(if ($calls.ContainsKey("$($f.Name)|$name")) { $calls["$($f.Name)|$name"] } else { 0 })
            }
        }
        $want = @($script:GateConsumerScript.Keys | ForEach-Object { "$($script:GateConsumerScript[$_])|$_" } | Sort-Object) -join ','
        Assert-Equal $want (@($calls.Keys | Sort-Object) -join ',') 'call sites'
        Assert-Equal '1' ((@($calls.Values) | Sort-Object -Unique) -join ',') 'one call each'
        Assert-Equal (@((Get-OrtConsumerContract).Name | Sort-Object) -join ',') (@($script:GateConsumerScript.Keys | Sort-Object) -join ',') 'the census contract = the gated consumers'
    }
}

Describe 'ORT gate (G2): wiring' {
    $read = { param([string]$Rel) [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $Rel)) }

    It 'each consumer imports the module from modules\ or its per-file mount, gates before its tree is removed, unconditionally (mutation)' {
        # The first command that removes the tree (or opens the cleanup phase) must come after the gate.
        $end = @{ opencv = 'Remove-SourceBuildTree'; genai = 'Remove-SourceBuildTree'; ffmpeg = 'Remove-SourceBuildTree'
            gstreamer = 'Switch-BuildPhase'; 'amdgpu-ep' = 'Complete-CurrentBuildPhase' }
        foreach ($consumer in $script:GateConsumerScript.Keys) {
            $rel = "windows\scripts\build\$($script:GateConsumerScript[$consumer])"
            $text = & $read $rel
            Assert-Match "@\('modules', 'ortmods'\) \| ForEach-Object \{ Join-Path \`$scriptAssetRoot \`$_ 'WindowsOrtProvenance\.Build\.psm1' \}" $text "$consumer imports the gate"
            $call = @(Get-OrtGateCommandAst -Text $text -Name 'Assert-ChainOrtOnly')[0]
            $stops = @(Get-OrtGateCommandAst -Text $text -Name $end[$consumer] | Where-Object { $consumer -ne 'gstreamer' -or "$($_.CommandElements[1])" -match '10\. cleanup' })
            Assert-True ($stops.Count -gt 0) "$consumer has a '$($end[$consumer])'"
            Assert-True ($call.Extent.EndOffset -lt @($stops | Sort-Object { $_.Extent.StartOffset })[0].Extent.StartOffset) "$consumer gates before its first '$($end[$consumer])'"
            for ($p = $call.Parent; $p; $p = $p.Parent) { Assert-False ($p -is [System.Management.Automation.Language.IfStatementAst]) "$consumer gates on every lane (no if around the call)" }
        }
        Assert-Match '(?s)Get-OpencvOrtConfigureFinding -ConfigureLog.*Assert-ChainOrtOnly -Consumer ''opencv''' (& $read 'windows\scripts\build\Build-OpencvFromSource.ps1') 'after the OpenCV configure gate'
        $genai = & $read 'windows\scripts\build\Build-OnnxGenaiFromSource.ps1'
        Assert-Match "(?s)\`$genaiOrtPost = .*Assert-ChainOrtOnly -Consumer 'genai' .*-Finding \`$genaiOrtPost" $genai 'GenAI folds its post-build gate into G2'
        Assert-False ($genai -match 'if \(\$genaiOrtPost\.Count') 'one throw point for the post-build gate'
    }

    It 'each call site hands G2 exactly its records and the log its configure was teed into (mutation)' {
        # A dropped record or log stays green as long as one other names the chain, so each set is pinned here.
        $want = [ordered]@{
            opencv = @('$cfgLog', "(Join-Path `$buildDir 'CMakeCache.txt'), (Join-Path `$buildDir 'build.ninja')", '$cfgLog')
            genai = @('$genaiCfgLog', "(Join-Path `$genaiBuildDir 'CMakeCache.txt'), (Join-Path `$genaiBuildDir 'build.ninja')", '$genaiCfgLog')
            ffmpeg = @("(Join-Path `$srcDir 'ffbuild\config.log')", "(Join-Path `$srcDir 'ffbuild\config.mak')", '')
            gstreamer = @("(Join-Path `$resolvedBuildDir 'meson-logs\meson-log.txt')",
                "(Join-Path `$resolvedBuildDir 'build.ninja'), (Join-Path `$resolvedBuildDir 'meson-info\intro-dependencies.json')", '')
            'amdgpu-ep' = @('$epCfgLog', "(Join-Path `$buildDir 'CMakeCache.txt'), (Join-Path `$buildDir 'build.ninja')", '$epCfgLog')
        }
        foreach ($consumer in $want.Keys) {
            $text = & $read "windows\scripts\build\$($script:GateConsumerScript[$consumer])"
            $call = @(Get-OrtGateCommandAst -Text $text -Name 'Assert-ChainOrtOnly')[0]
            Assert-Equal $want[$consumer][0] (Get-OrtGateCallArg -Call $call -Parameter '-Log') "$consumer -Log"
            Assert-Equal $want[$consumer][1] (Get-OrtGateCallArg -Call $call -Parameter '-Record') "$consumer -Record"
            if ($want[$consumer][2]) { Assert-Match ('Tee-Object -FilePath ' + [regex]::Escape($want[$consumer][2]) + '\b') $text "$consumer tees its configure into the log G2 reads" }
        }
    }

    It 'every consumer RUN mounts the module per file, nothing else mounts it, and no stage COPYs it (mutation)' {
        $consumers = 0
        foreach ($df in 'windows\Dockerfile.media-builder', 'windows\Dockerfile.media-merge-builder', 'windows\Dockerfile.rocm-migraphx') {
            $joined = (& $read $df) -replace '`\r?\n', ' '
            foreach ($line in ($joined -split "`n")) {
                $isConsumer = $line -match 'source=windows/scripts/build/Build-(Opencv|OnnxGenai|Ffmpeg|Gstreamer|OrtAmdgpuEp)FromSource\.ps1'
                if ($line -match '^RUN\s') {
                    if ($isConsumer) { $consumers++ }
                    Assert-Equal $isConsumer $line.Contains($script:GateMount) "$df RUN: $($line.Substring(0, [Math]::Min(120, $line.Length)))"
                }
                Assert-False ($line -match '^COPY\s.*WindowsOrtProvenance\.Build') "$df COPYs the gate into a stage"
            }
        }
        Assert-Equal 5 $consumers 'five consumer RUNs (FFmpeg, OpenCV, GenAI, GStreamer, the rocm EP)'
    }

    It 'imports nothing, so a per-file mount loads it alone, and no shared closure pulls it in' {
        $mod = & $read 'windows\scripts\modules\WindowsOrtProvenance.Build.psm1'
        Assert-False ($mod -match '(?m)^\s*(Import-Module|using\s+module)\b') 'no import'
        foreach ($shared in 'windows\scripts\modules\WindowsSourceBuild.Common.psm1', 'windows\scripts\build\Build-MediaCoreAll.ps1', 'windows\scripts\modules\WindowsMigraphx.Common.psm1') {
            Assert-False ((& $read $shared) -match 'WindowsOrtProvenance') "$shared re-keys every RUN it is mounted into"
        }
        Invoke-InTestDir { param($dir)
            $lone = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'ortmods')
            Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Build.psm1') -Destination $lone.FullName
            $ps = [powershell]::Create()
            try {
                $null = $ps.AddScript({ param($m) $ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest; Import-Module $m; [bool](Get-Command Assert-ChainOrtOnly) }).AddArgument("$($lone.FullName)\WindowsOrtProvenance.Build.psm1")
                Assert-Equal 'True' "$(@($ps.Invoke())[0])" 'loads from a directory holding only itself'
            } finally { $ps.Dispose() }
        }
    }
}

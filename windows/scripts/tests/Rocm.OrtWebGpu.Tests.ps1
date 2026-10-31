#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

. (Join-Path $PSScriptRoot 'Import-OrtWebGpuTestModules.ps1')

# The rocm-lane WebGPU EP spike offline: plan, pins, fetch chain, Dawn patch and gates; no real build or GPU.

$script:OrtBuildScript = 'windows\scripts\build\Build-OnnxFromSource.ps1'
$script:OrtWebGpuBuildFunction = @('Get-OrtWebGpuPlan', 'Get-OrtWebGpuPin', 'Get-OrtDepsRow', 'Assert-OrtDependencyArchiveSha1', 'Get-OrtDawnDepsEntry', 'Get-OrtDawnPatchName',
    'Get-OrtDawnRequiredDep', 'Get-OrtDawnDepsProbeSource', 'Invoke-OrtDawnDepsProbe', 'ConvertTo-OrtDawnDepPin', 'Save-OrtDawnDep', 'Expand-OrtZipMember',
    'Expand-OrtWebGpuDxc', 'Expand-OrtDawnArchive', 'Invoke-DawnPrebuiltDxcPatch', 'Resolve-GnuPatchExe', 'Initialize-OrtWebGpuInput',
    'Get-OrtWebGpuCmakeArgs', 'Get-OrtWebGpuConfigureFinding', 'Install-OrtWebGpuRuntime', 'Get-OrtWebGpuWheelFinding',
    'Get-OrtDxcNoticeTitle', 'Add-OrtWebGpuWheelNotice', 'Get-OrtWebGpuWheelReport', 'Get-OrtWebGpuFeatureMarker')
# ORT v1.31.0 cmake/deps.txt, verbatim: the row Get-OrtDawnDepsEntry grades.
$script:OrtDawnRow = 'dawn;https://github.com/google/dawn/archive/refs/tags/v20260916.214021.zip;514e914f23a0787213c89eed879f74b5e275690d'
# Dawn v20260916.214021 third_party/CMakeLists.txt, the block Invoke-DawnPrebuiltDxcPatch rewrites (verbatim).
$script:DawnDxcBlock = "if (DAWN_USE_BUILT_DXC)`n    AddSubdirectoryDXC()`nendif()`n`nif (TINT_BUILD_MESA)`n"


# A zip whose entries are named exactly as given ('\' kept, as DXC's release zip names them).
function New-OrtWebGpuTestZip([string]$Path, [hashtable]$Entry) {
    Add-Type -AssemblyName System.IO.Compression
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entry.Keys) {
            $w = [System.IO.StreamWriter]::new($zip.CreateEntry($name).Open())
            try { $w.Write([string]$Entry[$name]) } finally { $w.Dispose() }
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}

# One existence check per fixture path, so each keeps its own message.
function Assert-OrtWebGpuTestPath([string]$Root, [string]$Path, [bool]$Exists, [string]$Message) {
    Assert-Equal $Exists (Test-Path (Join-Path $Root $Path)) $Message
}

# A rewrite of $Initial must leave every wanted text in $Path and change nothing when it runs again.
function Assert-OrtWebGpuIdempotentText([string]$Path, [string]$Initial, [scriptblock]$Run, [string[]]$Want, [string]$Label, [string]$Again) {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    [System.IO.File]::WriteAllText($Path, $Initial)
    & $Run
    $text = [System.IO.File]::ReadAllText($Path)
    foreach ($w in $Want) { Assert-True $text.Contains($w) "$Label$w" }
    & $Run
    Assert-Equal $text ([System.IO.File]::ReadAllText($Path)) $Again
    return $text
}

Describe 'Build-OnnxFromSource WebGPU: plan and pins (cpu/nvidia never enter the spike)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtBuildScript -FunctionName $script:OrtWebGpuBuildFunction)

    It 'only the native rocm lane with ORT_WEBGPU=1 builds the EP; 0 or empty is the plain rocm ORT' {
        $rocm = @{ HasRocm = $true; GpuType = 'rocm' }
        foreach ($c in @(
                @{ G = @{ HasRocm = $false; GpuType = '' }; X = $false; F = ''; Want = 'False,False' }
                @{ G = @{ HasRocm = $false; GpuType = 'cuda' }; X = $false; F = '0'; Want = 'False,False' }
                @{ G = $rocm; X = $false; F = ''; Want = 'True,False' }
                @{ G = $rocm; X = $false; F = '0'; Want = 'True,False' }
                @{ G = $rocm; X = $false; F = '1'; Want = 'True,True' })) {
            $p = Get-OrtWebGpuPlan -GpuEnv $c.G -Cross $c.X -SpikeFlag $c.F
            Assert-Equal $c.Want "$($p.OnLane),$($p.WebGpu)" "gpu '$($c.G.GpuType)' flag '$($c.F)'"
        }
    }

    It 'refuses ORT_WEBGPU=1 off the rocm lane (cpu, nvidia, cross) and any value but 0/1' {
        Assert-Throws { Get-OrtWebGpuPlan -GpuEnv @{ HasRocm = $false; GpuType = 'cuda' } -Cross $false -SpikeFlag '1' } 'nvidia' -MessagePattern "GPU_TYPE is 'cuda'"
        Assert-Throws { Get-OrtWebGpuPlan -GpuEnv @{ HasRocm = $true; GpuType = 'rocm' } -Cross $true -SpikeFlag '1' } 'cross' -MessagePattern 'cross lane'
        foreach ($bad in 'true', 'yes', ' 1') {
            Assert-Throws { Get-OrtWebGpuPlan -GpuEnv @{ HasRocm = $true; GpuType = 'rocm' } -Cross $false -SpikeFlag $bad } "flag '$bad'" -MessagePattern "must be '0' or '1'"
        }
    }

    It 'the real pins parse, and the Dawn tag is the one ORT v1.31.0''s deps.txt fetches' {
        $pin = Get-OrtWebGpuPin -Source (Get-OrtWebGpuTestPin)
        $entry = Get-OrtDawnDepsEntry -DepsLine @('#Name;Url;SHA1', $script:OrtDawnRow) -DawnVersion $pin.DAWN_VERSION
        Assert-Equal '514e914f23a0787213c89eed879f74b5e275690d' $entry.Sha1 'ORT''s SHA1'
        Assert-Equal 'dxc_2026_09_29.zip' $pin.DXC_ASSET 'DXC asset'
        Assert-Equal 'v1.31.0' (Get-OrtWebGpuTestPin)['ONNXRUNTIME_VERSION'] 'the row above is v1.31.0''s: re-capture it with ORT'
    }

    It 'every empty or malformed pin refuses by name (the ARGs are valueless off the driver)' {
        foreach ($c in @(
                @{ K = 'ORT_WEBGPU_WINDOWS_DAWN_VERSION'; V = '' }, @{ K = 'ORT_WEBGPU_WINDOWS_DAWN_VERSION'; V = '20260818.211311' }
                @{ K = 'ORT_WEBGPU_WINDOWS_DAWN_SHA256'; V = '' }, @{ K = 'ORT_WEBGPU_WINDOWS_DAWN_SHA256'; V = 'abc' }
                @{ K = 'ORT_WEBGPU_WINDOWS_DXC_VERSION'; V = 'latest' }, @{ K = 'ORT_WEBGPU_WINDOWS_DXC_ASSET'; V = 'dxc.zip' }
                @{ K = 'ORT_WEBGPU_WINDOWS_DXC_SHA256'; V = '' })) {
            $pins = Get-OrtWebGpuTestPin
            $pins[$c.K] = $c.V
            Assert-Throws { Get-OrtWebGpuPin -Source $pins } "$($c.K)='$($c.V)'" -MessagePattern ([regex]::Escape($c.K))
        }
    }

    It 'deps.txt must name exactly the pinned tag, once, with a SHA1' {
        foreach ($c in @(
                @{ L = @($script:OrtDawnRow -replace 'v20260916\.214021', 'v20261001.000000'); P = 're-derive' }
                @{ L = @($script:OrtDawnRow, $script:OrtDawnRow); P = '2 ''dawn;'' rows' }
                @{ L = @('abseil_cpp;x;y'); P = '0 ''dawn;'' rows' }
                @{ L = @($script:OrtDawnRow -replace ';[0-9a-f]{40}$', ';sha256:abcd'); P = 'not a SHA1' })) {
            Assert-Throws { Get-OrtDawnDepsEntry -DepsLine $c.L -DawnVersion 'v20260916.214021' } $c.P -MessagePattern $c.P
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: ORT''s patch list, Dawn DEPS and the dependency fetch' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtBuildScript -FunctionName $script:OrtWebGpuBuildFunction)

    It 'reads ORT''s Dawn patches in PATCH_COMMAND order, and refuses a moved block' {
        $text = "set(X`n  `${Patch_EXECUTABLE} -p1 < `${PROJECT_SOURCE_DIR}/patches/dawn/b_first.patch &&`n" +
            "  `${Patch_EXECUTABLE} -p1 < `${PROJECT_SOURCE_DIR}/patches/dawn/a_second.patch &&`n  other < `${PROJECT_SOURCE_DIR}/patches/abseil/x.patch)"
        Assert-Equal 'b_first.patch,a_second.patch' ((Get-OrtDawnPatchName -ExternalDepsText $text) -join ',') 'order kept, other deps ignored'
        Assert-Throws { Get-OrtDawnPatchName -ExternalDepsText 'no dawn patches here' } 'none' -MessagePattern 'PATCH_COMMAND moved'
    }

    It 'the DEPS probe (real Python) resolves Var()/{var} URLs exactly as Dawn''s fetcher, and the pins are checked' {
        Invoke-InTestDir { param($dir)
            $deps = Join-Path $dir 'DEPS'
            $c = 'c' * 40
            [System.IO.File]::WriteAllText($deps, "vars = {'chromium_git': 'https://chromium.googlesource.com', 'x': 'ignored'}`n" +
                "deps = {`n  'third_party/jinja2': {'url': '{chromium_git}/chromium/src/third_party/jinja2@$c', 'condition': 'dawn_standalone'},`n" +
                "  'third_party/markupsafe': Var('chromium_git') + '/m@$c',`n  'third_party/spirv-headers/src': {'url': 'http://insecure/x@$c'},`n}`n")
            $got = Invoke-OrtDawnDepsProbe -Python (Get-OrtWebGpuTestPython) -DepsFile $deps -Path @('third_party/jinja2', 'third_party/markupsafe', 'third_party/spirv-headers/src', 'third_party/nope')
            Assert-Equal "https://chromium.googlesource.com/chromium/src/third_party/jinja2@$c" $got['third_party/jinja2'] '{var} formatted'
            Assert-Equal "chromium_git/m@$c" $got['third_party/markupsafe'] 'Var() + str is the name, as in fetch_dawn_dependencies.py'
            Assert-Equal '' $got['third_party/nope'] 'an absent entry resolves to empty'
            $pins = ConvertTo-OrtDawnDepPin -Resolved $got -Path @('third_party/jinja2')
            Assert-Equal $c $pins['third_party/jinja2'].Commit 'commit'
            foreach ($p in 'third_party/markupsafe', 'third_party/spirv-headers/src', 'third_party/nope') {
                Assert-Throws { ConvertTo-OrtDawnDepPin -Resolved $got -Path @($p) } $p -MessagePattern 'not https-url@40-hex-commit'
            }
            Assert-Throws { ConvertTo-OrtDawnDepPin -Resolved $null -Path @('third_party/jinja2') } 'no report' -MessagePattern 'jinja2'
        }
    }

    It 'fetches only the four entries a D3D12, prebuilt-DXC configure reads (not DXC, abseil, Vulkan or tests)' {
        Assert-Equal 'third_party/jinja2,third_party/markupsafe,third_party/spirv-headers/src,third_party/spirv-tools/src' ((Get-OrtDawnRequiredDep) -join ',') 'the list'
    }

    It 'a dependency is fetched by commit and must check out AS that commit, or the build stops' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src'
            $git = { & git -C $src -c user.email=t@t -c user.name=t @args 2>&1 | Out-Null }
            [void](New-Item -ItemType Directory -Path $src)
            & $git init -q; & $git commit -q --allow-empty -m one
            $first = "$(& git -C $src rev-parse HEAD)".Trim()
            & $git commit -q --allow-empty -m two
            $dest = Join-Path $dir 'dawn\third_party\jinja2'
            Save-OrtDawnDep -Dir $dest -Url $src -Commit $first -DelaySeconds 0 6>$null
            Assert-Equal $first "$(& git -C $dest rev-parse HEAD)".Trim() 'checked out the pinned (non-tip) commit'
            Assert-Throws { Save-OrtDawnDep -Dir $dest -Url $src -Commit ('e' * 40) -MaxAttempts 1 -DelaySeconds 0 3>$null } 'unknown commit' -MessagePattern 'after 1 attempt'
            Assert-Throws { Save-OrtDawnDep -Dir $dest -Url $src -Commit 'abc123' } 'short commit' -MessagePattern 'Commit'
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: archives and the Dawn DXC patch' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtBuildScript -FunctionName $script:OrtWebGpuBuildFunction)

    It 'DXC: the five members come out of a backslash-named zip, dxil.dll stays in it, and a missing one refuses' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'dxc.zip'
            $members = @{ 'bin\x64\dxcompiler.dll' = 'c'; 'bin\x64\dxil.dll' = 'i'; 'lib\x64\dxcompiler.lib' = 'l'; 'bin\arm64\dxcompiler.dll' = 'arm'
                'LICENSE-LLVM.txt' = 'L'; 'LICENSE-MS.txt' = 'M'; 'LICENCE-MIT.txt' = 'T'; 'inc\dxcapi.h' = 'h' }
            New-OrtWebGpuTestZip $zip $members
            Expand-OrtWebGpuDxc -Zip $zip -Destination (Join-Path $dir 'out')
            Assert-Equal 'c' ([System.IO.File]::ReadAllText((Join-Path $dir 'out\dxcompiler.dll'))) 'the x64 dxcompiler, not arm64'
            Assert-OrtWebGpuTestPath $dir 'out\licenses\LICENSE-MS.txt' $true 'licences'
            Assert-OrtWebGpuTestPath $dir 'out\dxcapi.h' $false 'nothing unasked'
            Assert-OrtWebGpuTestPath $dir 'out\dxil.dll' $false 'no dxil.dll: nothing loads it since ORT v1.31.0'
            $members.Remove('lib\x64\dxcompiler.lib')
            New-OrtWebGpuTestZip $zip $members
            Assert-Throws { Expand-OrtWebGpuDxc -Zip $zip -Destination (Join-Path $dir 'out2') } 'no import lib' -MessagePattern 'lacks lib/x64/dxcompiler\.lib'
        }
    }

    It 'Dawn: the top directory and test/ are dropped, a tree without CMakeLists.txt or a zip-slip member refuses' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'dawn.zip'
            New-OrtWebGpuTestZip $zip @{ 'dawn-x/CMakeLists.txt' = 'c'; 'dawn-x/src/a.cc' = 'a'; 'dawn-x/test/t.cc' = 't'; 'dawn-x/third_party/test/k' = 'k' }
            Expand-OrtDawnArchive -Zip $zip -Destination (Join-Path $dir 'd')
            Assert-OrtWebGpuTestPath $dir 'd\src\a.cc' $true 'source'
            Assert-OrtWebGpuTestPath $dir 'd\test' $false 'test/ dropped'
            Assert-OrtWebGpuTestPath $dir 'd\third_party\test\k' $true 'only the top-level test/ is dropped'
            New-OrtWebGpuTestZip $zip @{ 'dawn-x/src/a.cc' = 'a' }
            Assert-Throws { Expand-OrtDawnArchive -Zip $zip -Destination (Join-Path $dir 'e') } 'no CMakeLists' -MessagePattern 'no top-level CMakeLists'
            New-OrtWebGpuTestZip $zip @{ 'dawn-x/CMakeLists.txt' = 'c'; 'dawn-x/../../evil.txt' = 'e' }
            Assert-Throws { Expand-OrtDawnArchive -Zip $zip -Destination (Join-Path $dir 'f') } 'zip slip' -MessagePattern 'outside'
            Assert-OrtWebGpuTestPath $dir 'evil.txt' $false 'nothing written outside'
        }
    }

    It 'the DXC block becomes the prebuilt targets, $ literals intact, idempotently; a moved block refuses' {
        Invoke-InTestDir { param($dir)
            $cm = Join-Path $dir 'third_party\CMakeLists.txt'
            $text = Assert-OrtWebGpuIdempotentText $cm "function(AddSubdirectoryDXC)`nendfunction()`n`n$($script:DawnDxcBlock)" { Invoke-DawnPrebuiltDxcPatch -DawnSrc $dir 6>$null } @(
                'if (DAWN_USE_BUILT_DXC AND DAWN_PREBUILT_DXC_DIR)', 'add_library(dxcompiler SHARED IMPORTED GLOBAL)',
                'IMPORTED_LOCATION "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.dll"', 'IMPORTED_IMPLIB "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.lib"',
                'message(STATUS "Dawn: prebuilt DXC from ${DAWN_PREBUILT_DXC_DIR}")',
                "elseif (DAWN_USE_BUILT_DXC)`n    AddSubdirectoryDXC()`nendif()", 'if (TINT_BUILD_MESA)') 'missing: ' 'second run changes nothing'
            Assert-False $text.Contains('dxil') 'no dxil.dll target: Dawn v20260916.214021 dropped copy_dxil_dll'
            [System.IO.File]::WriteAllText($cm, "if(DAWN_USE_BUILT_DXC)`n  AddSubdirectoryDXC()`nendif()`n")
            Assert-Throws { Invoke-DawnPrebuiltDxcPatch -DawnSrc $dir 3>$null 6>$null } 'moved block' -MessagePattern 'moved'
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: the whole input chain, offline (downloads and git faked, patch.exe and Python real)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtBuildScript -FunctionName $script:OrtWebGpuBuildFunction)
    # The two network steps, faked AFTER the lift so these definitions win: a URL -> local file map, verified like the real one.
    function Invoke-DownloadWithRetry { param($Url, $DestinationPath, $ExpectedSha256, $ExpectSignature, $Description)
        if (-not $script:OrtFakeDownload.ContainsKey($Url)) { throw "unexpected download: $Url" }
        Copy-Item -LiteralPath $script:OrtFakeDownload[$Url] -Destination $DestinationPath
        Assert-FileSha256 -Path $DestinationPath -Expected $ExpectedSha256 -Label $Description 6>$null
    }
    function Save-OrtDawnDep { param($Dir, $Url, $Commit) $script:OrtFakeFetched.Add("$Url@$Commit"); [void](New-Item -ItemType Directory -Force -Path $Dir) }
    # A fake ORT tree + Dawn zip + DXC zip; returns the env the orchestrator reads.
    function New-OrtWebGpuFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'the fixture writes ORT''s SHA1-shaped deps.txt row')]
        param([string]$Dir, [string]$PatchTarget = 'src/a.txt')
        $c = '0123456789abcdef0123456789abcdef01234567'
        $deps = "vars = {'g': 'https://example.test'}`ndeps = {`n" + ((Get-OrtDawnRequiredDep | ForEach-Object { "  '$_': {'url': '{g}/$_@$c'}," }) -join "`n") + "`n}`n"
        $dawnZip = Join-Path $Dir 'dawn-in.zip'
        New-OrtWebGpuTestZip $dawnZip @{ 'dawn-v/CMakeLists.txt' = 'project(dawn)'; 'dawn-v/src/a.txt' = "one`n"; 'dawn-v/DEPS' = $deps
            'dawn-v/third_party/CMakeLists.txt' = $script:DawnDxcBlock; 'dawn-v/test/big.txt' = 'x' }
        $dxcZip = Join-Path $Dir 'dxc-in.zip'
        New-OrtWebGpuTestZip $dxcZip @{ 'bin\x64\dxcompiler.dll' = 'c'; 'bin\x64\dxil.dll' = 'i'; 'lib\x64\dxcompiler.lib' = 'l'
            'LICENSE-LLVM.txt' = 'L'; 'LICENSE-MS.txt' = 'M'; 'LICENCE-MIT.txt' = 'T' }
        $ort = Join-Path $Dir 'ort'
        $sha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $dawnZip).Hash.ToLowerInvariant()
        Write-TestFileTree -Root $ort -Files @{
            'cmake/deps.txt' = "#Name;Url;SHA1`ndawn;https://github.com/google/dawn/archive/refs/tags/v20260818.211311.zip;$sha1`n"
            'cmake/external/onnxruntime_external_deps.cmake' = "`${Patch_EXECUTABLE} -p1 < `${PROJECT_SOURCE_DIR}/patches/dawn/p1.patch &&"
            'cmake/patches/dawn/p1.patch' = "--- a/$PatchTarget`n+++ b/$PatchTarget`n@@ -1 +1 @@`n-one`n+two`n"
        }
        $script:OrtFakeDownload = @{
            'https://github.com/google/dawn/archive/refs/tags/v20260818.211311.zip' = $dawnZip
            'https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2607/dxc_2026_07_29.zip' = $dxcZip
        }
        $script:OrtFakeFetched = [System.Collections.Generic.List[string]]::new()
        return @{ ORT_WEBGPU_WINDOWS_DAWN_VERSION = 'v20260818.211311'; ORT_WEBGPU_WINDOWS_DXC_VERSION = 'v1.9.2607'; ORT_WEBGPU_WINDOWS_DXC_ASSET = 'dxc_2026_07_29.zip'
            ORT_WEBGPU_WINDOWS_DAWN_SHA256 = (Get-FileHash -LiteralPath $dawnZip).Hash; ORT_WEBGPU_WINDOWS_DXC_SHA256 = (Get-FileHash -LiteralPath $dxcZip).Hash }
    }
    # The orchestrator on that fixture, with $Vars as its environment.
    function Invoke-OrtWebGpuFixtureInput([string]$Dir, [hashtable]$Vars) {
        Invoke-WithEnv $Vars { Initialize-OrtWebGpuInput -OrtSourceDir (Join-Path $Dir 'ort') -WorkDir (Join-Path $Dir 'work') -Python (Get-OrtWebGpuTestPython) 6>$null 3>$null }
    }

    It 'builds the Dawn tree (ORT''s patch applied, DXC swapped, test/ gone), fetches the four DEPS pins, stages DXC' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-OrtWebGpuFixtureInput $dir (New-OrtWebGpuFixture -Dir $dir)
            Assert-Equal "two`n" ([System.IO.File]::ReadAllText((Join-Path $r.DawnSrc 'src\a.txt'))) 'ORT''s Dawn patch applied with GNU patch'
            Assert-True ([System.IO.File]::ReadAllText((Join-Path $r.DawnSrc 'third_party\CMakeLists.txt')).Contains('ANTfrastructure prebuilt DXC')) 'DXC swapped'
            Assert-OrtWebGpuTestPath $r.DawnSrc 'test' $false 'test/ dropped'
            Assert-Equal 4 $script:OrtFakeFetched.Count "fetched: $($script:OrtFakeFetched -join ' ')"
            Assert-True ($script:OrtFakeFetched[0] -eq 'https://example.test/third_party/jinja2@0123456789abcdef0123456789abcdef01234567') "first fetch: $($script:OrtFakeFetched[0])"
            Assert-Equal 'c' ([System.IO.File]::ReadAllText((Join-Path $r.DxcDir 'dxcompiler.dll'))) 'DXC staged'
            Assert-Equal 'v20260818.211311' $r.Pin.DAWN_VERSION 'pins returned'
            Assert-OrtWebGpuTestPath $dir 'work\dawn.zip' $false 'the archives are not left in the work dir'
        }
    }

    It 'refuses a Dawn archive whose SHA256 or ORT SHA1 disagrees, and a patch that does not apply' {
        Invoke-InTestDir { param($dir)
            $vars = New-OrtWebGpuFixture -Dir $dir
            $bad = $vars.Clone(); $bad['ORT_WEBGPU_WINDOWS_DAWN_SHA256'] = 'f' * 64
            Assert-Throws { Invoke-OrtWebGpuFixtureInput $dir $bad } 'SHA256 pin' -MessagePattern 'SHA256 mismatch'
            $depsTxt = Join-Path $dir 'ort\cmake\deps.txt'
            [System.IO.File]::WriteAllText($depsTxt, ([System.IO.File]::ReadAllText($depsTxt) -replace ';[0-9a-f]{40}', (';' + 'a' * 40)))
            Assert-Throws { Invoke-OrtWebGpuFixtureInput $dir $vars } 'SHA1' -MessagePattern 'is not ORT''s deps\.txt'
            $vars = New-OrtWebGpuFixture -Dir $dir -PatchTarget 'src/missing.txt'
            Assert-Throws { Invoke-OrtWebGpuFixtureInput $dir $vars } 'patch' -MessagePattern 'ORT Dawn patch p1\.patch'
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: cmake args, configure/install/wheel gates, marker, wiring' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtBuildScript -FunctionName $script:OrtWebGpuBuildFunction)

    It 'off the spike the configure line gains nothing; on it, the five switches with forward slashes' {
        Assert-Equal 0 @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $false })).Count 'rocm, spike off'
        Assert-Equal 0 @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $false; WebGpu = $false })).Count 'cpu/nvidia'
        $a = @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $true }) -DawnSrc 'C:\w\dawn' -DxcDir 'C:\w\dxc')
        Assert-Equal ('-Donnxruntime_USE_WEBGPU=ON,-Donnxruntime_ENABLE_DAWN_BACKEND_D3D12=ON,-Donnxruntime_ENABLE_DAWN_BACKEND_VULKAN=OFF,' +
            '-Donnxruntime_CUSTOM_DAWN_SRC_PATH=C:/w/dawn,-DDAWN_PREBUILT_DXC_DIR:PATH=C:/w/dxc') ($a -join ',') 'spike args'
    }

    It 'the configure gate: each switch, the prebuilt-DXC branch and no Dawn self-fetch' {
        $cache = "onnxruntime_USE_WEBGPU:BOOL=ON`r`nDAWN_FETCH_DEPENDENCIES:BOOL=OFF`r`nDAWN_USE_BUILT_DXC:BOOL=ON`r`nDAWN_ENABLE_D3D12:BOOL=ON`r`nDAWN_ENABLE_VULKAN:BOOL=OFF`r`n"
        $log = "-- Dawn: prebuilt DXC from C:/w/dxc`n"
        Assert-Equal 0 @(Get-OrtWebGpuConfigureFinding -CacheText $cache -LogText $log).Count 'healthy'
        Assert-TestSingleFindingCases -Message 'configure gate' -Cases @(
                @{ C = $cache.Replace('USE_WEBGPU:BOOL=ON', 'USE_WEBGPU:BOOL=OFF'); L = $log; P = 'onnxruntime_USE_WEBGPU=OFF' }
                @{ C = $cache.Replace("DAWN_FETCH_DEPENDENCIES:BOOL=OFF`r`n", ''); L = $log; P = 'DAWN_FETCH_DEPENDENCIES=<unset>' }
                @{ C = $cache.Replace('BUILT_DXC:BOOL=ON', 'BUILT_DXC:BOOL=OFF'); L = $log; P = 'DAWN_USE_BUILT_DXC=OFF' }
                @{ C = $cache.Replace('D3D12:BOOL=ON', 'D3D12:BOOL=OFF'); L = $log; P = 'DAWN_ENABLE_D3D12=OFF' }
                @{ C = $cache.Replace('VULKAN:BOOL=OFF', 'VULKAN:BOOL=ON'); L = $log; P = 'DAWN_ENABLE_VULKAN=ON' }
                @{ C = $cache; L = ''; P = 'prebuilt-DXC branch' }
                @{ C = $cache; L = $log + "-- Running fetch_dawn_dependencies:`n"; P = 'fetch_dawn_dependencies' }
        ) -Exercise { param($c) Get-OrtWebGpuConfigureFinding -CacheText $c.C -LogText $c.L }
    }

    # A DXC dir as Expand-OrtWebGpuDxc leaves it: dxcompiler.dll and the three licence texts, each holding its own name.
    function New-OrtWebGpuTestDxc([string]$Dir) {
        $dxc = Join-Path $Dir 'dxc'
        'dxcompiler.dll', 'licenses\LICENSE-LLVM.txt', 'licenses\LICENSE-MS.txt', 'licenses\LICENCE-MIT.txt' |
            ForEach-Object { [void](New-Item -ItemType File -Force -Path (Join-Path $dxc $_) -Value "text of $_`n") }
        return $dxc
    }

    It 'install: dxcompiler.dll and the licences land beside onnxruntime.dll; a load-time DXC import refuses' {
        Invoke-InTestDir { param($dir)
            $dxc = New-OrtWebGpuTestDxc $dir
            New-TestPeFile -Path (Join-Path $dir 'ort\bin\onnxruntime.dll')
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('KERNEL32.dll') }
            $sha = Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort')
            Assert-Equal (Get-FileHash -LiteralPath (Join-Path $dxc 'dxcompiler.dll')).Hash.ToLowerInvariant() $sha['dxcompiler.dll'] 'hash returned'
            Assert-Equal 'dxcompiler.dll' (@($sha.Keys) -join ',') 'one DLL staged'
            Assert-OrtWebGpuTestPath $dir 'ort\bin\dxcompiler.dll' $true 'dxcompiler staged'
            Assert-OrtWebGpuTestPath $dir 'ort\bin\dxil.dll' $false 'no dxil.dll'
            Assert-OrtWebGpuTestPath $dir 'ort\licenses\directx-shader-compiler\LICENSE-MS.txt' $true 'licence staged'
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('KERNEL32.dll', 'DXCOMPILER.dll') }
            Assert-Throws { Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort') } 'static DXC' -MessagePattern 'imports DXCOMPILER\.dll'
            Remove-Item (Join-Path $dir 'ort\bin\onnxruntime.dll')
            Assert-Throws { Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort') } 'no ORT' -MessagePattern 'missing after the install'
        }
    }

    It 'the wheel gate: the EP listed, capi''s dxcompiler.dll equal to the staged one and no dxil.dll, DXC''s notice in the wheel' {
        $sha = @{ 'dxcompiler.dll' = 'a' * 64 }
        $ok = @{ providers = @('WebGpuExecutionProvider', 'DmlExecutionProvider', 'CPUExecutionProvider'); dlls = @{ 'dxcompiler.dll' = 'a' * 64 }; dxc_notice = $true }
        Assert-Equal 0 @(Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 $sha).Count 'healthy'
        Assert-TestSingleFindingCases -Message 'wheel gate' -Cases @(
                @{ R = $null; P = 'printed no report' }
                @{ R = @{ error = 'ImportError: x' }; P = 'does not import: ImportError' }
                @{ R = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider'); dlls = $ok.dlls; dxc_notice = $true }; P = 'no WebGpuExecutionProvider' }
                @{ R = @{ providers = $ok.providers; dlls = @{ 'dxcompiler.dll' = 'b' * 64 }; dxc_notice = $true }; P = 'capi\\dxcompiler\.dll is ''b{64}''' }
                @{ R = @{ providers = $ok.providers; dlls = @{}; dxc_notice = $true }; P = 'capi\\dxcompiler\.dll is ''''' }
                @{ R = @{ providers = $ok.providers; dlls = @{ 'dxcompiler.dll' = 'a' * 64; 'dxil.dll' = 'b' * 64 }; dxc_notice = $true }; P = 'capi carries dxil\.dll, which nothing loads since ORT v1\.31\.0' }
                @{ R = @{ providers = $ok.providers; dlls = $ok.dlls; dxc_notice = $false }; P = 'ThirdPartyNotices\.txt lacks ''DirectXShaderCompiler' }
                @{ R = @{ providers = $ok.providers; dlls = $ok.dlls }; P = 'ThirdPartyNotices\.txt lacks' }
        ) -Exercise { param($c) Get-OrtWebGpuWheelFinding -Report $c.R -DllSha256 $sha }
    }

    It 'the wheel gate refuses a staged-hash table that is empty, other-keyed or malformed (no vacuous byte check)' {
        $ok = @{ providers = @('WebGpuExecutionProvider'); dlls = @{ 'dxcompiler.dll' = 'a' * 64 }; dxc_notice = $true }
        Assert-TestSingleFindingCases -Message 'staged-hash table' -Cases @(
                @{ T = @{}; P = 'staged dxcompiler\.dll hash is '''', not a SHA256' }
                @{ T = @{ 'dxil.dll' = 'a' * 64 }; P = 'staged dxcompiler\.dll hash is '''', not a SHA256' }
                @{ T = @{ 'dxcompiler.dll' = 'A' * 64 }; P = 'staged dxcompiler\.dll hash is ''A{64}'', not a SHA256' }
        ) -Exercise { param($c) Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 $c.T }
    }

    It 'the wheel''s notices gain DXC''s texts once, and the real probe (Python, fake package) reads them and capi''s hashes back' {
        Invoke-InTestDir { param($dir)
            $dxc = New-OrtWebGpuTestDxc $dir
            $build = Join-Path $dir 'build'; $pkg = Join-Path $build 'onnxruntime'
            $notices = Join-Path $pkg 'ThirdPartyNotices.txt'
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'capi'))
            $text = Assert-OrtWebGpuIdempotentText $notices "_____`n`ndawn`n`nBSD 3-Clause`n" { Add-OrtWebGpuWheelNotice -BuildDir $build -DxcDir $dxc -DxcVersion 'v1.9.2607' } @(
                "$(Get-OrtDxcNoticeTitle) v1.9.2607", 'https://github.com/microsoft/DirectXShaderCompiler',
                'text of licenses\LICENSE-LLVM.txt', 'text of licenses\LICENSE-MS.txt', 'text of licenses\LICENCE-MIT.txt') 'notices carry: ' 'a second run appends nothing'
            Assert-True $text.StartsWith("_____`n`ndawn`n`nBSD 3-Clause`n") 'ORT''s own notices kept'
            [System.IO.File]::WriteAllText((Join-Path $pkg '__init__.py'), "def get_available_providers():`n    return ['WebGpuExecutionProvider', 'CPUExecutionProvider']`n")
            Copy-Item -Path (Join-Path $dxc '*.dll') -Destination (Join-Path $pkg 'capi')
            $sha = @{ 'dxcompiler.dll' = (Get-FileHash -LiteralPath (Join-Path $dxc 'dxcompiler.dll')).Hash.ToLowerInvariant() }
            $probe = { Invoke-WithEnv @{ PYTHONPATH = $build } { Get-OrtWebGpuWheelReport -Python (Get-OrtWebGpuTestPython) } }
            $f = @(Get-OrtWebGpuWheelFinding -Report (& $probe) -DllSha256 $sha)
            Assert-Equal 0 $f.Count "healthy fake wheel: $($f -join ' | ')"
            [System.IO.File]::WriteAllText((Join-Path $pkg 'capi\dxil.dll'), 'leftover')
            Assert-Match 'capi carries dxil\.dll' (@(Get-OrtWebGpuWheelFinding -Report (& $probe) -DllSha256 $sha) -join '') 'the probe sees a leftover dxil.dll'
            Remove-Item -LiteralPath (Join-Path $pkg 'capi\dxil.dll')
            [System.IO.File]::WriteAllText($notices, "_____`n`ndawn`n")
            Assert-Match 'ThirdPartyNotices\.txt lacks' (@(Get-OrtWebGpuWheelFinding -Report (& $probe) -DllSha256 $sha) -join '') 'the probe sees the notice gone'
            Remove-Item -LiteralPath $notices
            Assert-Throws { Add-OrtWebGpuWheelNotice -BuildDir $build -DxcDir $dxc -DxcVersion 'v1' } 'no notices file' -MessagePattern 'POST_BUILD copy moved'
            [System.IO.File]::WriteAllText($notices, 'x')
            Get-ChildItem -LiteralPath (Join-Path $dxc 'licenses') | Remove-Item
            Assert-Throws { Add-OrtWebGpuWheelNotice -BuildDir $build -DxcDir $dxc -DxcVersion 'v1' } 'no licence texts' -MessagePattern 'no DXC licence texts'
        }
    }

    It 'the marker says the mode, and on the spike the versions and the staged hashes' {
        $off = @(Get-OrtWebGpuFeatureMarker -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $false }))
        Assert-Equal 'ORT_WEBGPU=0' ($off | Where-Object { $_ -notmatch '^#' }) 'spike off'
        $on = @(Get-OrtWebGpuFeatureMarker -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $true }) -Pin ([pscustomobject]@{ DAWN_VERSION = 'v1'; DXC_VERSION = 'v2' }) `
                -DllSha256 @{ 'dxcompiler.dll' = 'c' * 64 })
        Assert-Equal "ORT_WEBGPU=1,DAWN_VERSION=v1,DXC_VERSION=v2,DXCOMPILER_SHA256=$('c' * 64)" (($on | Where-Object { $_ -notmatch '^#' }) -join ',') 'spike on'
    }

    It 'wiring: the spike args are appended only inside the spike branch, gated after configure and install, marker on the rocm lane only' {
        $src = (Get-TestScriptAst -ScriptPath $script:OrtBuildScript).Extent.Text
        Assert-Match '\$webgpuPlan = Get-OrtWebGpuPlan -GpuEnv \$gpuEnv -Cross \$onnxCross -SpikeFlag "\$env:ORT_WEBGPU"' $src 'the plan reads the driver''s ORT_WEBGPU'
        Assert-Match '(?s)if \(\$webgpuPlan\.WebGpu\) \{\s+Switch-BuildPhase [^\n]+\s+\$webgpu = Initialize-OrtWebGpuInput [^\n]+\s+\$cmakeArgs \+= Get-OrtWebGpuCmakeArgs' $src 'args only in the spike branch'
        Assert-Equal 1 ([regex]::Matches($src, '\$cmakeArgs \+= ')).Count 'no other append to the ORT configure line'
        $cfg = $src.IndexOf('Get-OrtWebGpuConfigureFinding -CacheText'); $ninja = $src.IndexOf("Switch-BuildPhase '5. ninja build + install'")
        Assert-True ($cfg -gt 0 -and $cfg -lt $ninja) 'the configure gate runs before ninja'
        Assert-Match '(?s)if \(\$webgpuPlan\.WebGpu\) \{\s+\$webgpuCfg = @\(Get-OrtWebGpuConfigureFinding -CacheText [^\n]+\s+if \(\$webgpuCfg\.Count -gt 0\) \{ throw' $src 'the configure gate throws'
        Assert-Match 'if \(\$webgpuPlan\.OnLane\) \{\s+\$marker = Get-OrtWebGpuFeatureMarker' $src 'the marker is rocm-lane only (cpu/nvidia install trees unchanged)'
        Assert-Match '\$webgpuDllSha = if \(\$webgpuPlan\.WebGpu\) \{ Install-OrtWebGpuRuntime -DxcDir \$webgpu\.DxcDir -OrtInstallDir \$ortInstallDir \}' $src 'the staged hashes come from the install step'
        Assert-Equal 1 ([regex]::Matches($src, '\$webgpuDllSha = if \(\$webgpuPlan\.WebGpu\)')).Count 'the install helper derives hashes only from the staged DLLs'
        Assert-Equal 1 ([regex]::Matches($src, '\$webgpuDllSha = Install-OrtRuntimeSidecars -SourceDir \$SourceDir')).Count 'the build receives hashes from that install helper'
        Assert-Match '(?s)Get-OrtWebGpuWheelFinding -Report \(Get-OrtWebGpuWheelReport -Python \$py\.Exe\) -DllSha256 \$webgpuDllSha\)\s+if \(\$wheelFindings\.Count -gt 0\) \{ throw' $src 'the wheel gate grades against them and throws'
        $notice = $src.IndexOf('if ($webgpuPlan.WebGpu) { Add-OrtWebGpuWheelNotice -BuildDir $buildDir -DxcDir $webgpu.DxcDir -DxcVersion $webgpu.Pin.DXC_VERSION }')
        Assert-True ($notice -gt $src.IndexOf('$webgpuDllSha = ') -and $notice -lt $src.IndexOf("Switch-BuildPhase '6. python wheel'")) 'DXC''s notice is added to the build tree before the wheel is packed'
    }
}

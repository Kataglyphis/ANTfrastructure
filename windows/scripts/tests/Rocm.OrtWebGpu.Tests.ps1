#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The rocm-lane WebGPU EP spike: Build-OnnxFromSource.ps1's plan, pins, fetch chain (offline, with fakes for the
# two downloads), Dawn patch, configure/install/wheel gates, DXC's wheel notice, marker, deps.json rows, OrtWebGpu.ps1.
# NOT covered: a real Dawn/ORT build or setup.py, CMake itself, a GPU, or GenAI failing for want of an adapter.

$script:OrtBuildScript = 'windows\scripts\build\Build-OnnxFromSource.ps1'
$script:OrtWebGpuCheck = 'windows\scripts\build\rocm-checks\OrtWebGpu.ps1'
$script:OrtWebGpuBuildFunction = @('Get-OrtWebGpuPlan', 'Get-OrtWebGpuPin', 'Get-OrtDawnDepsEntry', 'Get-OrtDawnPatchName',
    'Get-OrtDawnRequiredDep', 'Get-OrtDawnDepsProbeSource', 'Invoke-OrtDawnDepsProbe', 'ConvertTo-OrtDawnDepPin', 'Save-OrtDawnDep', 'Expand-OrtZipMember',
    'Expand-OrtWebGpuDxc', 'Expand-OrtDawnArchive', 'Invoke-DawnPrebuiltDxcPatch', 'Resolve-GnuPatchExe', 'Initialize-OrtWebGpuInput',
    'Get-OrtWebGpuCmakeArgs', 'Get-OrtWebGpuConfigureFinding', 'Install-OrtWebGpuRuntime', 'Get-OrtWebGpuWheelFinding',
    'Get-OrtDxcNoticeTitle', 'Add-OrtWebGpuWheelNotice', 'Get-OrtWebGpuWheelReport', 'Get-OrtWebGpuFeatureMarker')
$script:OrtWebGpuDepsJson = 'docs\deps\deps.json'
# ORT v1.30.0 cmake/deps.txt, verbatim: the row Get-OrtDawnDepsEntry grades.
$script:OrtDawnRow = 'dawn;https://github.com/google/dawn/archive/refs/tags/v20260818.211311.zip;10e42c94f70fc222ecbafebbd1cfbb5482593d59'
# Dawn v20260818.211311 third_party/CMakeLists.txt, the block Invoke-DawnPrebuiltDxcPatch rewrites (verbatim).
$script:DawnDxcBlock = "if (DAWN_USE_BUILT_DXC)`n    AddSubdirectoryDXC()`nendif()`n`nif (TINT_BUILD_MESA)`n"

# Repo-relative, or rooted as given (a mutation run points the paths above at mutant copies).
function Resolve-OrtWebGpuSuitePath([string]$Path) { if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-RepoRoot) $Path } }

# versions.env as the build sees it, a fresh copy per call (Get-OrtWebGpuPin reads only its own keys).
function Get-OrtWebGpuTestPin { ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env') }

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

function Get-OrtWebGpuTestPython {
    $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { throw 'python is not on PATH: the DEPS probe is Python and must run for real here' }
    return $py.Source
}

Describe 'Build-OnnxFromSource WebGPU: plan and pins (cpu/nvidia never enter the spike)' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtBuildScript) -FunctionName $script:OrtWebGpuBuildFunction)

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

    It 'the real pins parse, and the Dawn tag is the one ORT v1.30.0''s deps.txt fetches' {
        $pin = Get-OrtWebGpuPin -Source (Get-OrtWebGpuTestPin)
        $entry = Get-OrtDawnDepsEntry -DepsLine @('#Name;Url;SHA1', $script:OrtDawnRow) -DawnVersion $pin.DAWN_VERSION
        Assert-Equal '10e42c94f70fc222ecbafebbd1cfbb5482593d59' $entry.Sha1 'ORT''s SHA1'
        Assert-Equal 'dxc_2026_07_29.zip' $pin.DXC_ASSET 'DXC asset'
        Assert-Equal 'v1.30.0' (Get-OrtWebGpuTestPin)['ONNXRUNTIME_VERSION'] 'the row above is v1.30.0''s: re-capture it with ORT'
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
                @{ L = @($script:OrtDawnRow -replace 'v20260818\.211311', 'v20261001.000000'); P = 're-derive' }
                @{ L = @($script:OrtDawnRow, $script:OrtDawnRow); P = '2 ''dawn;'' rows' }
                @{ L = @('abseil_cpp;x;y'); P = '0 ''dawn;'' rows' }
                @{ L = @($script:OrtDawnRow -replace ';[0-9a-f]{40}$', ';sha256:abcd'); P = 'not a SHA1' })) {
            Assert-Throws { Get-OrtDawnDepsEntry -DepsLine $c.L -DawnVersion 'v20260818.211311' } $c.P -MessagePattern $c.P
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: ORT''s patch list, Dawn DEPS and the dependency fetch' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtBuildScript) -FunctionName $script:OrtWebGpuBuildFunction)

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
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtBuildScript) -FunctionName $script:OrtWebGpuBuildFunction)

    It 'DXC: the six members come out of a backslash-named zip, and a missing one refuses' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'dxc.zip'
            $members = @{ 'bin\x64\dxcompiler.dll' = 'c'; 'bin\x64\dxil.dll' = 'i'; 'lib\x64\dxcompiler.lib' = 'l'; 'bin\arm64\dxil.dll' = 'arm'
                'LICENSE-LLVM.txt' = 'L'; 'LICENSE-MS.txt' = 'M'; 'LICENCE-MIT.txt' = 'T'; 'inc\dxcapi.h' = 'h' }
            New-OrtWebGpuTestZip $zip $members
            Expand-OrtWebGpuDxc -Zip $zip -Destination (Join-Path $dir 'out')
            Assert-Equal 'i' ([System.IO.File]::ReadAllText((Join-Path $dir 'out\dxil.dll'))) 'the x64 dxil, not arm64'
            Assert-True (Test-Path (Join-Path $dir 'out\licenses\LICENSE-MS.txt')) 'licences'
            Assert-False (Test-Path (Join-Path $dir 'out\dxcapi.h')) 'nothing unasked'
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
            Assert-True (Test-Path (Join-Path $dir 'd\src\a.cc')) 'source'
            Assert-False (Test-Path (Join-Path $dir 'd\test')) 'test/ dropped'
            Assert-True (Test-Path (Join-Path $dir 'd\third_party\test\k')) 'only the top-level test/ is dropped'
            New-OrtWebGpuTestZip $zip @{ 'dawn-x/src/a.cc' = 'a' }
            Assert-Throws { Expand-OrtDawnArchive -Zip $zip -Destination (Join-Path $dir 'e') } 'no CMakeLists' -MessagePattern 'no top-level CMakeLists'
            New-OrtWebGpuTestZip $zip @{ 'dawn-x/CMakeLists.txt' = 'c'; 'dawn-x/../../evil.txt' = 'e' }
            Assert-Throws { Expand-OrtDawnArchive -Zip $zip -Destination (Join-Path $dir 'f') } 'zip slip' -MessagePattern 'outside'
            Assert-False (Test-Path (Join-Path $dir 'evil.txt')) 'nothing written outside'
        }
    }

    It 'the DXC block becomes the prebuilt targets, $ literals intact, idempotently; a moved block refuses' {
        Invoke-InTestDir { param($dir)
            $cm = Join-Path $dir 'third_party\CMakeLists.txt'
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $cm -Parent))
            [System.IO.File]::WriteAllText($cm, "function(AddSubdirectoryDXC)`nendfunction()`n`n$($script:DawnDxcBlock)")
            Invoke-DawnPrebuiltDxcPatch -DawnSrc $dir 6>$null
            $text = [System.IO.File]::ReadAllText($cm)
            foreach ($want in 'if (DAWN_USE_BUILT_DXC AND DAWN_PREBUILT_DXC_DIR)', 'add_library(dxcompiler SHARED IMPORTED GLOBAL)',
                'IMPORTED_LOCATION "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.dll"', 'IMPORTED_IMPLIB "${DAWN_PREBUILT_DXC_DIR}/dxcompiler.lib"',
                'add_custom_target(copy_dxil_dll', 'message(STATUS "Dawn: prebuilt DXC from ${DAWN_PREBUILT_DXC_DIR}")',
                "elseif (DAWN_USE_BUILT_DXC)`n    AddSubdirectoryDXC()`nendif()", 'if (TINT_BUILD_MESA)') {
                Assert-True $text.Contains($want) "missing: $want"
            }
            Invoke-DawnPrebuiltDxcPatch -DawnSrc $dir 6>$null
            Assert-Equal $text ([System.IO.File]::ReadAllText($cm)) 'second run changes nothing'
            [System.IO.File]::WriteAllText($cm, "if(DAWN_USE_BUILT_DXC)`n  AddSubdirectoryDXC()`nendif()`n")
            Assert-Throws { Invoke-DawnPrebuiltDxcPatch -DawnSrc $dir 3>$null 6>$null } 'moved block' -MessagePattern 'moved'
        }
    }
}

Describe 'Build-OnnxFromSource WebGPU: the whole input chain, offline (downloads and git faked, patch.exe and Python real)' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtBuildScript) -FunctionName $script:OrtWebGpuBuildFunction)
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
        foreach ($d in 'cmake\external', 'cmake\patches\dawn') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $ort $d)) }
        $sha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $dawnZip).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText((Join-Path $ort 'cmake\deps.txt'), "#Name;Url;SHA1`ndawn;https://github.com/google/dawn/archive/refs/tags/v20260818.211311.zip;$sha1`n")
        [System.IO.File]::WriteAllText((Join-Path $ort 'cmake\external\onnxruntime_external_deps.cmake'), "`${Patch_EXECUTABLE} -p1 < `${PROJECT_SOURCE_DIR}/patches/dawn/p1.patch &&")
        [System.IO.File]::WriteAllText((Join-Path $ort 'cmake\patches\dawn\p1.patch'), "--- a/$PatchTarget`n+++ b/$PatchTarget`n@@ -1 +1 @@`n-one`n+two`n")
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
            Assert-False (Test-Path (Join-Path $r.DawnSrc 'test')) 'test/ dropped'
            Assert-Equal 4 $script:OrtFakeFetched.Count "fetched: $($script:OrtFakeFetched -join ' ')"
            Assert-True ($script:OrtFakeFetched[0] -eq 'https://example.test/third_party/jinja2@0123456789abcdef0123456789abcdef01234567') "first fetch: $($script:OrtFakeFetched[0])"
            Assert-Equal 'c' ([System.IO.File]::ReadAllText((Join-Path $r.DxcDir 'dxcompiler.dll'))) 'DXC staged'
            Assert-Equal 'v20260818.211311' $r.Pin.DAWN_VERSION 'pins returned'
            Assert-False (Test-Path (Join-Path $dir 'work\dawn.zip')) 'the archives are not left in the work dir'
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
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtBuildScript) -FunctionName $script:OrtWebGpuBuildFunction)

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
        foreach ($c in @(
                @{ C = $cache.Replace('USE_WEBGPU:BOOL=ON', 'USE_WEBGPU:BOOL=OFF'); L = $log; P = 'onnxruntime_USE_WEBGPU=OFF' }
                @{ C = $cache.Replace("DAWN_FETCH_DEPENDENCIES:BOOL=OFF`r`n", ''); L = $log; P = 'DAWN_FETCH_DEPENDENCIES=<unset>' }
                @{ C = $cache.Replace('BUILT_DXC:BOOL=ON', 'BUILT_DXC:BOOL=OFF'); L = $log; P = 'DAWN_USE_BUILT_DXC=OFF' }
                @{ C = $cache.Replace('D3D12:BOOL=ON', 'D3D12:BOOL=OFF'); L = $log; P = 'DAWN_ENABLE_D3D12=OFF' }
                @{ C = $cache.Replace('VULKAN:BOOL=OFF', 'VULKAN:BOOL=ON'); L = $log; P = 'DAWN_ENABLE_VULKAN=ON' }
                @{ C = $cache; L = ''; P = 'prebuilt-DXC branch' }
                @{ C = $cache; L = $log + "-- Running fetch_dawn_dependencies:`n"; P = 'fetch_dawn_dependencies' })) {
            $f = @(Get-OrtWebGpuConfigureFinding -CacheText $c.C -LogText $c.L)
            Assert-Equal 1 $f.Count "case /$($c.P)/: $($f -join ' | ')"
            Assert-Match $c.P $f[0] $c.P
        }
    }

    # A DXC dir as Expand-OrtWebGpuDxc leaves it: the pair and the three licence texts, each holding its own name.
    function New-OrtWebGpuTestDxc([string]$Dir) {
        $dxc = Join-Path $Dir 'dxc'
        'dxcompiler.dll', 'dxil.dll', 'licenses\LICENSE-LLVM.txt', 'licenses\LICENSE-MS.txt', 'licenses\LICENCE-MIT.txt' |
            ForEach-Object { [void](New-Item -ItemType File -Force -Path (Join-Path $dxc $_) -Value "text of $_`n") }
        return $dxc
    }

    It 'install: the DXC pair and licences land beside onnxruntime.dll; a load-time DXC import refuses' {
        Invoke-InTestDir { param($dir)
            $dxc = New-OrtWebGpuTestDxc $dir
            New-TestPeFile -Path (Join-Path $dir 'ort\bin\onnxruntime.dll')
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('KERNEL32.dll') }
            $sha = Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort')
            Assert-Equal (Get-FileHash -LiteralPath (Join-Path $dxc 'dxil.dll')).Hash.ToLowerInvariant() $sha['dxil.dll'] 'hash returned'
            Assert-True (Test-Path (Join-Path $dir 'ort\bin\dxcompiler.dll')) 'dxcompiler staged'
            Assert-True (Test-Path (Join-Path $dir 'ort\licenses\directx-shader-compiler\LICENSE-MS.txt')) 'licence staged'
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('KERNEL32.dll', 'DXCOMPILER.dll') }
            Assert-Throws { Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort') } 'static DXC' -MessagePattern 'imports DXCOMPILER\.dll'
            Remove-Item (Join-Path $dir 'ort\bin\onnxruntime.dll')
            Assert-Throws { Install-OrtWebGpuRuntime -DxcDir $dxc -OrtInstallDir (Join-Path $dir 'ort') } 'no ORT' -MessagePattern 'missing after the install'
        }
    }

    It 'the wheel gate: the EP listed, capi''s DXC pair equal to the staged one, DXC''s notice in the wheel' {
        $sha = @{ 'dxcompiler.dll' = 'a' * 64; 'dxil.dll' = 'b' * 64 }
        $ok = @{ providers = @('WebGpuExecutionProvider', 'DmlExecutionProvider', 'CPUExecutionProvider'); dlls = @{ 'dxcompiler.dll' = 'a' * 64; 'dxil.dll' = 'b' * 64 }; dxc_notice = $true }
        Assert-Equal 0 @(Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 $sha).Count 'healthy'
        foreach ($c in @(
                @{ R = $null; P = 'printed no report' }
                @{ R = @{ error = 'ImportError: x' }; P = 'does not import: ImportError' }
                @{ R = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider'); dlls = $ok.dlls; dxc_notice = $true }; P = 'no WebGpuExecutionProvider' }
                @{ R = @{ providers = $ok.providers; dlls = @{ 'dxcompiler.dll' = 'a' * 64 }; dxc_notice = $true }; P = 'capi\\dxil\.dll is ''''' }
                @{ R = @{ providers = $ok.providers; dlls = @{ 'dxil.dll' = 'b' * 64 }; dxc_notice = $true }; P = 'capi\\dxcompiler\.dll is ''''' }
                @{ R = @{ providers = $ok.providers; dlls = $ok.dlls; dxc_notice = $false }; P = 'ThirdPartyNotices\.txt lacks ''DirectXShaderCompiler' }
                @{ R = @{ providers = $ok.providers; dlls = $ok.dlls }; P = 'ThirdPartyNotices\.txt lacks' })) {
            $f = @(Get-OrtWebGpuWheelFinding -Report $c.R -DllSha256 $sha)
            Assert-Equal 1 $f.Count "case /$($c.P)/: $($f -join ' | ')"
            Assert-Match $c.P $f[0] $c.P
        }
    }

    It 'the wheel gate refuses a staged-hash table that is empty, short or malformed (no vacuous byte check)' {
        $ok = @{ providers = @('WebGpuExecutionProvider'); dlls = @{ 'dxcompiler.dll' = 'a' * 64; 'dxil.dll' = 'b' * 64 }; dxc_notice = $true }
        $f = @(Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 @{}) -join "`n"
        Assert-Match 'staged dxcompiler\.dll hash is '''', not a SHA256' $f 'empty table: dxcompiler'
        Assert-Match 'staged dxil\.dll hash is '''', not a SHA256' $f 'empty table: dxil'
        $f = @(Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 @{ 'dxcompiler.dll' = 'a' * 64 })
        Assert-Equal 1 $f.Count "one key: $($f -join ' | ')"
        Assert-Match 'staged dxil\.dll hash is ''''' $f[0] 'one key: the missing dxil'
        $f = @(Get-OrtWebGpuWheelFinding -Report $ok -DllSha256 @{ 'dxcompiler.dll' = 'a' * 64; 'dxil.dll' = 'B' * 64 })
        Assert-Match 'staged dxil\.dll hash is ''B{64}'', not a SHA256' ($f -join '') 'the lowercase hex Install-OrtWebGpuRuntime returns'
    }

    It 'the wheel''s notices gain DXC''s texts once, and the real probe (Python, fake package) reads them and capi''s hashes back' {
        Invoke-InTestDir { param($dir)
            $dxc = New-OrtWebGpuTestDxc $dir
            $build = Join-Path $dir 'build'; $pkg = Join-Path $build 'onnxruntime'
            $notices = Join-Path $pkg 'ThirdPartyNotices.txt'
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'capi'))
            [System.IO.File]::WriteAllText($notices, "_____`n`ndawn`n`nBSD 3-Clause`n")
            Add-OrtWebGpuWheelNotice -BuildDir $build -DxcDir $dxc -DxcVersion 'v1.9.2607'
            $text = [System.IO.File]::ReadAllText($notices)
            Assert-True $text.StartsWith("_____`n`ndawn`n`nBSD 3-Clause`n") 'ORT''s own notices kept'
            foreach ($w in "$(Get-OrtDxcNoticeTitle) v1.9.2607", 'https://github.com/microsoft/DirectXShaderCompiler',
                'text of licenses\LICENSE-LLVM.txt', 'text of licenses\LICENSE-MS.txt', 'text of licenses\LICENCE-MIT.txt') {
                Assert-True $text.Contains($w) "notices carry: $w"
            }
            Add-OrtWebGpuWheelNotice -BuildDir $build -DxcDir $dxc -DxcVersion 'v1.9.2607'
            Assert-Equal $text ([System.IO.File]::ReadAllText($notices)) 'a second run appends nothing'
            [System.IO.File]::WriteAllText((Join-Path $pkg '__init__.py'), "def get_available_providers():`n    return ['WebGpuExecutionProvider', 'CPUExecutionProvider']`n")
            Copy-Item -Path (Join-Path $dxc '*.dll') -Destination (Join-Path $pkg 'capi')
            $sha = @{ 'dxcompiler.dll' = (Get-FileHash -LiteralPath (Join-Path $dxc 'dxcompiler.dll')).Hash.ToLowerInvariant()
                'dxil.dll' = (Get-FileHash -LiteralPath (Join-Path $dxc 'dxil.dll')).Hash.ToLowerInvariant() }
            $probe = { Invoke-WithEnv @{ PYTHONPATH = $build } { Get-OrtWebGpuWheelReport -Python (Get-OrtWebGpuTestPython) } }
            $f = @(Get-OrtWebGpuWheelFinding -Report (& $probe) -DllSha256 $sha)
            Assert-Equal 0 $f.Count "healthy fake wheel: $($f -join ' | ')"
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
                -DllSha256 @{ 'dxcompiler.dll' = 'c' * 64; 'dxil.dll' = 'd' * 64 })
        Assert-Equal "ORT_WEBGPU=1,DAWN_VERSION=v1,DXC_VERSION=v2,DXCOMPILER_SHA256=$('c' * 64),DXIL_SHA256=$('d' * 64)" (($on | Where-Object { $_ -notmatch '^#' }) -join ',') 'spike on'
    }

    It 'wiring: the spike args are appended only inside the spike branch, gated after configure and install, marker on the rocm lane only' {
        $src = [System.IO.File]::ReadAllText((Resolve-OrtWebGpuSuitePath $script:OrtBuildScript))
        Assert-Match '\$webgpuPlan = Get-OrtWebGpuPlan -GpuEnv \$gpuEnv -Cross \$onnxCross -SpikeFlag "\$env:ORT_WEBGPU"' $src 'the plan reads the driver''s ORT_WEBGPU'
        Assert-Match '(?s)if \(\$webgpuPlan\.WebGpu\) \{\s+Switch-BuildPhase [^\n]+\s+\$webgpu = Initialize-OrtWebGpuInput [^\n]+\s+\$cmakeArgs \+= Get-OrtWebGpuCmakeArgs' $src 'args only in the spike branch'
        Assert-Equal 1 ([regex]::Matches($src, '\$cmakeArgs \+= ')).Count 'no other append to the ORT configure line'
        $cfg = $src.IndexOf('Get-OrtWebGpuConfigureFinding -CacheText'); $ninja = $src.IndexOf("Switch-BuildPhase '5. ninja build + install'")
        Assert-True ($cfg -gt 0 -and $cfg -lt $ninja) 'the configure gate runs before ninja'
        Assert-Match '(?s)if \(\$webgpuPlan\.WebGpu\) \{\s+\$webgpuCfg = @\(Get-OrtWebGpuConfigureFinding -CacheText [^\n]+\s+if \(\$webgpuCfg\.Count -gt 0\) \{ throw' $src 'the configure gate throws'
        Assert-Match 'if \(\$webgpuPlan\.OnLane\) \{\s+\$marker = Get-OrtWebGpuFeatureMarker' $src 'the marker is rocm-lane only (cpu/nvidia install trees unchanged)'
        Assert-Match '\$webgpuDllSha = if \(\$webgpuPlan\.WebGpu\) \{ Install-OrtWebGpuRuntime -DxcDir \$webgpu\.DxcDir -OrtInstallDir \$ortInstallDir \}' $src 'the staged hashes come from the install step'
        Assert-Equal 1 ([regex]::Matches($src, '\$webgpuDllSha = ')).Count 'nothing else assigns the staged hashes'
        Assert-Match '(?s)Get-OrtWebGpuWheelFinding -Report \(Get-OrtWebGpuWheelReport -Python \$py\.Exe\) -DllSha256 \$webgpuDllSha\)\s+if \(\$wheelFindings\.Count -gt 0\) \{ throw' $src 'the wheel gate grades against them and throws'
        $notice = $src.IndexOf('if ($webgpuPlan.WebGpu) { Add-OrtWebGpuWheelNotice -BuildDir $buildDir -DxcDir $webgpu.DxcDir -DxcVersion $webgpu.Pin.DXC_VERSION }')
        Assert-True ($notice -gt $src.IndexOf('$webgpuDllSha = ') -and $notice -lt $src.IndexOf("Switch-BuildPhase '6. python wheel'")) 'DXC''s notice is added to the build tree before the wheel is packed'
    }
}

Describe 'rocm-checks\OrtWebGpu.ps1: the spike mode, the DXC pair and each interpreter' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Resolve-OrtWebGpuSuitePath $script:OrtWebGpuCheck) -FunctionName 'Read-OrtWebGpuMarker', 'Get-OrtWebGpuDxcKey',
        'Get-OrtWebGpuMarkerFinding', 'Test-OrtWebGpuOutcome', 'Get-OrtWebGpuProbeSource', 'Get-OrtWebGpuInterpreterFinding')
    # A spike-on ORT root: bin\ with the DXC pair and the licence, and the marker naming their hashes.
    function New-OrtWebGpuTestRoot([string]$Dir, [string]$Mode = '1') {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'bin'), (Join-Path $Dir 'licenses\directx-shader-compiler'))
        $lines = @('# test', "ORT_WEBGPU=$Mode")
        if ($Mode -eq '1') {
            foreach ($dll in 'dxcompiler.dll', 'dxil.dll') { [System.IO.File]::WriteAllText((Join-Path $Dir "bin\$dll"), $dll) }
            [System.IO.File]::WriteAllText((Join-Path $Dir 'licenses\directx-shader-compiler\LICENSE-MS.txt'), 'ms')
            $lines += "DXCOMPILER_SHA256=$((Get-FileHash (Join-Path $Dir 'bin\dxcompiler.dll')).Hash.ToLowerInvariant())", "DXIL_SHA256=$((Get-FileHash (Join-Path $Dir 'bin\dxil.dll')).Hash.ToLowerInvariant())"
        }
        [System.IO.File]::WriteAllLines((Join-Path $Dir 'ROCM-FEATURES.txt'), [string[]]$lines)
        return Read-OrtWebGpuMarker -Path (Join-Path $Dir 'ROCM-FEATURES.txt')
    }
    function New-OrtWebGpuReport([hashtable]$Marker, [hashtable]$Override = @{}) {
        $r = @{ providers = @('WebGpuExecutionProvider', 'DmlExecutionProvider', 'CPUExecutionProvider'); capi = 'C:\v\Lib\site-packages\onnxruntime\capi'
            session = 'fell back to [''CPUExecutionProvider'']: webgpu_context.cc:69 Failed to get a WebGPU adapter: No supported adapters'
            dlls = @{ 'dxcompiler.dll' = @{ sha256 = $Marker['DXCOMPILER_SHA256']; entry = $true }; 'dxil.dll' = @{ sha256 = $Marker['DXIL_SHA256']; entry = $true } }
            genai_ort = 'c:\V\lib\site-packages\onnxruntime\capi\onnxruntime.dll'; genai_session = 'RuntimeError: Failed to get a WebGPU adapter: No supported adapters' }
        foreach ($k in $Override.Keys) { $r[$k] = $Override[$k] }
        return $r
    }

    It 'a spike image passes, and each marker defect is its own finding' {
        Invoke-InTestDir { param($dir)
            $m = New-OrtWebGpuTestRoot -Dir $dir
            $grade = { param($Marker, $Expect) @(Get-OrtWebGpuMarkerFinding -Marker $Marker -MarkerPath 'm' -Expect $Expect -OrtRoot $dir) }
            Assert-Equal 0 @(& $grade $m '1').Count "healthy: $((& $grade $m '1') -join ' | ')"
            Assert-Match 'missing: the rocm-lane ORT build writes it' ((& $grade $null '1') -join '') 'no marker'
            Assert-Match 'cannot be graded' ((& $grade $m '') -join '') 'no EXPECT_ROCM_SPIKES'
            Assert-Match 'ORT_WEBGPU=1, EXPECT_ROCM_SPIKES=0: an onnx stage from the other spike mode' ((& $grade $m '0') -join '') 'stale parent'
            [System.IO.File]::WriteAllText((Join-Path $dir 'bin\dxil.dll'), 'swapped')
            Assert-Match 'bin\\dxil\.dll is [0-9a-f]{64}, the build staged' ((& $grade $m '1') -join '') 'other bytes'
            Remove-Item (Join-Path $dir 'bin\dxcompiler.dll'), (Join-Path $dir 'licenses\directx-shader-compiler\LICENSE-MS.txt')
            $f = (& $grade $m '1') -join "`n"
            Assert-Match 'dxcompiler\.dll missing beside onnxruntime\.dll' $f 'missing DLL'
            Assert-Match 'licence texts are missing' $f 'missing licence'
            $m['DXIL_SHA256'] = ''
            Assert-Match 'DXIL_SHA256 is '''', not a SHA256' ((& $grade $m '1') -join '') 'empty hash in the marker'
        }
    }

    It 'a -NoRocmSpikes image passes with no DXC beside ORT, and is flagged when a WebGPU leftover ships' {
        Invoke-InTestDir { param($dir)
            $m = New-OrtWebGpuTestRoot -Dir $dir -Mode '0'
            Assert-Equal 0 @(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '0' -OrtRoot $dir).Count 'healthy'
            Assert-Match 'EXPECT_ROCM_SPIKES=1' (@(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '1' -OrtRoot $dir) -join '') 'spike asked, none built'
            [System.IO.File]::WriteAllText((Join-Path $dir 'bin\dxil.dll'), 'x')
            Assert-Match 'dxil\.dll ships although ORT_WEBGPU=0' (@(Get-OrtWebGpuMarkerFinding -Marker $m -MarkerPath 'm' -Expect '0' -OrtRoot $dir) -join '') 'leftover'
        }
    }

    It 'a session may use WebGPU or fail for want of an adapter; nothing else passes' {
        foreach ($ok in 'webgpu', 'created', 'RuntimeError: ... Failed to get a WebGPU adapter: No supported adapters', 'fell back to [x]: Failed to get a WebGPU adapter.') {
            Assert-True (Test-OrtWebGpuOutcome $ok) "accepted: $ok"
        }
        foreach ($bad in '', 'fell back to [''CPUExecutionProvider'']: LoadLibrary failed with error 126 "dxcompiler.dll"', 'RuntimeError: WebGPU execution provider is not supported in this build',
            'Failed to get a WebGPU device.', 'failed to get a webgpu adapter') {
            Assert-False (Test-OrtWebGpuOutcome $bad) "refused: $bad"
        }
    }

    It 'an interpreter on the spike image passes; each defect is its own finding' {
        $m = @{ ORT_WEBGPU = '1'; DXCOMPILER_SHA256 = 'c' * 64; DXIL_SHA256 = 'd' * 64 }
        Assert-Equal 0 @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report (New-OrtWebGpuReport $m) -WebGpu $true -Marker $m).Count 'healthy (paths compared case-insensitively)'
        $dll = { param($Name, $Sha, $Entry) $d = (New-OrtWebGpuReport $m).dlls; $d[$Name] = @{ sha256 = $Sha; entry = $Entry }; $d }
        foreach ($c in @(
                @{ O = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider') }; P = 'no WebGpuExecutionProvider' }
                @{ O = @{ session = 'RuntimeError: D3D12CreateDevice failed' }; P = 'session failed, and not for want of an adapter: RuntimeError: D3D12' }
                @{ O = @{ dlls = (& $dll 'dxil.dll' ('e' * 64) $true) }; P = 'capi\\dxil\.dll is e{64}, the build staged d{64}' }
                @{ O = @{ dlls = (& $dll 'dxcompiler.dll' ('c' * 64) $false) }; P = 'capi\\dxcompiler\.dll does not load' }
                @{ O = @{ dlls = @{ 'dxcompiler.dll' = @{ sha256 = 'c' * 64; entry = $true } } }; P = 'capi has no dxil\.dll' }
                @{ O = @{ genai_error = 'ImportError: onnxruntime-genai.dll' }; P = 'import onnxruntime_genai failed' }
                @{ O = @{ genai_ort = 'C:\Windows\System32\onnxruntime.dll' }; P = 'GenAI runs on ''C:\\Windows\\System32\\onnxruntime\.dll''' }
                @{ O = @{ genai_session = 'RuntimeError: WebGPU execution provider is not supported in this build' }; P = 'GenAI''s WebGPU model failed' })) {
            $f = @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report (New-OrtWebGpuReport $m $c.O) -WebGpu $true -Marker $m)
            Assert-Equal 1 $f.Count "case /$($c.P)/: $($f -join ' | ')"
            Assert-Match $c.P $f[0] $c.P
        }
        Assert-Match 'import onnxruntime failed' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report @{ error = 'x' } -WebGpu $true -Marker $m) 'no ORT'
        Assert-Match 'the probe exited 1' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report 'the probe exited 1 without a report' -WebGpu $true -Marker $m) 'probe failure'
        Assert-Match 'no report' (Get-OrtWebGpuInterpreterFinding -Label 'base' -Report $null -WebGpu $true -Marker $m) 'null report'
    }

    It 'without the spike, a listed WebGPU EP or a DXC pair in capi is a finding' {
        $m = @{ ORT_WEBGPU = '0' }
        $plain = @{ providers = @('DmlExecutionProvider', 'CPUExecutionProvider'); capi = 'C:\v'; dlls = @{} }
        Assert-Equal 0 @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report $plain -WebGpu $false -Marker $m).Count 'healthy'
        $plain.providers = @('WebGpuExecutionProvider', 'CPUExecutionProvider'); $plain.dlls = @{ 'dxil.dll' = @{ sha256 = 'x'; entry = $true } }
        $f = @(Get-OrtWebGpuInterpreterFinding -Label 'venv' -Report $plain -WebGpu $false -Marker $m) -join "`n"
        Assert-Match 'lists WebGpuExecutionProvider although the marker says ORT_WEBGPU=0' $f 'listed'
        Assert-Match 'capi carries dxil\.dll without the WebGPU EP' $f 'leftover'
    }

    It 'the probe: the identity model is the smoke suite''s, stdout is captured around the fallback, dxil loads first, GenAI asks for webgpu' {
        $src = Get-OrtWebGpuProbeSource
        $tc = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Container.ps1'))
        $bytes = [regex]::Match($tc, '(?s)\$script:identityOnnxBytes = \[byte\[\]\]@\((.*?)\)').Groups[1].Value
        $hex = -join ([regex]::Matches($bytes, '0x([0-9A-Fa-f]{2})') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
        Assert-True ($hex.Length -eq 126) "identity model in Test-Container.ps1: $($hex.Length / 2) bytes"
        Assert-Match "bytes\.fromhex\(`"$hex`"\)" $src 'the same 63-byte Identity model'
        Assert-Match 'contextlib\.redirect_stdout\(printed\)' $src 'the fallback''s printed EP error is captured'
        Assert-True ($src.IndexOf('"dxil.dll", "dxcompiler.dll"') -gt $src.IndexOf('og.Model(og.Config(model_dir))')) 'DXC loads last, dxil first (as Dawn does)'
        Assert-Match '"provider_options": \[\{"webgpu": \{\}\}\]' $src 'GenAI asks for its webgpu provider'
        Assert-False ($src -match 'ALLOW_SOFTWARE|forceFallback|dawnBackendType|register_execution_provider_library') 'no adapter forcing, no plugin EP'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-OrtWebGpuSuitePath $script:OrtWebGpuCheck), [ref]$null, [ref]$null)
        Assert-Null $ast.ParamBlock 'rocm-checks scripts take no parameters (Test-RocmImage.ps1 runs them bare)'
    }

    It 'the whole script: no marker is one finding, a stale spike mode stops before any probe, a gradable one probes base AND venv' {
        Invoke-InTestDir { param($dir)
            $check = Resolve-OrtWebGpuSuitePath $script:OrtWebGpuCheck
            $shim = Join-Path $dir 'shim'
            $run = { @(Invoke-WithEnv @{ ONNX_ROOT = $dir; EXPECT_ROCM_SPIKES = '1'; TORCH_APP_DIR = $dir; PATH = "$shim;$env:SystemRoot\System32" } { & $check 6>$null }) }
            $out = @(& $run)
            Assert-Equal 1 $out.Count "no marker: $($out -join ' / ')"
            Assert-Match 'ROCM-FEATURES\.txt missing' $out[0] 'no marker'
            [void](New-OrtWebGpuTestRoot -Dir $dir -Mode '0')
            [void](New-Item -ItemType Directory -Path $shim)
            [System.IO.File]::WriteAllText((Join-Path $shim 'python.cmd'), "@echo {`"error`": `"base shim`"}`r`n")
            $out = @(& $run)
            Assert-Equal 1 $out.Count "stale: $($out -join ' / ')"
            Assert-Match 'ORT_WEBGPU=0, EXPECT_ROCM_SPIKES=1' $out[0] 'stale mode, no python probed'
            [void](New-OrtWebGpuTestRoot -Dir $dir -Mode '1')
            & (Get-OrtWebGpuTestPython) -m venv --without-pip (Join-Path $dir '.venv') | Out-Null
            Assert-Equal 0 $LASTEXITCODE 'a real venv for the app interpreter'
            $out = @(& $run)
            Assert-Equal 2 $out.Count "gradable: $($out -join ' / ')"
            Assert-Match '^OrtWebGpu \[base\]: import onnxruntime failed: base shim$' $out[0] 'the base python on PATH is probed'
            Assert-Match '^OrtWebGpu \[venv\]: import onnxruntime failed: ModuleNotFoundError' $out[1] 'the app venv is probed with the real probe source'
        }
    }
}

Describe 'deps.json: what the WebGPU spike ships beside and inside the chain ORT' {
    It 'names the DXC pair and Dawn/Tint in Windows rows with an spdx id, versioned by the ORT_WEBGPU_WINDOWS_* pins' {
        $doc = [System.IO.File]::ReadAllText((Resolve-OrtWebGpuSuitePath $script:OrtWebGpuDepsJson)) | ConvertFrom-Json -AsHashtable
        $byVar = @{}
        foreach ($sub in @($doc['sections'] | Where-Object { $_['title'] -eq 'Windows Image' } | ForEach-Object { $_['subsections'] })) {
            foreach ($e in @($sub['entries'] | Where-Object { $_['spdx'] -and $_['var'] })) {
                if (-not $byVar.ContainsKey($e['var'])) { $byVar[$e['var']] = [System.Collections.Generic.List[object]]::new() }
                $byVar[$e['var']].Add($e)
            }
        }
        $pins = Get-OrtWebGpuTestPin
        foreach ($c in @(
                @{ Var = 'ORT_WEBGPU_WINDOWS_DXC_VERSION'; Name = @('dxcompiler.dll', 'dxil.dll', 'onnxruntime'); Spdx = '^NCSA AND LicenseRef-Proprietary-EULA$' }
                @{ Var = 'ORT_WEBGPU_WINDOWS_DAWN_VERSION'; Name = @('Dawn', 'Tint', 'onnxruntime.dll'); Spdx = '^BSD-3-Clause\b' })) {
            Assert-True $pins.Contains($c.Var) "$($c.Var) is a versions.env key"
            $hit = @(if ($byVar.ContainsKey($c.Var)) { $byVar[$c.Var] })
            Assert-Equal 1 $hit.Count "Windows rows with an spdx id versioned by $($c.Var)"
            foreach ($n in $c.Name) { Assert-True ("$($hit[0]['name'])".Contains($n)) "the $($c.Var) row names $n" }
            Assert-Match $c.Spdx "$($hit[0]['spdx'])" "$($c.Var) spdx"
        }
    }
}

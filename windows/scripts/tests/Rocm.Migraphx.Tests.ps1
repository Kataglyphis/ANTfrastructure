#requires -Version 7.0
# rocm-lane MIGraphX spike: WindowsMigraphx.Common, Build-MigraphxFromSource.ps1,
# Build-OrtAmdgpuEpFromSource.ps1, Dockerfile.rocm-migraphx and rocm-checks\MIGraphX.ps1.
# NOT covered: any download, compile or link (the container build), and the load probe itself.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsMigraphx.Common.psm1') -Force -DisableNameChecking

$script:MgxRepo = Get-RepoRoot
$script:MgxDockerfile = Join-Path $script:MgxRepo 'windows\Dockerfile.rocm-migraphx'
$script:MgxScript = 'windows\scripts\build\Build-MigraphxFromSource.ps1'
$script:EpScript = 'windows\scripts\build\Build-OrtAmdgpuEpFromSource.ps1'
$script:MgxCheck = 'windows\scripts\build\rocm-checks\MIGraphX.ps1'

function Get-MgxVersionTable {
    $t = @{}
    $v = ConvertFrom-VersionsEnv -Path (Join-Path $script:MgxRepo 'linux\scripts\01-core\versions.env')
    foreach ($k in $v.Keys) { $t[$k] = $v[$k] }
    return $t
}

# ARG name -> default, backtick continuations joined; BASE_IMAGE and sccache ARGs are lane-shaped.
function Get-MgxDockerfileArg {
    $table = [ordered]@{}
    Select-String -LiteralPath $script:MgxDockerfile -Pattern '^ARG\s+([A-Z][A-Z0-9_]*)=(\S*)' |
        ForEach-Object { $g = $_.Matches[0].Groups; $table[$g[1].Value] = $g[2].Value.Trim('"') }
    return $table
}

Describe 'WindowsMigraphx.Common: lane guard' {
    It 'returns the ROCm root on the rocm lane' {
        $root = Assert-MigraphxRocmLane -GpuEnvironment @{ GpuType = 'rocm'; HasRocm = $true; RocmRoot = 'C:\TheRock\build\' }
        Assert-Equal 'C:\TheRock\build' $root 'trailing separator trimmed'
    }

    It 'refuses the cpu and nvidia lanes, so neither can ever build MIGraphX or the EP' {
        foreach ($type in 'cpu', 'nvidia') {
            $lane = @{ GpuType = $type; HasCuda = ($type -eq 'nvidia'); HasRocm = $false; RocmRoot = 'C:\TheRock\build' }
            Assert-Throws { Assert-MigraphxRocmLane -GpuEnvironment $lane } "lane $type (a stray HIP_PATH must not count)" -MessagePattern 'only on the rocm lane'
        }
        # A Get-GpuEnvironment result from before HasRocm existed must refuse too.
        Assert-Throws { Assert-MigraphxRocmLane -GpuEnvironment @{ GpuType = 'cpu'; HasCuda = $false } } -MessagePattern 'only on the rocm lane'
    }

    It 'refuses a rocm environment without a root' {
        Assert-Throws { Assert-MigraphxRocmLane -GpuEnvironment @{ GpuType = 'rocm'; HasRocm = $true; RocmRoot = '' } } -MessagePattern 'without a RocmRoot'
    }
}

Describe 'WindowsMigraphx.Common: gfx targets' {
    It 'maps the pinned family to explicit targets (never a host probe)' {
        Assert-Equal 'gfx1200;gfx1201' (Get-MigraphxGpuTargetList -GfxFamily 'gfx120X-all') 'gfx120X-all'
        Assert-Equal 'gfx1100;gfx1101;gfx1102;gfx1103' (Get-MigraphxGpuTargetList -GfxFamily 'gfx110X-all') 'gfx110X-all'
        Assert-Equal 'gfx1151' (Get-MigraphxGpuTargetList -GfxFamily 'gfx1151') 'single-target family'
    }

    It 'the versions.env family resolves' {
        $family = (Get-MgxVersionTable)['ROCM_WINDOWS_GFX_FAMILY']
        Assert-Match '^gfx\d' (Get-MigraphxGpuTargetList -GfxFamily $family) "ROCM_WINDOWS_GFX_FAMILY=$family"
    }

    It 'refuses multiarch, empty and look-alikes' {
        foreach ($bad in @('', 'multiarch', 'GFX120X-ALL', 'gfx120X-all;gfx942', 'gfx1154', 'gfx94X-dcgpu')) {
            Assert-Throws { Get-MigraphxGpuTargetList -GfxFamily $bad } "family '$bad'" -MessagePattern 'no gfx target list'
        }
    }
}

Describe 'WindowsMigraphx.Common: AMD LLVM tool paths' {
    It 'returns an absolute forward-slash path under lib\llvm\bin, and throws when absent' {
        Invoke-InTestDir { param($dir)
            $bin = Join-Path $dir 'lib\llvm\bin'
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            Set-Content -LiteralPath (Join-Path $bin 'clang++.exe') -Value 'x'
            $got = Get-RocmLlvmToolPath -RocmRoot $dir -Tool 'clang++'
            Assert-Equal ((Join-Path $bin 'clang++.exe') -replace '\\', '/') $got 'clang++ path'
            Assert-Throws { Get-RocmLlvmToolPath -RocmRoot $dir -Tool 'clang-cl' } -MessagePattern 'not found'
        }
    }
}

Describe 'WindowsMigraphx.Common: pinned sources' {
    $sha = 'A' * 64
    It 'builds the URL from the env pin and lower-cases the SHA' {
        Invoke-WithEnv @{ MGX_T_VERSION = '1.2.3'; MGX_T_SHA256 = $sha; MGX_T_YEAR = '2025' } {
            $s = Resolve-PinnedSource -Name 't' -VersionKey 'MGX_T_VERSION' -ShaKey 'MGX_T_SHA256' -UrlFormat 'https://x/{1}/t-{0}.zip' -ExtraKeys @('MGX_T_YEAR')
            Assert-Equal 'https://x/2025/t-1.2.3.zip' $s.Url 'URL'
            Assert-Equal ('a' * 64) $s.Sha256 'SHA'
            Assert-Equal '1.2.3' $s.Version 'version'
        }
    }

    # One refusal case: the env it runs under and the message it must name.
    function Assert-PinRefused([hashtable]$Env, [string]$Pattern) {
        Invoke-WithEnv $Env {
            Assert-Throws { Resolve-PinnedSource -Name 't' -VersionKey 'MGX_T_VERSION' -ShaKey 'MGX_T_SHA256' -UrlFormat '{0}{1}' -ExtraKeys @('MGX_T_YEAR') } `
                "env $(($Env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')" -MessagePattern $Pattern
        }
    }

    It 'refuses a missing version, a missing extra key, and a path-shaped version' {
        Assert-PinRefused @{ MGX_T_VERSION = $null; MGX_T_SHA256 = $sha; MGX_T_YEAR = '2025' } 'MGX_T_VERSION is not set'
        Assert-PinRefused @{ MGX_T_VERSION = '1'; MGX_T_SHA256 = $sha; MGX_T_YEAR = $null } 'MGX_T_YEAR is not set'
        Assert-PinRefused @{ MGX_T_VERSION = '../evil'; MGX_T_SHA256 = $sha; MGX_T_YEAR = '2025' } 'plain version'
    }

    It 'refuses an empty or malformed SHA256 (an empty pin means "no check" downstream)' {
        foreach ($bad in @($null, '', 'abc', ('g' * 64), ('a' * 63))) {
            Assert-PinRefused @{ MGX_T_VERSION = '1'; MGX_T_SHA256 = $bad; MGX_T_YEAR = '2025' } 'unverified'
        }
    }
}

Describe 'WindowsMigraphx.Common: facts read from fetched trees' {
    It 'reads the MIGraphX version and protobuf''s abseil pin, and throws when upstream moved them' {
        Assert-Equal '2.17.0' (Get-MigraphxTreeFact -Fact MigraphxVersion -CMakeText "include(X)`nrocm_setup_version(VERSION 2.17.0)`n") 'version'
        Assert-Equal '20250512.1' (Get-MigraphxTreeFact -Fact ProtobufAbseil -CMakeText "set(re2-version `"x`")`nset(abseil-cpp-version `"20250512.1`")") 'abseil'
        Assert-Throws { Get-MigraphxTreeFact -Fact MigraphxVersion -CMakeText 'project(x)' } -MessagePattern 'MigraphxVersion not found'
        Assert-Throws { Get-MigraphxTreeFact -Fact ProtobufAbseil -CMakeText '' } -MessagePattern 'ProtobufAbseil not found'
    }

    It 'reads MIGraphX''s own rocm-cmake commit, and refuses a missing pin or one that is not a 40-hex commit' {
        $sha = '6a7c5b73b8882c74f8f7060e2633f230dabb7b63'
        $req = "abseil/abseil-cpp@20250512.0 -DABSL_ENABLE_INSTALL=ON`nROCm/rocm-cmake@$sha --build`nsqlite3@3.50.4"
        Assert-Equal $sha (Get-MigraphxRocmCmakeCommit -RequirementsText $req) 'commit'
        Assert-Throws { Get-MigraphxRocmCmakeCommit -RequirementsText 'google/protobuf@v30.0' } -MessagePattern 'rocm-cmake not found'
        Assert-Throws { Get-MigraphxRocmCmakeCommit -RequirementsText 'ROCm/rocm-cmake@rocm-7.0.0 --build' } -MessagePattern 'not a 40-hex commit'
    }

    It 'Save-GitCommitSource binds only a 40-hex commit, so a branch or tag never reaches git' {
        Assert-Throws { Save-GitCommitSource -Name 'x' -Repository 'https://example.invalid/x.git' -Commit 'develop' -WorkDir 'unused' } `
            -MessagePattern 'Commit'
    }
}

Describe 'Build-MigraphxFromSource.ps1: rocm-cmake' {
    It 'installs MIGraphX''s own rocm-cmake into the deps prefix before MIGraphX configures' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:MgxRepo $script:MgxScript)
        $fetch = $text.IndexOf('Save-GitCommitSource -Name ''rocm-cmake''')
        $configure = $text.IndexOf('3. MIGraphX configure')
        Assert-True ($fetch -gt 0 -and $fetch -lt $configure) 'rocm-cmake is staged in phase 2, before the MIGraphX configure'
        Assert-True ($text -match 'Get-MigraphxRocmCmakeCommit -RequirementsText') 'the commit comes from MIGraphX''s requirements.txt'
        Assert-True ($text -match '-InstallPrefix \$depsPrefix') 'it installs into the deps prefix, which precedes TheRock on CMAKE_PREFIX_PATH'
    }
}

Describe 'WindowsMigraphx.Common: FetchContent seeding' {
    $cmake = @'
FetchContent_Declare(
        fmt
        URL https://example.org/fmt-1.zip
        DOWNLOAD_NO_PROGRESS TRUE)
FetchContent_Declare(range-v3 URL https://example.org/r.zip EXCLUDE_FROM_ALL)
if(USE_DML)
    FetchContent_Declare(
            eigen
            URL https://example.org/eigen.zip)
endif()
FetchContent_Declare(
      absl
      GIT_REPOSITORY "https://github.com/abseil/abseil-cpp.git"
      GIT_TAG "${abseil-cpp-version}"
    )
'@
    $map = Get-FetchContentUrlMap -CMakeText $cmake
    It 'parses URL and git declarations, lower-cased' {
        Assert-Equal 'fmt,range-v3,eigen,absl' (@($map.Keys) -join ',') 'names in order'
        Assert-Equal 'https://example.org/r.zip' $map['range-v3'] 'one-line declaration'
        Assert-Equal 'git:https://github.com/abseil/abseil-cpp.git' $map['absl'] 'git declaration'
    }

    It 'passes when every active declaration has a seed for the same URL' {
        Assert-FetchContentSeeded -Declared $map -Seeded @{ fmt = 'https://example.org/fmt-1.zip'; 'range-v3' = 'https://example.org/r.zip'; absl = 'git:https://github.com/abseil/abseil-cpp.git' } -Inactive @('eigen')
        Assert-True $true 'no throw'
    }

    It 'fails on an unseeded declaration, a URL drift, and an empty scan' {
        Assert-Throws { Assert-FetchContentSeeded -Declared $map -Seeded @{ fmt = 'https://example.org/fmt-1.zip' } -Inactive @('eigen') } -MessagePattern 'range-v3 .* no hash-pinned seed'
        Assert-Throws { Assert-FetchContentSeeded -Declared $map -Seeded @{ fmt = 'https://example.org/fmt-2.zip'; 'range-v3' = 'https://example.org/r.zip'; absl = 'x' } -Inactive @('eigen', 'absl') } -MessagePattern 'fmt is declared as'
        Assert-Throws { Assert-FetchContentSeeded -Declared ([ordered]@{}) -Seeded @{} } -MessagePattern 'would check nothing'
    }

    It 'names the FetchContent source-dir override the way FetchContent upper-cases it' {
        Assert-Equal '-DFETCHCONTENT_SOURCE_DIR_RANGE-V3:PATH=C:/w/range-v3-src/x' (Get-FetchContentSeedArg -Name 'range-v3' -SourceDir 'C:\w\range-v3-src\x') 'range-v3'
    }
}

Describe 'WindowsMigraphx.Common: licence texts' {
    # name:path of every licence file in the pinned archives, listed from them on 2026-09-23.
    $measured = @{
        MigraphxDeps = 'abseil:LICENSE,msgpack:COPYING,msgpack:LICENSE_1_0.txt,msgpack:NOTICE,protobuf:LICENSE,protobuf:third_party\utf8_range\LICENSE'
        OrtAmdgpuEp  = 'absl:LICENSE,flatbuffers:LICENSE,fmt:LICENSE,gsl:LICENSE,onnx:LICENSE,protobuf:LICENSE,protobuf:third_party\utf8_range\LICENSE,range-v3:LICENSE.txt'
    }
    # Fetched but linked into nothing (json is USE_DML only, zlib is off in protobuf), so no text.
    $unlinked = @{ MigraphxDeps = ''; OrtAmdgpuEp = 'json,zlib' }

    # Fetched trees holding every file Get-MigraphxLicenseFile names, plus a TheRock nlohmann header.
    function New-MgxLicenseFixture([string]$Root, [string]$Set) {
        $roots = @{}
        $map = Get-MigraphxLicenseFile -Set $Set
        foreach ($n in $map.Keys) {
            $roots[$n] = Join-Path $Root "src\$n"
            New-Item -ItemType Directory -Force -Path $roots[$n] | Out-Null
            foreach ($r in $map[$n]) { New-Item -ItemType File -Force -Path (Join-Path $roots[$n] $r) -Value "$n $r" | Out-Null }
        }
        $header = "// JSON for Modern C++`n// SPDX-FileCopyrightText: 2013-2023 Niels Lohmann`n// SPDX-License-Identifier: MIT`n`n#ifndef INCLUDE_NLOHMANN_JSON_HPP_`n// a comment inside the code`n"
        New-Item -ItemType File -Force -Path (Join-Path $Root 'rocm\include\nlohmann\json.hpp') -Value $header | Out-Null
        return $roots
    }

    It 'maps exactly the measured licence files, and only for pinned sources that get linked' {
        foreach ($set in 'MigraphxDeps', 'OrtAmdgpuEp') {
            $map = Get-MigraphxLicenseFile -Set $set
            $flat = @(foreach ($n in $map.Keys) { foreach ($r in $map[$n]) { "${n}:$r" } }) | Sort-Object
            Assert-Equal $measured[$set] ($flat -join ',') "$set licence files"
            $specNames = @(Get-MigraphxPinnedSourceSpec -Set $set | ForEach-Object { $_.Name })
            Assert-Equal '' (@($map.Keys | Where-Object { $specNames -notcontains $_ }) -join ',') "$set maps only fetched sources"
            Assert-Equal $unlinked[$set] (@($specNames | Where-Object { -not $map.Contains($_) } | Sort-Object) -join ',') "$set sources without a text"
        }
    }

    It 'lists the own LICENSE, the nlohmann notice (MIGraphX only) and every file under licenses\<name>\<path>' {
        $mgx = @(Get-MigraphxStagedLicensePath -Set MigraphxDeps)
        $ep = @(Get-MigraphxStagedLicensePath -Set OrtAmdgpuEp)
        Assert-True ($mgx -contains 'LICENSE' -and $ep -contains 'LICENSE') 'the component''s own LICENSE'
        Assert-True ($mgx -contains 'licenses\nlohmann_json\NOTICE.txt') 'nlohmann notice beside MIGraphX'
        Assert-False ($ep -contains 'licenses\nlohmann_json\NOTICE.txt') 'the EP does not link nlohmann'
        Assert-True ($ep -contains 'licenses\protobuf\third_party\utf8_range\LICENSE') 'the path is kept, so two LICENSEs of one tree cannot collide'
        Assert-Equal 8 $mgx.Count 'MIGraphX: LICENSE + notice + 6 files'
        Assert-Equal 9 $ep.Count 'EP: LICENSE + 8 files'
    }

    It 'stages every path the gap check asks for; the notice is the header''s leading comment only' {
        Invoke-InTestDir { param($dir)
            foreach ($set in 'MigraphxDeps', 'OrtAmdgpuEp') {
                $install = Join-Path $dir "install-$set"
                $roots = New-MgxLicenseFixture (Join-Path $dir $set) $set
                Assert-Equal @(Get-MigraphxStagedLicensePath -Set $set).Count @(Get-MigraphxLicenseGap -InstallDir $install -Set $set).Count "$set empty install"
                Save-MigraphxLicense -Set $set -SourceRoot $roots -InstallDir $install -RocmRoot (Join-Path $dir "$set\rocm")
                Set-Content -LiteralPath (Join-Path $install 'LICENSE') -Value 'own'
                Assert-Equal '' (@(Get-MigraphxLicenseGap -InstallDir $install -Set $set) -join ',') "$set staged"
            }
            $notice = Get-Content -LiteralPath (Join-Path $dir 'install-MigraphxDeps\licenses\nlohmann_json\NOTICE.txt') -Raw
            Assert-Match 'SPDX-FileCopyrightText: 2013-2023 Niels Lohmann' $notice 'copyright kept'
            Assert-Match 'SPDX-License-Identifier: MIT' $notice 'SPDX id kept'
            Assert-False ($notice -match '#ifndef|inside the code') 'the notice stops at the first line that is not a comment'
        }
    }

    It 'refuses a moved licence file, a missing tree, a missing TheRock root and a header without an SPDX id' {
        Invoke-InTestDir { param($dir)
            $install = Join-Path $dir 'install'
            $rocm = Join-Path $dir 'rocm'
            $roots = New-MgxLicenseFixture $dir 'MigraphxDeps'
            Remove-Item -LiteralPath (Join-Path $roots['protobuf'] 'third_party\utf8_range\LICENSE')
            Assert-Throws { Save-MigraphxLicense -Set MigraphxDeps -SourceRoot $roots -InstallDir $install -RocmRoot $rocm } 'moved file' -MessagePattern 'protobuf: .*utf8_range.*upstream moved'
            $roots = New-MgxLicenseFixture $dir 'MigraphxDeps'
            $partial = $roots.Clone(); $partial.Remove('msgpack')
            Assert-Throws { Save-MigraphxLicense -Set MigraphxDeps -SourceRoot $partial -InstallDir $install -RocmRoot $rocm } 'no tree' -MessagePattern "no fetched tree for 'msgpack'"
            Assert-Throws { Save-MigraphxLicense -Set MigraphxDeps -SourceRoot $roots -InstallDir $install } 'no TheRock' -MessagePattern 'needs -RocmRoot'
            Set-Content -LiteralPath (Join-Path $rocm 'include\nlohmann\json.hpp') -Value "// no licence here`n#pragma once"
            Assert-Throws { Save-MigraphxLicense -Set MigraphxDeps -SourceRoot $roots -InstallDir $install -RocmRoot $rocm } 'no SPDX' -MessagePattern 'no SPDX-License-Identifier'
        }
    }
}

Describe 'the licence texts reach the image and the licence list' {
    foreach ($case in @(@{ Rel = $script:MgxScript; Set = 'MigraphxDeps' }, @{ Rel = $script:EpScript; Set = 'OrtAmdgpuEp' })) {
        It "$(Split-Path $case.Rel -Leaf) stages the $($case.Set) texts and its verify phase fails without them" {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:MgxRepo $case.Rel))
            Assert-Match "Save-MigraphxLicense -Set $($case.Set) " $text 'staged'
            Assert-Match ([regex]::Escape("Get-MigraphxLicenseGap -InstallDir `$InstallDir -Set $($case.Set))")) $text 'verified'
        }
    }

    It 'docs/deps/deps.json has a rocm-only Windows row with an spdx id for everything the spike ships' {
        $deps = Get-Content -LiteralPath (Join-Path $script:MgxRepo 'docs\deps\deps.json') -Raw | ConvertFrom-Json
        $windows = @($deps.sections | Where-Object { $_.title -eq 'Windows Image' })[0]
        $subs = @($windows.subsections | Where-Object { $_.title -match '^MIGraphX.*\(rocm variant only\)$' })
        Assert-Equal 1 $subs.Count 'one rocm-only MIGraphX subsection'
        $rows = @($subs[0].entries | Where-Object { $_.spdx })
        Assert-Equal @($subs[0].entries).Count $rows.Count 'every row has an spdx id'
        $want = @('MIGRAPHX_VERSION', 'ORT_AMDGPU_EP_COMMIT')
        foreach ($set in 'MigraphxDeps', 'OrtAmdgpuEp') {
            $linked = Get-MigraphxLicenseFile -Set $set
            $want += @(Get-MigraphxPinnedSourceSpec -Set $set | Where-Object { $linked.Contains($_.Name) } | ForEach-Object { $_.VersionKey })
        }
        $vars = @($rows | ForEach-Object { $_.var } | Where-Object { $_ })
        Assert-Equal (@($want | Sort-Object) -join ',') (@($vars | Sort-Object) -join ',') 'row pins = the linked set, nothing more'
        Assert-Equal 1 @($rows | Where-Object { $_.name -match '^nlohmann/json' -and -not $_.var }).Count 'TheRock''s nlohmann/json has a row'
    }
}

Describe 'Build-MigraphxFromSource.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:MgxScript -FunctionName @(
            'Get-MigraphxDepCmakeArgs', 'Get-MigraphxCmakeArgs', 'Get-MigraphxInstallGap'))

    It 'every dep pin exists in versions.env and resolves to the upstream archive measured for it' {
        $table = Get-MgxVersionTable
        $expected = @{
            abseil   = 'https://github.com/abseil/abseil-cpp/archive/refs/tags/20250512.0.tar.gz'
            protobuf = 'https://github.com/protocolbuffers/protobuf/releases/download/v30.0/protobuf-30.0.tar.gz'
            msgpack  = 'https://github.com/msgpack/msgpack-c/releases/download/cpp-3.3.0/msgpack-3.3.0.tar.gz'
            sqlite   = 'https://www.sqlite.org/2025/sqlite-amalgamation-3500400.zip'
        }
        $specs = @(Get-MigraphxPinnedSourceSpec -Set MigraphxDeps)
        Assert-Equal 'abseil,msgpack,protobuf,sqlite' (@($specs | ForEach-Object { $_.Name } | Sort-Object) -join ',') 'dep set'
        # Every digit in a URL template must come from versions.env: none may be hardcoded.
        foreach ($s in @($specs) + @(Get-MigraphxPinnedSourceSpec -Set OrtAmdgpuEp)) {
            Assert-False (($s.UrlFormat -replace '\{\d\}', '' -replace 'range-v3', '') -match '\d') "$($s.Name) URL template hardcodes a version: $($s.UrlFormat)"
        }
        foreach ($spec in $specs) {
            $env_ = @{}
            foreach ($k in @($spec.VersionKey, $spec.ShaKey) + @(if ($spec.ContainsKey('ExtraKeys')) { $spec.ExtraKeys })) { $env_[$k] = $table[$k] }
            Invoke-WithEnv $env_ { Assert-Equal $expected[$spec.Name] (Resolve-PinnedSource @spec).Url "$($spec.Name) URL" }
        }
    }

    It 'dep builds are static, /MD and offline' {
        foreach ($name in 'abseil', 'protobuf', 'msgpack', 'sqlite') {
            $a = @(Get-MigraphxDepCmakeArgs -Name $name -DepsPrefix 'C:\w\deps') -join ' '
            Assert-Match 'BUILD_SHARED_LIBS:BOOL=OFF' $a "$name static"
            Assert-Match 'CMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL' $a "$name /MD"
            Assert-Match 'FETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON' $a "$name offline"
            Assert-Match 'CMAKE_PREFIX_PATH:STRING=C:/w/deps' $a "$name finds earlier deps"
        }
        Assert-Match 'protobuf_LOCAL_DEPENDENCIES_ONLY=ON' (@(Get-MigraphxDepCmakeArgs -Name 'protobuf' -DepsPrefix 'C:\d') -join ' ') 'protobuf never fetches abseil'
        Assert-Throws { Get-MigraphxDepCmakeArgs -Name 'eigen' -DepsPrefix 'C:\d' } -MessagePattern 'no configure args'
    }

    It 'configures GPU on, MLIR/CK/Python/TF off, explicit targets, AMD tools by absolute path' {
        Invoke-InTestDir { param($dir)
            $bin = Join-Path $dir 'lib\llvm\bin'
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            foreach ($t in 'llvm-ar', 'llvm-ranlib', 'llvm-objcopy', 'clang-offload-bundler', 'llvm-readobj') { Set-Content -LiteralPath (Join-Path $bin "$t.exe") -Value 'x' }
            $a = @(Get-MigraphxCmakeArgs -RocmRoot $dir -DepsPrefix 'C:\w\deps' -GpuTargets 'gfx1200;gfx1201' -Python 'C:\py\python.exe')
            $joined = $a -join ' '
            foreach ($want in '-DMIGRAPHX_ENABLE_GPU=ON', '-DMIGRAPHX_ENABLE_MLIR=OFF', '-DMIGRAPHX_USE_COMPOSABLEKERNEL=OFF',
                '-DMIGRAPHX_ENABLE_PYTHON=OFF', '-DMIGRAPHX_ENABLE_TENSORFLOW=OFF', '-DBUILD_DEV=OFF', '-DGPU_TARGETS:STRING=gfx1200;gfx1201',
                '-DMIGRAPHX_USE_AMDMLSS=OFF', '-DCMAKE_MSVC_RUNTIME_LIBRARY:STRING=MultiThreadedDLL', '-DSQLite3_LIBRARY:FILEPATH=C:/w/deps/lib/sqlite3.lib') {
                Assert-True ($a -contains $want) "missing $want"
            }
            $rocm = $dir -replace '\\', '/'
            Assert-True ($a -contains "-DCMAKE_AR:FILEPATH=$rocm/lib/llvm/bin/llvm-ar.exe") 'AMD llvm-ar, never llvm-lib'
            Assert-True ($a -contains "-DCLANG_OFFLOAD_BUNDLER:FILEPATH=$rocm/lib/llvm/bin/clang-offload-bundler.exe") 'AMD bundler for the offload-arch check'
            Assert-True ($a -contains "-DCMAKE_PREFIX_PATH:STRING=C:/w/deps;$rocm") 'deps first, then TheRock'
            Assert-True ($a -contains "-Dnlohmann_json_DIR:PATH=$rocm/share/cmake/nlohmann_json") 'TheRock''s nlohmann/json, the copy whose notice is staged'
            Assert-False ($joined -match 'CMAKE_(C|CXX)_COMPILER=') 'compilers are passed to Invoke-CmakeConfigure, not here'
        }
    }

    It 'names every missing install piece' {
        Invoke-InTestDir { param($dir)
            Assert-Equal 10 @(Get-MigraphxInstallGap -InstallDir $dir).Count 'empty prefix'
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'bin') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'bin\migraphx.dll') -Value 'x'
            Assert-False (@(Get-MigraphxInstallGap -InstallDir $dir) -contains 'bin\migraphx.dll') 'present file not reported'
        }
    }
}

Describe 'Build-OrtAmdgpuEpFromSource.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:EpScript -FunctionName @(
            'Get-OrtAmdgpuEpCmakeArgs', 'Get-OrtAmdgpuEpStageGap'))

    It 'the versions.env pins rebuild exactly the URLs the pinned EP commit declares' {
        # src/CMakeLists.txt at ORT_AMDGPU_EP_COMMIT (99ab5cb), non-DML declarations, verbatim.
        $declared = [ordered]@{
            fmt           = 'https://github.com/fmtlib/fmt/releases/download/12.1.0/fmt-12.1.0.zip'
            gsl           = 'https://github.com/microsoft/GSL/archive/refs/tags/v4.2.1.zip'
            json          = 'https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz'
            zlib          = 'https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz'
            protobuf      = 'https://github.com/protocolbuffers/protobuf/archive/refs/tags/v34.1.zip'
            onnx          = 'https://github.com/onnx/onnx/archive/refs/tags/v1.21.0.zip'
            flatbuffers   = 'https://github.com/google/flatbuffers/archive/refs/tags/v25.12.19.zip'
            'range-v3'    = 'https://github.com/ericniebler/range-v3/archive/refs/tags/0.12.0.zip'
        }
        $table = Get-MgxVersionTable
        Assert-Equal '99ab5cb43caa421e0b19870fa4ce9323117e5e56' $table['ORT_AMDGPU_EP_COMMIT'] 'the URLs above belong to this commit; re-derive them with a bump'
        $seeded = @{}
        foreach ($spec in @(Get-MigraphxPinnedSourceSpec -Set OrtAmdgpuEp)) {
            Invoke-WithEnv @{ ($spec.VersionKey) = $table[$spec.VersionKey]; ($spec.ShaKey) = $table[$spec.ShaKey] } {
                $seeded[$spec.Name] = (Resolve-PinnedSource @spec).Url
            }
        }
        Assert-Equal 'https://github.com/abseil/abseil-cpp/archive/refs/tags/20250512.1.tar.gz' $seeded['absl'] 'protobuf v34.1 abseil'
        $seeded.Remove('absl')
        Assert-FetchContentSeeded -Declared $declared -Seeded $seeded
        Assert-Equal 8 $seeded.Count 'no extra seeds'
    }

    It 'configures MIGraphX only, offline, with explicit targets and the seeds appended' {
        $a = @(Get-OrtAmdgpuEpCmakeArgs -MigraphxDir 'C:\runtime\lib\migraphx' -RocmRoot 'C:\TheRock\build' `
                -OrtCmakeDir 'C:\ort\lib\cmake\onnxruntime' -GpuTargets 'gfx1200;gfx1201' -Python 'C:\py\python.exe' -SeedArgs @('-DSEED=1'))
        foreach ($want in '-DUSE_MIGRAPHX=ON', '-DUSE_AMDGPU=OFF', '-DUSE_DML=OFF', '-DUSE_HIP=OFF', '-DGPU_TARGETS:STRING=gfx1200;gfx1201',
            '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON', '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW', '-Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON',
            '-Donnxruntime_DIR:PATH=C:/ort/lib/cmake/onnxruntime', '-DCMAKE_PREFIX_PATH:STRING=C:/runtime/lib/migraphx;C:/TheRock/build') {
            Assert-True ($a -contains $want) "missing $want"
        }
        Assert-Equal '-DSEED=1' $a[-1] 'seeds last'
    }

    It 'stages amdhip64, comgr and hiprtc but leaves rocm_kpack and the math libraries in HIP_PATH' {
        Invoke-InTestDir { param($dir)
            foreach ($n in 'amdhip64_7.dll', 'amd_comgr.dll', 'amd_comgr0715.dll', 'hiprtc0715.dll', 'hiprtc-builtins0715.dll',
                'rocm_kpack.dll', 'MIOpen.dll', 'rocblas.dll', 'hiprtc0715.pdb', 'amdhip64.lib') { Set-Content -LiteralPath (Join-Path $dir $n) -Value 'x' }
            $names = @(Get-MigraphxHipRuntimeFile -RocmBin $dir | ForEach-Object Name) -join ','
            Assert-Equal 'amd_comgr.dll,amd_comgr0715.dll,amdhip64_7.dll,hiprtc-builtins0715.dll,hiprtc0715.dll' $names 'HIP runtime set'
        }
    }

    It 'names what is missing beside migraphx-ep.dll' {
        Invoke-InTestDir { param($dir)
            $gap = @(Get-OrtAmdgpuEpStageGap -EpDir $dir -HipRuntimeName @('amdhip64_7.dll'))
            Assert-True ($gap -contains 'migraphx-ep.dll') 'EP'
            Assert-True ($gap -contains 'amdhip64_7.dll') 'HIP runtime'
            Assert-Equal 8 $gap.Count 'everything missing'
        }
    }
}

Describe 'both scripts refuse off the rocm lane before fetching anything' {
    It 'the shared preamble guards with Get-GpuEnvironment' {
        $def = (Get-Command Initialize-MigraphxBuild).Definition
        Assert-Match 'Assert-MigraphxRocmLane -GpuEnvironment \(Get-GpuEnvironment\)' $def 'guard inside the preamble'
    }
    foreach ($rel in @($script:MgxScript, $script:EpScript)) {
        It "$(Split-Path $rel -Leaf): the preamble runs before the first download" {
            # Script-local functions never name either command, so text order is call order.
            $text = [System.IO.File]::ReadAllText((Join-Path $script:MgxRepo $rel))
            $guard = $text.IndexOf('= Initialize-MigraphxBuild ')
            $fetch = $text.IndexOf('Save-PinnedSource ')
            Assert-True ($guard -gt 0 -and $fetch -gt 0) "both calls present (guard $guard, fetch $fetch)"
            Assert-True ($guard -lt $fetch) 'the lane guard runs before any download'
        }
    }
}

Describe 'Dockerfile.rocm-migraphx' {
    It 'declares an ARG for every forwarded pin, with the versions.env value as default' {
        $table = Get-MgxVersionTable
        $forwarded = Get-MediaBranchVersionArg -Branch 'rocm-migraphx' -VersionTable $table
        $declared = Get-MgxDockerfileArg
        $pins = @($declared.Keys | Where-Object { $_ -ne 'BASE_IMAGE' -and $_ -notlike 'SCCACHE_*' })
        Assert-Equal (@($forwarded.Keys | Sort-Object) -join ',') (@($pins | Sort-Object) -join ',') 'forwarded keys = declared pin ARGs'
        foreach ($k in $pins) { Assert-Equal "$($table[$k])" $declared[$k] "ARG $k default" }
        Assert-True ($pins.Count -ge 20) "only $($pins.Count) pin ARGs parsed - the scan broke"
    }

    It 'declares the EP pins after the MIGraphX RUN, so an EP bump never re-runs that compile' {
        $text = [System.IO.File]::ReadAllText($script:MgxDockerfile)
        $mgxRun = $text.IndexOf('Build-MigraphxFromSource.ps1')
        Assert-True ($mgxRun -gt 0) 'MIGraphX RUN found'
        foreach ($m in [regex]::Matches($text, '(?m)^ARG\s+(ORT_AMDGPU_EP_\w+)=')) {
            Assert-True ($m.Index -gt $mgxRun) "$($m.Groups[1].Value) is declared before the MIGraphX RUN"
        }
        foreach ($m in [regex]::Matches($text, '(?m)^ARG\s+(MIGRAPHX_\w+|ROCM_WINDOWS_GFX_FAMILY)=')) {
            Assert-True ($m.Index -lt $mgxRun) "$($m.Groups[1].Value) is declared after the RUN that reads it"
        }
    }

    It 'mounts both scripts with the media lane''s buildmods closure plus the leaf, and sets the rocm-check markers' {
        # BuildKit.ModuleClosure.Tests.ps1 proves media-builder's buildmods is WindowsSourceBuild.Common's closure.
        $bkmodsOf = { param($path)
            $j = ([System.IO.File]::ReadAllText($path)) -replace '`\r?\n', ' '
            # The COPY that carries SourceBuild.Common: buildmods there, migraphxmods here (not tvmmods).
            @($j -split "`n" | Where-Object { $_ -match '^COPY\s.*WindowsSourceBuild\.Common.*bkmods' } | ForEach-Object {
                    [regex]::Matches($_, 'modules\\([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value } })
        }
        $mine = & $bkmodsOf $script:MgxDockerfile
        $media = & $bkmodsOf (Join-Path $script:MgxRepo 'windows\Dockerfile.media-builder')
        Assert-True ($media -contains 'WindowsSourceBuild.Common') 'media-builder buildmods parsed'
        Assert-Equal '' (@(@($media) + 'WindowsMigraphx.Common' | Sort-Object -Unique | Where-Object { $mine -notcontains $_ }) -join ',') 'missing from migraphxmods'
        $leaf = [System.IO.File]::ReadAllText((Join-Path $script:MgxRepo 'windows\scripts\modules\WindowsMigraphx.Common.psm1'))
        $leafImports = @([regex]::Matches($leaf, "PSScriptRoot\s+'([A-Za-z0-9._]+)\.psm1'") | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal '' (@($leafImports | Where-Object { $media -notcontains $_ }) -join ',') 'the leaf imports only buildmods modules'
        $joined = ([System.IO.File]::ReadAllText($script:MgxDockerfile)) -replace '`\r?\n', ' '
        foreach ($rel in @($script:MgxScript, $script:EpScript)) {
            Assert-Match ([regex]::Escape("source=$($rel -replace '\\', '/'),")) $joined "$rel is mounted"
            $imports = @([regex]::Matches([System.IO.File]::ReadAllText((Join-Path $script:MgxRepo $rel)), 'modules\\([A-Za-z0-9._]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
            Assert-Equal 'WindowsMigraphx.Common,WindowsSourceBuild.Common' (@($imports | Sort-Object -Unique) -join ',') "$rel imports"
        }
        Assert-Match 'MIGRAPHX_ROOT="C:\\runtime\\lib\\migraphx"' $joined 'MIGRAPHX_ROOT marker'
        Assert-Match 'ORT_AMDGPU_EP_ROOT="C:\\runtime\\lib\\onnxruntime-ep-amdgpu"' $joined 'EP marker'
    }
}

Describe 'cpu and nvidia inputs are untouched by the spike' {
    It 'no other Windows Dockerfile names the spike''s scripts, module or pins' {
        $hits = @(Get-ChildItem -Path (Join-Path $script:MgxRepo 'windows') -Filter 'Dockerfile*' -File |
            Where-Object { $_.Name -ne 'Dockerfile.rocm-migraphx' } |
            Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'Build-MigraphxFromSource|Build-OrtAmdgpuEpFromSource|WindowsMigraphx\.Common|MIGRAPHX_WINDOWS_|ORT_AMDGPU_EP_' } |
            ForEach-Object Name)
        Assert-Equal '' ($hits -join ',') 'a media/torch/final Dockerfile would re-key cpu and nvidia'
    }

    It 'the three media branches forward none of the spike''s pins' {
        $table = Get-MgxVersionTable
        foreach ($branch in 'media-core', 'media-litert', 'media-tvm') {
            $keys = @((Get-MediaBranchVersionArg -Branch $branch -VersionTable $table).Keys | Where-Object { $_ -match '^(MIGRAPHX_|ORT_AMDGPU_EP_)' })
            Assert-Equal '' ($keys -join ',') "$branch build-args"
        }
        $merge = @((Get-MediaMergeVersionArg -VersionTable $table).Keys | Where-Object { $_ -match '^(MIGRAPHX_|ORT_AMDGPU_EP_)' })
        Assert-Equal '' ($merge -join ',') 'merge build-args'
    }

    It 'the rocm-migraphx map throws on a table without its pins' {
        Assert-Throws { Get-MediaBranchVersionArg -Branch 'rocm-migraphx' -VersionTable @{ ROCM_WINDOWS_GFX_FAMILY = 'x' } } -MessagePattern 'MIGRAPHX_VERSION'
    }
}

Describe 'rocm-checks\MIGraphX.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:MgxCheck -FunctionName @(
            'Get-MigraphxCheckInstallFinding', 'Get-MigraphxCheckLicenseFinding', 'Get-MigraphxCheckHipSidecarFinding', 'Get-MigraphxCheckImportFinding',
            'ConvertTo-MigraphxLoadFinding'))

    It 'reports every missing binary of both trees, and nothing on a complete one' {
        Invoke-InTestDir { param($dir)
            $mgx = Join-Path $dir 'mgx'; $ep = Join-Path $dir 'ep'
            Assert-Equal 15 @(Get-MigraphxCheckInstallFinding -MigraphxRoot $mgx -EpRoot $ep).Count 'nothing installed'
            foreach ($rel in 'bin\migraphx.dll', 'bin\migraphx_c.dll', 'bin\migraphx_gpu.dll', 'bin\migraphx_device.dll', 'bin\migraphx_onnx.dll',
                'bin\migraphx-hiprtc-driver.exe', 'bin\migraphx-driver.exe', 'lib\cmake\migraphx\migraphx-config.cmake') {
                New-Item -ItemType File -Force -Path (Join-Path $mgx $rel) | Out-Null
            }
            foreach ($n in 'migraphx-ep.dll', 'migraphx.dll', 'migraphx_c.dll', 'migraphx_gpu.dll', 'migraphx_device.dll', 'migraphx_onnx.dll', 'migraphx-hiprtc-driver.exe') {
                New-Item -ItemType File -Force -Path (Join-Path $ep $n) | Out-Null
            }
            Assert-Equal 0 @(Get-MigraphxCheckInstallFinding -MigraphxRoot $mgx -EpRoot $ep).Count 'complete'
        }
    }

    It 'reports every missing licence text of both trees, nothing once staged, and runs after the install gate' {
        Invoke-InTestDir { param($dir)
            $mgx = Join-Path $dir 'mgx'; $ep = Join-Path $dir 'ep'
            $all = @(Get-MigraphxStagedLicensePath -Set MigraphxDeps).Count + @(Get-MigraphxStagedLicensePath -Set OrtAmdgpuEp).Count
            Assert-Equal $all @(Get-MigraphxCheckLicenseFinding -MigraphxRoot $mgx -EpRoot $ep).Count 'nothing staged'
            foreach ($t in @(@{ Root = $mgx; Set = 'MigraphxDeps' }, @{ Root = $ep; Set = 'OrtAmdgpuEp' })) {
                foreach ($rel in Get-MigraphxStagedLicensePath -Set $t.Set) { New-Item -ItemType File -Force -Path (Join-Path $t.Root $rel) | Out-Null }
            }
            Assert-Equal 0 @(Get-MigraphxCheckLicenseFinding -MigraphxRoot $mgx -EpRoot $ep).Count 'all staged'
            Remove-Item -LiteralPath (Join-Path $ep 'licenses\absl\LICENSE')
            Assert-Match 'licenses\\absl\\LICENSE is missing' (@(Get-MigraphxCheckLicenseFinding -MigraphxRoot $mgx -EpRoot $ep) -join '|') 'one text gone'
        }
        $text = [System.IO.File]::ReadAllText((Join-Path $script:MgxRepo $script:MgxCheck))
        Assert-Match '(?m)^Get-MigraphxCheckLicenseFinding -MigraphxRoot \$env:MIGRAPHX_ROOT -EpRoot \$epRoot' $text 'called at script level'
    }

    # $Files maps 'rocm'/'ep' to the names written there (content = the name, so sizes differ per file).
    function New-MgxCheckFixture([string]$Root, [hashtable]$Files) {
        foreach ($side in 'rocm', 'ep') {
            $d = Join-Path $Root $side
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            foreach ($n in @($Files[$side])) { if ($n) { Set-Content -LiteralPath (Join-Path $d $n) -Value $n } }
        }
        return @{ Rocm = (Join-Path $Root 'rocm'); Ep = (Join-Path $Root 'ep') }
    }

    It 'wants TheRock''s HIP runtime set beside the EP, byte-for-byte' {
        Invoke-InTestDir { param($dir)
            $hipSet = @('amdhip64_7.dll', 'amd_comgr.dll', 'hiprtc0715.dll')
            $f = New-MgxCheckFixture $dir @{ rocm = $hipSet + 'rocm_kpack.dll' }
            Assert-Equal 3 @(Get-MigraphxCheckHipSidecarFinding -RocmBin $f.Rocm -EpRoot $f.Ep).Count 'three missing (rocm_kpack is not part of the set)'
            $f = New-MgxCheckFixture $dir @{ ep = $hipSet }
            Assert-Equal 0 @(Get-MigraphxCheckHipSidecarFinding -RocmBin $f.Rocm -EpRoot $f.Ep).Count 'identical copies'
            Add-Content -LiteralPath (Join-Path $f.Ep 'amd_comgr.dll') -Value 'a different build'
            Assert-Match 'amd_comgr.dll differs' (@(Get-MigraphxCheckHipSidecarFinding -RocmBin $f.Rocm -EpRoot $f.Ep) -join '|') 'size drift'
        }
    }

    It 'resolves imports beside the PE and in the search dirs, skips API sets, and flags a static HIP import' {
        Invoke-InTestDir { param($dir)
            $f = New-MgxCheckFixture $dir @{ ep = @('migraphx_c.dll', 'migraphx-ep.dll'); rocm = @('MIOpen.dll') }
            $pe = Join-Path $f.Ep 'migraphx-ep.dll'
            $reader = { param([string]$Path) @('migraphx_c.dll', 'MIOpen.dll', 'api-ms-win-crt-heap-l1-1-0.dll', 'ghost.dll', 'amdhip64_7.dll') }
            $got = @(Get-MigraphxCheckImportFinding -Path $pe -SearchDir @($f.Rocm) -ReadImports $reader -HipDelayOnly)
            Assert-Equal 'ghost|statically' (($got | ForEach-Object { if ($_ -match 'ghost') { 'ghost' } elseif ($_ -match 'amdhip64_7\.dll statically') { 'statically' } }) -join '|') 'unresolved + static HIP'
            Assert-Equal 2 @(Get-MigraphxCheckImportFinding -Path $pe -SearchDir @($f.Rocm) -ReadImports $reader).Count 'without -HipDelayOnly amdhip64 only has to resolve (it does not here)'
        }
    }

    It 'turns the load probe''s exit codes into findings' {
        Assert-Null (ConvertTo-MigraphxLoadFinding -ExitCode 0) 'loaded'
        Assert-Match 'hung' (ConvertTo-MigraphxLoadFinding -ExitCode $null) 'timeout'
        Assert-Match 'did not load \(Win32 error 126' (ConvertTo-MigraphxLoadFinding -ExitCode 3 -Output 'Win32 error 126') 'load failure'
        Assert-Match 'CreateEpFactories' (ConvertTo-MigraphxLoadFinding -ExitCode 4) 'export'
        Assert-Match 'started the HIP runtime' (ConvertTo-MigraphxLoadFinding -ExitCode 5 -Output 'C:\x\amdhip64_7.dll') 'HIP loaded'
        Assert-Match 'exited 9' (ConvertTo-MigraphxLoadFinding -ExitCode 9) 'other'
    }

    It 'is silent on an image built with -NoRocmSpikes, and loud on one that claims MIGraphX but lacks it' {
        $check = Join-Path $script:MgxRepo $script:MgxCheck
        Invoke-WithEnv @{ MIGRAPHX_ROOT = $null } { Assert-Equal 0 @(& $check 6>$null).Count 'no MIGRAPHX_ROOT' }
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ MIGRAPHX_ROOT = (Join-Path $dir 'mgx'); ORT_AMDGPU_EP_ROOT = (Join-Path $dir 'ep'); HIP_PATH = $dir } {
                $got = @(& $check 6>$null)
                Assert-Equal 15 $got.Count 'every missing file reported, then it stops'
            }
        }
    }
}

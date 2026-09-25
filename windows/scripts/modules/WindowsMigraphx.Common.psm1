#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# rocm-lane helpers shared by Build-MigraphxFromSource.ps1 and Build-OrtAmdgpuEpFromSource.ps1:
# lane guard, AMD LLVM tool paths, gfx targets, hash-pinned sources, licence texts. docs/windows-builds.md § ROCm layer.

Set-StrictMode -Version Latest

# Guarded, never -Force: a forced nested import unloads the caller's top-level copy.
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath -DisableNameChecking }
$sourceBuildPath = Join-Path $PSScriptRoot 'WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name 'WindowsSourceBuild.Common')) { Import-Module $sourceBuildPath -DisableNameChecking }

function Assert-MigraphxRocmLane {
    <#
    .SYNOPSIS
        Returns the ROCm root; throws unless Get-GpuEnvironment says this is the rocm lane.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$GpuEnvironment,
        [string]$Component = 'MIGraphX'
    )
    if (-not $GpuEnvironment['HasRocm']) {
        throw ("$Component builds only on the rocm lane (Build-Buildkit.ps1 -Variant rocm); " +
               "GPU_TYPE resolved to '$($GpuEnvironment['GpuType'])'. Refusing, so no other lane ever carries it.")
    }
    $root = "$($GpuEnvironment['RocmRoot'])".TrimEnd('\', '/')
    if (-not $root) { throw "$Component`: Get-GpuEnvironment reported HasRocm without a RocmRoot" }
    return $root
}

function Get-MigraphxGpuTargetList {
    <#
    .SYNOPSIS
        The gfx targets a TheRock family carries, ';'-joined; never a host probe (no GPU at build time).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$GfxFamily)
    # Membership from TheRock cmake/therock_amdgpu_targets.cmake; case-sensitive like its tarball names.
    switch -CaseSensitive -Regex ($GfxFamily) {
        '^gfx120X-all$' { return 'gfx1200;gfx1201' }
        '^gfx110X-all$' { return 'gfx1100;gfx1101;gfx1102;gfx1103' }
        '^gfx103X-all$' { return 'gfx1030;gfx1031;gfx1032;gfx1033;gfx1034;gfx1035;gfx1036' }
        '^gfx115[0-3]$' { return $GfxFamily }
    }
    throw ("ROCM_WINDOWS_GFX_FAMILY '$GfxFamily' has no gfx target list for MIGraphX " +
           '(known: gfx120X-all, gfx110X-all, gfx103X-all, gfx1150-gfx1153; multiarch needs an explicit list)')
}

function Get-MigraphxHipRuntimeFile {
    <#
    .SYNOPSIS
        TheRock's HIP runtime set that sits beside migraphx-ep.dll: amdhip64 (delay-loaded), comgr, hiprtc.
    .DESCRIPTION
        rocm_kpack.dll stays in HIP_PATH\bin, where it finds its .kpack payload. One owner for the
        build that stages the set and the rocm-check that verifies it.
    #>
    param([Parameter(Mandatory)][string]$RocmBin)
    return @(Get-ChildItem -LiteralPath $RocmBin -File -Filter '*.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(amdhip64_\d+|amd_comgr[0-9_]*|hiprtc(-builtins)?\d+)\.dll$' } | Sort-Object Name)
}

function Initialize-MigraphxBuild {
    <#
    .SYNOPSIS
        Shared preamble of both builds: versions, the rocm-lane guard, amd64 only, the gfx targets.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$Component
    )
    $resolvedInstall = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $ScriptRoot
    $rocmRoot = Assert-MigraphxRocmLane -GpuEnvironment (Get-GpuEnvironment) -Component $Component
    $arch = Get-WindowsTargetArch
    if ($arch -ne 'amd64') { throw "$Component is amd64-only (TheRock ships no Windows arm64); got $arch" }
    return [pscustomobject]@{
        InstallDir = $resolvedInstall
        RocmRoot   = $rocmRoot
        GpuTargets = (Get-MigraphxGpuTargetList -GfxFamily "$env:ROCM_WINDOWS_GFX_FAMILY")
    }
}

function Get-RocmLlvmToolPath {
    <#
    .SYNOPSIS
        Absolute, forward-slash path of an AMD LLVM tool; lib\llvm\bin never goes on PATH (Dockerfile.rocm).
    #>
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string]$Tool
    )
    $path = Join-Path $RocmRoot "lib\llvm\bin\$Tool.exe"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "AMD LLVM tool $Tool.exe not found at $path (TheRock layout moved?)" }
    return ($path -replace '\\', '/')
}

function Resolve-PinnedSource {
    <#
    .SYNOPSIS
        Reads a version (or commit) and its SHA256 from the environment and builds the download URL.
    .DESCRIPTION
        Throws naming the key when either is empty: Invoke-DownloadWithRetry treats an empty
        -ExpectedSha256 as "no check", so a missing pin must never reach it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VersionKey,
        [Parameter(Mandatory)][string]$ShaKey,
        [Parameter(Mandatory)][string]$UrlFormat,
        # Extra {1}.. format values read from these keys (sqlite's release year).
        [string[]]$ExtraKeys = @()
    )
    $values = @()
    foreach ($key in @($VersionKey) + $ExtraKeys) {
        $v = "$([Environment]::GetEnvironmentVariable($key))".Trim()
        if (-not $v) { throw "$key is not set (stale versions.env, or the Dockerfile ARG is missing) - refusing to fetch $Name unpinned" }
        if ($v -notmatch '^[A-Za-z0-9._-]+$') { throw "$key='$v' is not a plain version/commit token" }
        $values += $v
    }
    $sha = "$([Environment]::GetEnvironmentVariable($ShaKey))".Trim()
    if ($sha -notmatch '^[0-9A-Fa-f]{64}$') { throw "$ShaKey='$sha' is not a 64-hex SHA256 - refusing to fetch $Name unverified" }
    return [pscustomobject]@{
        Name    = $Name
        Version = $values[0]
        Sha256  = $sha.ToLowerInvariant()
        Url     = ($UrlFormat -f $values)
    }
}

function Get-SevenZipSkippedLink {
    <#
    .SYNOPSIS
        The in-archive links one 7-Zip extraction refused as dangerous; throws on any other failure.
    .DESCRIPTION
        7-Zip 25+ refuses every symlink whose target climbs with '..', even one that stays inside the
        tree, and exits 2: flatbuffers 25.12.19 carries nine (Java test dirs, ts/package.json), none of
        them read by a C++ build. A refused link is never written, so nothing lands outside the
        destination. Any other ERROR line, another exit code or an exit 2 without ERROR lines throws.
    #>
    param(
        # 7-Zip prints blank lines.
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Archive
    )
    if ($ExitCode -eq 0) { return }
    $errors = @($Output -match '^ERROR: ')
    $links = @($errors -match '^ERROR: Dangerous link path was ignored : ' | ForEach-Object { ($_ -split ' : ')[1] })
    if ($ExitCode -ne 2 -or $errors.Count -eq 0 -or $links.Count -ne $errors.Count) {
        $why = if ($errors.Count) { $errors } else { $Output | Select-Object -Last 5 }
        throw "7z extraction of '$Archive' failed (exit $ExitCode): $($why -join '; ')"
    }
    return $links
}

function Expand-PinnedArchive {
    <#
    .SYNOPSIS
        Expand-SourceTarball's two 7-Zip passes, except that links 7-Zip refuses as dangerous are skipped.
    .DESCRIPTION
        Get-SevenZipSkippedLink grades each pass. The intermediate .tar is deleted once unpacked: the EP's
        onnxruntime-ep-amdgpu.tar is an ONNX Runtime archive by name, which G2 refuses to find in the tree.
        This lives here, not in Expand-SourceTarball, because WindowsSourceBuild.Common is mounted into
        every media layer; fold it in at the next deliberate media rebuild. Returns the extracted source root.
    #>
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )
    $skipped = @()
    # A .tar.gz yields a .tar on the first pass, and its entries on the second.
    foreach ($pass in 1, 2) {
        $from = if ($pass -eq 1) { $Archive } else { Get-ChildItem -Path $Destination -Filter '*.tar' | Select-Object -First 1 -ExpandProperty FullName }
        if (-not $from) { break }
        $out = @(& 7z x "$from" -o"$Destination" -y -bd 2>&1 | ForEach-Object { "$_" })
        $skipped += @(Get-SevenZipSkippedLink -Output $out -ExitCode $LASTEXITCODE -Archive $from)
        if ($pass -eq 2) { Remove-Item -LiteralPath $from -Force }
    }
    if ($skipped.Count) { Write-Warning "7-Zip left $($skipped.Count) in-tree link(s) of $(Split-Path $Archive -Leaf) unextracted: $($skipped -join ', ')" }
    $root = Get-ChildItem -Path $Destination -Directory | Select-Object -First 1 -ExpandProperty FullName
    if (-not $root) { throw "Failed to locate extracted source directory under $Destination" }
    return $root
}

function Save-PinnedSource {
    <#
    .SYNOPSIS
        Downloads a Resolve-PinnedSource result, verifies its SHA256, extracts it fresh; returns the source root.
    #>
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$WorkDir
    )
    $ext = if ($Source.Url -match '(\.tar\.gz|\.tar\.xz|\.zip)$') { $Matches[1] } else { throw "unknown archive type: $($Source.Url)" }
    $archive = Join-Path $WorkDir "$($Source.Name)$ext"
    $dest = Join-Path $WorkDir "$($Source.Name)-src"
    Reset-SourceBuildDirectory -Path $dest
    Invoke-DownloadWithRetry -Url $Source.Url -DestinationPath $archive -Description "$($Source.Name) $($Source.Version)" `
        -ExpectedSha256 $Source.Sha256
    $root = Expand-PinnedArchive -Archive $archive -Destination $dest
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Write-Host "Staged $($Source.Name) $($Source.Version) (sha256 $($Source.Sha256.Substring(0, 12))...) at $root"
    return $root
}

function Get-FetchContentUrlMap {
    <#
    .SYNOPSIS
        FetchContent_Declare(<name> URL <url>) pairs of a CMake file, lower-cased name -> URL ('git:<repo>' for GIT_REPOSITORY).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CMakeText)
    $map = [ordered]@{}
    $pattern = '(?is)FetchContent_Declare\(\s*([A-Za-z0-9_.+-]+)\s+(?:[^)]*?)\b(URL|GIT_REPOSITORY)\s+"?([^\s")]+)'
    foreach ($m in [regex]::Matches($CMakeText, $pattern)) {
        $url = if ($m.Groups[2].Value -ieq 'URL') { $m.Groups[3].Value } else { "git:$($m.Groups[3].Value)" }
        $map[$m.Groups[1].Value.ToLowerInvariant()] = $url
    }
    return $map
}

function Assert-FetchContentSeeded {
    <#
    .SYNOPSIS
        Throws unless every declared FetchContent dependency (bar -Inactive) has a seed for the SAME URL.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Declared,
        [Parameter(Mandatory)][hashtable]$Seeded,
        [string[]]$Inactive = @()
    )
    if ($Declared.Count -eq 0) { throw 'no FetchContent_Declare found - the upstream layout moved and this gate would check nothing' }
    $active = @($Declared.Keys | Where-Object { $Inactive -notcontains $_ })
    $unseeded = @($active | Where-Object { -not $Seeded.ContainsKey($_) } |
        ForEach-Object { "$_ ($($Declared[$_])) has no hash-pinned seed" })
    $drifted = @($active | Where-Object { $Seeded.ContainsKey($_) -and $Seeded[$_] -ne $Declared[$_] } |
        ForEach-Object { "$_ is declared as $($Declared[$_]) but the seed pins $($Seeded[$_])" })
    $bad = $unseeded + $drifted
    if ($bad.Count -gt 0) { throw ("FetchContent would download unpinned: " + ($bad -join '; ')) }
}

function Start-MigraphxBuildSession {
    <#
    .SYNOPSIS
        Shared prologue: VS environment, a fresh work dir, the sccache server; returns the build Python.
    #>
    param([Parameter(Mandatory)][string]$WorkDir)
    Enter-VsDevCmdEnvironment
    $python = (Get-SourceBuildPython).Exe
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "build Python not found at $python (both builds generate code with it)" }
    Reset-SourceBuildDirectory -Path $WorkDir
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Start-SccacheServerSession
    return $python
}

function Complete-MigraphxBuildSession {
    <#
    .SYNOPSIS
        Shared epilogue: phase table, sccache stats and flush, scratch removal, exit 0. Never returns.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Banner,
        [Parameter(Mandatory)][string]$WorkDir
    )
    Write-BuildPhaseSummary -Label $Label
    Write-SccacheStats -Label $Label
    Complete-SccacheServerSession
    Complete-SourceBuild -Banner $Banner -SourceDir $WorkDir
}

function Get-MigraphxTreeFact {
    <#
    .SYNOPSIS
        One pinned fact read from a fetched tree's CMake text; throws when upstream moved it.
    .PARAMETER Fact
        MigraphxVersion: rocm_setup_version() of the MIGraphX tree. ProtobufAbseil: the abseil tag
        protobuf's FetchContent fallback clones (cmake/dependencies.cmake).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('MigraphxVersion', 'ProtobufAbseil')][string]$Fact,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CMakeText
    )
    $pattern = @{
        MigraphxVersion = 'rocm_setup_version\(\s*VERSION\s+([0-9][0-9.]*)\s*\)'
        ProtobufAbseil  = 'set\(\s*abseil-cpp-version\s+"([^"]+)"\s*\)'
    }[$Fact]
    $m = [regex]::Match($CMakeText, $pattern)
    if (-not $m.Success) { throw "$Fact not found: the upstream CMake no longer matches /$pattern/" }
    return $m.Groups[1].Value
}

function Get-MigraphxRocmCmakeCommit {
    <#
    .SYNOPSIS
        The rocm-cmake commit MIGraphX's own requirements.txt pins; throws when upstream moved it.
    .DESCRIPTION
        MIGraphX rocm-10.0 calls rocm_add_version_resource (rocm-cmake 33541cd51f, 2026-04-17), which
        TheRock's rocm-cmake predates, so the build installs this commit ahead of TheRock. Only a full
        40-hex commit is accepted: that id is what verifies the fetched tree (Save-GitCommitSource).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RequirementsText)
    $m = [regex]::Match($RequirementsText, '(?m)^\s*ROCm/rocm-cmake@(\S+)')
    if (-not $m.Success) { throw 'rocm-cmake not found in MIGraphX requirements.txt: upstream moved the pin' }
    $ref = $m.Groups[1].Value
    if ($ref -notmatch '^[0-9a-f]{40}$') {
        throw "MIGraphX pins rocm-cmake at '$ref', not a 40-hex commit - refusing a ref that cannot verify the tree"
    }
    return $ref
}

function Save-GitCommitSource {
    <#
    .SYNOPSIS
        Fetches ONE commit of a repository into a fresh directory; returns the tree root.
    .DESCRIPTION
        The commit id is the pin: git checks every fetched object against it, so no archive SHA256
        exists to compare. HEAD is re-read after the checkout and must equal the requested id.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Commit,
        [Parameter(Mandatory)][string]$WorkDir
    )
    $dest = Join-Path $WorkDir "$Name-src"
    Reset-SourceBuildDirectory -Path $dest
    & git init --quiet $dest
    if ($LASTEXITCODE -ne 0) { throw "git init failed (exit $LASTEXITCODE) for $Name" }
    $fetched = $false
    foreach ($attempt in 1..3) {
        & git -C $dest fetch --quiet --depth 1 $Repository $Commit
        if ($LASTEXITCODE -eq 0) { $fetched = $true; break }
        Write-Warning "git fetch $Name $Commit failed (exit $LASTEXITCODE), attempt $attempt of 3"
        Start-Sleep -Seconds (5 * $attempt)
    }
    if (-not $fetched) { throw "could not fetch $Name at $Commit from $Repository" }
    & git -C $dest checkout --quiet --detach FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw "git checkout failed (exit $LASTEXITCODE) for $Name" }
    $head = "$(& git -C $dest rev-parse HEAD)".Trim()
    if ($head -ne $Commit) { throw "$Name checked out $head, not the pinned $Commit" }
    Write-Host "Staged $Name at $($Commit.Substring(0, 12)) (git verified the commit) in $dest"
    return $dest
}

function Write-NlohmannJsonConfigShim {
    <#
    .SYNOPSIS
        A nlohmann_json package dir that loads TheRock's config and clears its INTERFACE_SOURCES.
    .DESCRIPTION
        TheRock's copy was installed by an MSVC-style build, so its exported target lists
        <prefix>/nlohmann_json.natvis as an interface source, and TheRock's dist does not ship that
        file: "Cannot find source file: C:/TheRock/build/nlohmann_json.natvis" (2026-09-25). The natvis
        is a debugger visualizer; headers, version and licence stay TheRock's. Returns the shim dir.
    #>
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string]$DepsPrefix
    )
    $upstream = (Join-Path $RocmRoot 'share\cmake\nlohmann_json') -replace '\\', '/'
    $absent = @('nlohmann_jsonConfig.cmake', 'nlohmann_jsonConfigVersion.cmake').Where({ -not [IO.File]::Exists("$upstream/$_") })
    if ($absent.Count) { throw "TheRock has no $upstream/$($absent -join ' or ')" }
    $shimDir = [IO.Directory]::CreateDirectory((Join-Path $DepsPrefix 'share\cmake\nlohmann_json')).FullName
    [IO.File]::WriteAllLines((Join-Path $shimDir 'nlohmann_jsonConfig.cmake'), [string[]]@(
        '# Written by Build-MigraphxFromSource.ps1: TheRock''s nlohmann_json minus the natvis its dist lacks.'
        "include(`"$upstream/nlohmann_jsonConfig.cmake`")"
        'set_property(TARGET nlohmann_json::nlohmann_json PROPERTY INTERFACE_SOURCES "")'))
    [IO.File]::WriteAllLines((Join-Path $shimDir 'nlohmann_jsonConfigVersion.cmake'),
        [string[]]@("include(`"$upstream/nlohmann_jsonConfigVersion.cmake`")"))
    return $shimDir
}

function Write-HipMsvcCmathOverlay {
    <#
    .SYNOPSIS
        An -isystem directory whose two HIP math headers step aside for the comparisons MSVC's <cmath> owns.
    .DESCRIPTION
        Under clang, MSVC 14.51's <cmath> defines isgreater, isgreaterequal, isless, islessequal,
        islessgreater and isunordered as constexpr wrappers over builtins, which HIP makes
        __host__ __device__, so clang's HIP headers can no longer declare their __device__ versions
        ("cannot overload __host__ __device__ function", 2026-09-25). Each overlay header renames those
        six names, #include_next's the untouched original and restores them; device code then calls
        MSVC's builtin versions. The wrapper includes both headers with <>, so -isystem reaches them.
    #>
    param([Parameter(Mandatory)][string]$WorkDir)
    $owned = 'isgreater', 'isgreaterequal', 'isless', 'islessequal', 'islessgreater', 'isunordered'
    $rename = $owned | ForEach-Object { "#pragma push_macro(`"$_`")"; "#undef $_"; "#define $_ __hip_msvc_owned_$_" }
    $restore = $owned | ForEach-Object { "#undef $_"; "#pragma pop_macro(`"$_`")" }
    $overlay = [IO.Directory]::CreateDirectory((Join-Path $WorkDir 'hip-msvc-cmath-overlay')).FullName
    '__clang_cuda_math_forward_declares.h', '__clang_hip_cmath.h' | ForEach-Object {
        $body = @('// Written by Write-HipMsvcCmathOverlay: MSVC''s <cmath> owns these six.') + $rename + "#include_next <$_>" + $restore
        [IO.File]::WriteAllLines((Join-Path $overlay $_), [string[]]$body)
    }
    return $overlay
}

function Get-MigraphxPinnedSourceSpec {
    <#
    .SYNOPSIS
        Resolve-PinnedSource arguments for every archive the spike fetches, one owner for both builds.
    .PARAMETER Set
        MigraphxDeps: MIGraphX's requirements.txt pins at its tag. OrtAmdgpuEp: one entry per
        FetchContent name, each URL EXACTLY as the pinned EP commit declares it (absl: protobuf's).
    #>
    param([Parameter(Mandatory)][ValidateSet('MigraphxDeps', 'OrtAmdgpuEp')][string]$Set)
    $gh = 'https://github.com'
    $rows = switch ($Set) {
        'MigraphxDeps' {
            , @('abseil', 'MIGRAPHX_WINDOWS_ABSEIL', "$gh/abseil/abseil-cpp/archive/refs/tags/{0}.tar.gz")
            , @('protobuf', 'MIGRAPHX_WINDOWS_PROTOBUF', "$gh/protocolbuffers/protobuf/releases/download/v{0}/protobuf-{0}.tar.gz")
            , @('msgpack', 'MIGRAPHX_WINDOWS_MSGPACK', "$gh/msgpack/msgpack-c/releases/download/cpp-{0}/msgpack-{0}.tar.gz")
            , @('sqlite', 'MIGRAPHX_WINDOWS_SQLITE', 'https://www.sqlite.org/{1}/sqlite-amalgamation-{0}.zip', 'MIGRAPHX_WINDOWS_SQLITE_YEAR')
        }
        'OrtAmdgpuEp' {
            , @('fmt', 'ORT_AMDGPU_EP_FMT', "$gh/fmtlib/fmt/releases/download/{0}/fmt-{0}.zip")
            , @('gsl', 'ORT_AMDGPU_EP_GSL', "$gh/microsoft/GSL/archive/refs/tags/v{0}.zip")
            , @('json', 'ORT_AMDGPU_EP_JSON', "$gh/nlohmann/json/releases/download/v{0}/json.tar.xz")
            , @('zlib', 'ORT_AMDGPU_EP_ZLIB', "$gh/madler/zlib/releases/download/v{0}/zlib-{0}.tar.xz")
            , @('protobuf', 'ORT_AMDGPU_EP_PROTOBUF', "$gh/protocolbuffers/protobuf/archive/refs/tags/v{0}.zip")
            , @('onnx', 'ORT_AMDGPU_EP_ONNX', "$gh/onnx/onnx/archive/refs/tags/v{0}.zip")
            , @('flatbuffers', 'ORT_AMDGPU_EP_FLATBUFFERS', "$gh/google/flatbuffers/archive/refs/tags/v{0}.zip")
            , @('range-v3', 'ORT_AMDGPU_EP_RANGE_V3', "$gh/ericniebler/range-v3/archive/refs/tags/{0}.zip")
            , @('absl', 'ORT_AMDGPU_EP_ABSEIL', "$gh/abseil/abseil-cpp/archive/refs/tags/{0}.tar.gz")
        }
    }
    foreach ($r in $rows) {
        $spec = @{ Name = $r[0]; VersionKey = "$($r[1])_VERSION"; ShaKey = "$($r[1])_SHA256"; UrlFormat = $r[2] }
        if ($r.Count -gt 3) { $spec.ExtraKeys = @($r[3..($r.Count - 1)]) }
        $spec
    }
}

function Get-FetchContentSeedArg {
    <#
    .SYNOPSIS
        -DFETCHCONTENT_SOURCE_DIR_<NAME>=<dir>: FetchContent then uses the verified tree and never downloads.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourceDir
    )
    return "-DFETCHCONTENT_SOURCE_DIR_$($Name.ToUpperInvariant()):PATH=$($SourceDir -replace '\\', '/')"
}

# nlohmann/json is TheRock's header-only copy compiled into migraphx.dll; TheRock ships no licence file for it.
$script:NlohmannNotice = 'licenses\nlohmann_json\NOTICE.txt'

function Get-MigraphxLicenseFile {
    <#
    .SYNOPSIS
        Pinned-source name -> licence files in its tree, for what the build LINKS; docs/deps/deps.json has a row each.
    .DESCRIPTION
        SQLite is public domain, so it has no text. The EP's json (USE_DML only) and zlib
        (protobuf_WITH_ZLIB=OFF) are seeded but never linked, so they are absent here.
    #>
    param([Parameter(Mandatory)][ValidateSet('MigraphxDeps', 'OrtAmdgpuEp')][string]$Set)
    $protobuf = @('LICENSE', 'third_party\utf8_range\LICENSE')
    switch ($Set) {
        'MigraphxDeps' {
            return [ordered]@{ abseil = @('LICENSE'); protobuf = $protobuf; msgpack = @('LICENSE_1_0.txt', 'COPYING', 'NOTICE'); sqlite = @() }
        }
        'OrtAmdgpuEp' {
            return [ordered]@{ fmt = @('LICENSE'); gsl = @('LICENSE'); 'range-v3' = @('LICENSE.txt'); onnx = @('LICENSE')
                flatbuffers = @('LICENSE'); protobuf = $protobuf; absl = @('LICENSE') }
        }
    }
}

function Get-MigraphxStagedLicensePath {
    <#
    .SYNOPSIS
        Every licence path an install carries, relative to it: the builds write them, the rocm-check reads them.
    #>
    param([Parameter(Mandatory)][ValidateSet('MigraphxDeps', 'OrtAmdgpuEp')][string]$Set)
    $paths = @('LICENSE')
    if ($Set -eq 'MigraphxDeps') { $paths += $script:NlohmannNotice }
    $map = Get-MigraphxLicenseFile -Set $Set
    foreach ($name in $map.Keys) { foreach ($rel in $map[$name]) { $paths += "licenses\$name\$rel" } }
    return $paths
}

function Get-MigraphxLicenseGap {
    <#
    .SYNOPSIS
        The Get-MigraphxStagedLicensePath entries missing under an install dir.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][ValidateSet('MigraphxDeps', 'OrtAmdgpuEp')][string]$Set
    )
    return @(Get-MigraphxStagedLicensePath -Set $Set | Where-Object { -not (Test-Path -LiteralPath (Join-Path $InstallDir $_) -PathType Leaf) })
}

function Copy-MigraphxLicenseFile {
    <#
    .SYNOPSIS
        Copies a fetched tree's licence files to <Destination>\licenses\<Name>\; throws naming any upstream moved.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePath,
        [Parameter(Mandatory)][string]$Destination
    )
    $missing = @($RelativePath | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SourceRoot $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { throw "$Name`: licence file(s) $($missing -join ', ') not found in $SourceRoot (upstream moved them?)" }
    foreach ($rel in $RelativePath) {
        $target = Join-Path $Destination "licenses\$Name\$rel"
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceRoot $rel) -Destination $target -Force
    }
}

function Save-SpdxHeaderNotice {
    <#
    .SYNOPSIS
        Writes a header's leading // block (upstream's copyright + SPDX lines) to a file; throws without an SPDX id.
    .DESCRIPTION
        For header-only code taken from TheRock, which ships nlohmann/json without a licence file.
    #>
    param(
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Header -PathType Leaf)) { throw "$Header not found (TheRock layout moved?)" }
    $block = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Header -TotalCount 60)) {
        if ($line -notmatch '^\s*//') { break }
        $block.Add($line)
    }
    if (@($block | Where-Object { $_ -match 'SPDX-License-Identifier:\s*\S' }).Count -eq 0) {
        throw "$Header has no SPDX-License-Identifier in its leading comment block"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
    Set-Content -LiteralPath $Destination -Encoding utf8 -Value (@("Verbatim from $Header, as compiled into this build:", '') + $block)
}

function Save-MigraphxLicense {
    <#
    .SYNOPSIS
        Stages every Get-MigraphxStagedLicensePath entry except the component's own LICENSE into an install.
    .PARAMETER SourceRoot
        Pinned-source name -> its fetched tree (what Save-PinnedSource returned).
    .PARAMETER RocmRoot
        MigraphxDeps only: the TheRock tree whose nlohmann/json headers MIGraphX compiled.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('MigraphxDeps', 'OrtAmdgpuEp')][string]$Set,
        [Parameter(Mandatory)][hashtable]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallDir,
        [string]$RocmRoot = ''
    )
    $map = Get-MigraphxLicenseFile -Set $Set
    foreach ($name in $map.Keys) {
        if (-not $SourceRoot[$name]) { throw "no fetched tree for '$name' to take its licence from" }
        Copy-MigraphxLicenseFile -Name $name -SourceRoot $SourceRoot[$name] -RelativePath $map[$name] -Destination $InstallDir
    }
    if ($Set -eq 'MigraphxDeps') {
        if (-not $RocmRoot) { throw 'MigraphxDeps needs -RocmRoot for the nlohmann/json notice' }
        Save-SpdxHeaderNotice -Header (Join-Path $RocmRoot 'include\nlohmann\json.hpp') -Destination (Join-Path $InstallDir $script:NlohmannNotice)
    }
}

Export-ModuleMember -Function Assert-MigraphxRocmLane, Get-MigraphxGpuTargetList, Get-MigraphxHipRuntimeFile,
    Initialize-MigraphxBuild, Get-RocmLlvmToolPath, Resolve-PinnedSource, Get-SevenZipSkippedLink, Expand-PinnedArchive,
    Save-PinnedSource, Get-FetchContentUrlMap,
    Assert-FetchContentSeeded, Get-FetchContentSeedArg, Get-MigraphxTreeFact, Get-MigraphxRocmCmakeCommit, Save-GitCommitSource,
    Write-NlohmannJsonConfigShim, Write-HipMsvcCmathOverlay,
    Get-MigraphxPinnedSourceSpec, Start-MigraphxBuildSession, Complete-MigraphxBuildSession,
    Get-MigraphxLicenseFile, Get-MigraphxStagedLicensePath, Get-MigraphxLicenseGap, Copy-MigraphxLicenseFile, Save-SpdxHeaderNotice,
    Save-MigraphxLicense

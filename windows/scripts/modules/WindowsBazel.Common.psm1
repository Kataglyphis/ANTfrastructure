#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Bazel lanes on Windows: pinned tools, Bazel 7's clang-cl toolchain, the compiler gates and the tree cleanup; see docs/windows-builds.md § Bazel lanes

Set-StrictMode -Version Latest

function Get-UrlWithRetry {
    <#
    .SYNOPSIS
        Downloads -Uri to -OutFile, retrying an error or an empty file with a growing pause.
    #>
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile, [int]$Retries = 4)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return }
            throw 'downloaded file is missing or empty'
        } catch {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            if ($i -eq $Retries) { throw "download failed after $Retries attempts [$Uri]: $($_.Exception.Message)" }
            Write-Host ("  download attempt {0}/{1} failed [{2}]: {3} - retrying in {4}s" -f $i, $Retries, $Uri, $_.Exception.Message, ($i * 5))
            Start-Sleep -Seconds ($i * 5)
        }
    }
}

function Get-PinnedTool {
    <#
    .SYNOPSIS
        A cached download that must match the SHA256 in the environment variable -PinKey; a stale or corrupt entry is fetched again (hub #185).
    #>
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$PinKey)
    $want = [Environment]::GetEnvironmentVariable($PinKey)
    if ($want -notmatch '^[0-9a-fA-F]{64}$') { throw "$PinKey is not a SHA256 ('$want'): refusing an unpinned $(Split-Path -Leaf $Path)" }
    $hash = { if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { '' } }
    if ((& $hash) -eq $want) { Write-Host "  $(Split-Path -Leaf $Path): cache hit"; return }
    Get-UrlWithRetry -Uri $Uri -OutFile $Path
    $got = & $hash
    if ($got -ne $want) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$Uri has SHA256 $got, versions.env $PinKey pins $want"
    }
}

function Get-BazelPin {
    <#
    .SYNOPSIS
        The environment variables -Name as an ordered map; an unset one throws with -Context, since a floating input makes the build unreproducible.
    #>
    param([Parameter(Mandatory)][string[]]$Name, [Parameter(Mandatory)][string]$Context)
    $pin = [ordered]@{}
    foreach ($key in $Name) {
        $pin[$key] = [Environment]::GetEnvironmentVariable($key)
        if ([string]::IsNullOrWhiteSpace($pin[$key])) { throw "$key is unset: $Context" }
    }
    return $pin
}

function Get-BazelClangClArg {
    <#
    .SYNOPSIS
        The env and flags that make Bazel 7 build target and exec with its own clang-cl toolchain from -LlvmRoot.
    .DESCRIPTION
        No USE_CLANG_CL: it keeps the toolchain's compiler at msvc-cl. -Platform must carry @bazel_tools//tools/cpp:clang-cl.
        -VcRoot is VS's VC directory, whose newest MSVC toolset supplies the STL and SDK paths; -BashPath runs genrules.
    #>
    param(
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$VcRoot,
        [Parameter(Mandatory)][string]$BashPath,
        [string]$LlvmRoot = 'C:\llvm-patched'
    )
    foreach ($exe in 'clang-cl', 'lld-link', 'llvm-lib') {
        $p = Join-Path $LlvmRoot "bin\$exe.exe"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Bazel's clang-cl toolchain needs $p" }
    }
    $toolsets = @(Get-ChildItem -LiteralPath (Join-Path $VcRoot 'Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name })
    if ($toolsets.Count -eq 0) { throw "no MSVC toolset under $VcRoot\Tools\MSVC: Bazel's clang-cl toolchain takes its STL and SDK paths from it" }
    if (-not (Test-Path -LiteralPath $BashPath -PathType Leaf)) { throw "BAZEL_SH $BashPath is missing: genrules run through bash" }
    return [pscustomobject]@{
        Env   = [ordered]@{ BAZEL_LLVM = $LlvmRoot; BAZEL_VC = $VcRoot; BAZEL_VC_FULL_VERSION = $toolsets[-1].Name; BAZEL_SH = $BashPath }
        Flags = @('--extra_toolchains=@local_config_cc//:cc-toolchain-x64_windows-clang-cl',
            "--extra_execution_platforms=$Platform", "--host_platform=$Platform", "--platforms=$Platform", '--compiler=clang-cl')
    }
}

function Assert-BazelActionCompiler {
    <#
    .SYNOPSIS
        Throws unless every action in an `aquery --output=jsonproto` result runs clang-cl, lld-link or llvm-lib from -LlvmRoot; returns the action count.
    #>
    param([Parameter(Mandatory)][string]$AqueryJson, [string]$LlvmRoot = 'C:\llvm-patched')
    $parsed = $AqueryJson | ConvertFrom-Json
    $actions = @(if ($parsed.PSObject.Properties['actions']) { $parsed.actions })
    if ($actions.Count -eq 0) { throw 'aquery returned no action: the compiler gate would pass with nothing checked' }
    $bin = ($LlvmRoot -replace '\\', '/').TrimEnd('/') + '/bin/'
    $allowed = 'clang-cl.exe', 'lld-link.exe', 'llvm-lib.exe'
    $bad = @(foreach ($a in $actions) {
            $exe = ([string]@($a.arguments)[0]) -replace '\\', '/'
            $leaf = $exe.Substring($exe.LastIndexOf('/') + 1)
            if (-not $exe.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase) -or $leaf -notin $allowed) { "$($a.mnemonic): $exe" }
        })
    if ($bad.Count -gt 0) {
        throw "$($bad.Count) of $($actions.Count) bazel actions do not run $($LlvmRoot)'s clang-cl, lld-link or llvm-lib: $(($bad | Sort-Object -Unique | Select-Object -First 8) -join '; ')"
    }
    return $actions.Count
}

function Get-BazelRocmEnvScrub {
    <#
    .SYNOPSIS
        rocm lane: name -> value ($null unsets) for env entries into the ROCm tree and HIP_PLATFORM, hiding TheRock from bazel.
    #>
    param([string]$GpuType, [Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $scrub = @{}
    if ($GpuType -ne 'rocm') { return $scrub }
    $norm = { param([string]$p) $p.Trim().Replace('/', '\').TrimEnd('\') }
    $roots = @(foreach ($name in @($Environment.Keys)) {
            $value = [string]$Environment[$name]
            if ($name -in 'ROCM_PATH', 'HIP_PATH' -and $value.Trim()) { & $norm $value }
        })
    $inRocm = { param([string]$entry)
        $e = & $norm $entry
        foreach ($r in $roots) { if ($e -ieq $r -or $e.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    foreach ($name in @($Environment.Keys)) {
        if ($name -ieq 'HIP_PLATFORM') { $scrub[$name] = $null; continue }
        $entries = @(([string]$Environment[$name]) -split ';')
        $kept = @($entries | Where-Object { -not (& $inRocm $_) })
        if ($kept.Count -eq $entries.Count) { continue }
        $scrub[$name] = if (@($kept | Where-Object { $_.Trim() }).Count -eq 0) { $null } else { $kept -join ';' }
    }
    return $scrub
}

function Set-BazelProcessEnv {
    <#
    .SYNOPSIS
        Sets name -> value in this process ($null removes it) and returns the previous values for the restore.
    .DESCRIPTION
        The bazel server inherits the env it starts with, so the caller sets it before the first bazel call.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $previous = [ordered]@{}
    foreach ($name in @($Values.Keys)) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        # Remove-Item: SetEnvironmentVariable($null) leaves it defined-empty for native children.
        if ($null -eq $Values[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$name" -Value $Values[$name] }
    }
    return $previous
}

function Invoke-BazelLogged {
    <#
    .SYNOPSIS
        Runs -Bazel with -Argument and returns its exit code; every line goes to -LogPath, the stage log gets one progress line per 30 s (hub #181).
    #>
    param([Parameter(Mandatory)][string]$Bazel, [Parameter(Mandatory)][string[]]$Argument, [Parameter(Mandatory)][string]$LogPath, [switch]$Append)
    $lastProgress = [datetime]::MinValue
    & $Bazel @Argument 2>&1 | Tee-Object -FilePath $LogPath -Append:$Append | ForEach-Object {
        $line = "$_"
        if ($line -notmatch '^\[[\d,]+ / [\d,]+\]') { Write-Host $line }
        elseif (((Get-Date) - $lastProgress).TotalSeconds -ge 30) { Write-Host $line; $lastProgress = Get-Date }
    }
    return $LASTEXITCODE
}

function Get-TreeGb {
    <#
    .SYNOPSIS
        The size of -Path in GB; Get-ChildItem does not follow junctions, so a tree is counted once.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    # Measure-Object emits nothing for no input, and .Sum on that throws under StrictMode (probe LM2).
    if ($files.Count -eq 0) { return 0 }
    return ($files | Measure-Object -Property Length -Sum).Sum / 1GB
}

function Remove-BazelBuildTree {
    <#
    .SYNOPSIS
        Stops every bazel server whose java.exe lives under a -ServerRoot, then removes each -Path; a junction goes, never its target.
    .DESCRIPTION
        `bazel shutdown` would start a fresh server, and one started from outside a workspace dies on its command line (probe P3).
    #>
    param([Parameter(Mandatory)][string[]]$Path, [string[]]$ServerRoot = @())
    $servers = @(Get-Process -Name java -ErrorAction SilentlyContinue | Where-Object {
            $exe = $_.Path
            $exe -and @($ServerRoot | Where-Object { $_ -and $exe.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
    foreach ($server in $servers) {
        Write-Host "  stopping the bazel server (java.exe pid $($server.Id))"
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $null = $server.WaitForExit(30000)
    }
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        Write-Host ('  removing {0} ({1:N2} GB)' -f $p, (Get-TreeGb -Path $p))
        if (Test-Path -LiteralPath $p -PathType Container) { & cmd.exe /c "rd /s /q ""$p""" 2>$null }
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $p) { Write-Warning "  $p survived its removal and stays in the layer" }
    }
    $global:LASTEXITCODE = 0
}

function Get-BazelRemoteCacheArg {
    <#
    .SYNOPSIS
        Bazel's HTTP cache on the build host's dufs, <SCCACHE_WEBDAV_ENDPOINT>/bazel, or no option when there is no endpoint or it does not answer.
    .DESCRIPTION
        dufs speaks the protocol as it is: a PUT creates ac/ and cas/, a missing key is a 404. Every output is downloaded, as without the cache,
        because the install steps read intermediate files from bazel-bin. docs/windows-build-resources.md § Bazel's cache
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Endpoint = $env:SCCACHE_WEBDAV_ENDPOINT, [int]$TimeoutSec = 3)
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        Write-Host '  bazel remote cache: none (no SCCACHE_WEBDAV_ENDPOINT in this RUN)'
        return @()
    }
    $cache = "$($Endpoint.Trim().TrimEnd('/'))/bazel"
    try {
        $null = Invoke-WebRequest -Uri "$cache/" -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -SkipHttpErrorCheck
    } catch {
        Write-Warning "bazel remote cache: $cache does not answer ($($_.Exception.Message)); building without it"
        return @()
    }
    Write-Host "  bazel remote cache: $cache"
    return @("--remote_cache=$cache", '--remote_download_outputs=all')
}

Export-ModuleMember -Function Get-UrlWithRetry, Get-PinnedTool, Get-BazelPin, Get-BazelClangClArg, Assert-BazelActionCompiler, Get-BazelRocmEnvScrub,
    Set-BazelProcessEnv, Invoke-BazelLogged, Get-TreeGb, Remove-BazelBuildTree, Get-BazelRemoteCacheArg

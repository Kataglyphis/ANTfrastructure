#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# NOTE (downstream consumers -- do NOT remove as "dead code"): this module has no
# callers inside THIS repo, but Kataglyphis-Inference-Engine's
# scripts/windows/Build-Windows.ps1 imports it from its ContainerHub submodule at
# ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/. It was deleted
# once in 5be9b1e and restored (2026-07-15) -- grep known consumers before any
# future sweep of windows/scripts/modules/.


# WindowsFlutter.Common.psm1
# Reusable functions for building and patching Flutter Windows applications in a containerized environment.

# Write-BuildLog / Write-BuildLogWarning come from the sibling
# WindowsBuild.Common module; without this import a standalone consumer hits
# CommandNotFound at runtime. Guarded, WITHOUT -Force (repo-wide nested-import
# rule, 2026-08-04): a forced nested re-import would pull a caller's top-level
# import out of the global session state.
if (-not (Get-Module -Name 'WindowsBuild.Common')) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

function Clear-FlutterPluginSymlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object] $Context,

        [Parameter(Mandatory=$true)]
        [string] $WorkspaceDir
    )

    $symlinksDirToClean = Join-Path $WorkspaceDir "windows\flutter\ephemeral\.plugin_symlinks"
    if (Test-Path -LiteralPath $symlinksDirToClean) {
        Write-BuildLog -Context $Context -Message "Cleaning up old Flutter plugin symlinks directory: $symlinksDirToClean"
        Remove-Item -LiteralPath $symlinksDirToClean -Force -Recurse -ErrorAction SilentlyContinue
        & cmd.exe /c "rmdir /q /s `"$symlinksDirToClean`" 2>nul"
    }
}

function Repair-FlutterPluginSymlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object] $Context,

        [Parameter(Mandatory=$true)]
        [string] $WorkspaceDir
    )

    $flutterPluginsDepsPath = Join-Path $WorkspaceDir ".flutter-plugins-dependencies"
    $symlinksDir = Join-Path $WorkspaceDir "windows\flutter\ephemeral\.plugin_symlinks"

    if (-not (Test-Path $symlinksDir)) {
        New-Item -ItemType Directory -Force -Path $symlinksDir | Out-Null
    }

    if (Test-Path $flutterPluginsDepsPath) {
        $depsJson = Get-Content $flutterPluginsDepsPath -Raw | ConvertFrom-Json
        if ($null -ne $depsJson.plugins -and $null -ne $depsJson.plugins.windows) {
            foreach ($plugin in $depsJson.plugins.windows) {
                $pluginName = $plugin.name
                $pluginPath = $plugin.path

                # Ensure Windows paths and remove trailing slash
                $pluginPath = $pluginPath -replace '/', '\'
                $pluginPath = $pluginPath.TrimEnd('\')

                $junctionPath = Join-Path $symlinksDir $pluginName

                # Clean up any broken symlinks or existing folders before trying to link/copy
                if (Test-Path -LiteralPath $junctionPath -ErrorAction SilentlyContinue) {
                    Remove-Item -LiteralPath $junctionPath -Force -Recurse -ErrorAction SilentlyContinue
                }
                # Fallback for broken symlinks which Test-Path might miss
                & cmd.exe /c "rmdir /q /s `"$junctionPath`" 2>nul"
                & cmd.exe /c "del /q /f `"$junctionPath`" 2>nul"

                # Prefer a junction over a recursive copy: for plugins with a deep
                # vendored tree (e.g. kataglyphis_native_inference's
                # native/KataglyphisCppInference/ExternalLib/*), copying into the
                # even-deeper .plugin_symlinks path overruns MAX_PATH (260 chars) and
                # aborts before windows\ is copied, leaving a broken junction. A
                # junction is container-local-safe and immune to MAX_PATH; fall back to
                # a copy only if it fails to resolve (the copy rationale — avoiding
                # symlink access-denied — applies only to bind-mounted paths).
                Write-BuildLog -Context $Context -Message "Creating junction for $pluginName..."
                & cmd.exe /c "mklink /J `"$junctionPath`" `"$pluginPath`"" 2>&1 | Out-Null
                if (-not (Test-Path (Join-Path $junctionPath 'windows'))) {
                    Write-BuildLogWarning -Context $Context -Message "Junction for ${pluginName} did not resolve; falling back to copy..."
                    try {
                        Copy-Item -Path $pluginPath -Destination $junctionPath -Recurse -Force -ErrorAction Stop
                    } catch {
                        Write-BuildLogWarning -Context $Context -Message "Failed to copy plugin ${pluginName}: $($_.Exception.Message)"
                    }
                }
            }
        }
    } else {
        Write-BuildLogWarning -Context $Context -Message "No .flutter-plugins-dependencies file found to create junctions from."
    }
}

function Update-PermissionHandlerWindows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object] $Context,

        [Parameter(Mandatory=$true)]
        [string] $WorkspaceDir
    )

    $pluginFile = Join-Path $WorkspaceDir "windows\flutter\ephemeral\.plugin_symlinks\permission_handler_windows\windows\permission_handler_windows_plugin.cpp"
    $pluginFile = [System.IO.Path]::GetFullPath($pluginFile)

    if (Test-Path $pluginFile) {
        $pluginContent = Get-Content -LiteralPath $pluginFile -Raw
        $changed = $false

        $targetLine = 'result->Success\(requestResults\);'
        $patchedLine = 'result->Success(flutter::EncodableValue(requestResults));'

        if ($pluginContent -match 'result->Success\(flutter::EncodableValue\(requestResults\)\);') {
            Write-BuildLog -Context $Context -Message "permission_handler_windows Success already patched."
        } elseif ($pluginContent -match $targetLine) {
            Write-BuildLog -Context $Context -Message "Patching permission_handler_windows Success..."
            $pluginContent = $pluginContent -replace $targetLine, $patchedLine
            $changed = $true
        } else {
            Write-BuildLogWarning -Context $Context -Message "Patch target line not found in permission_handler_windows plugin file."
        }

        $targetLineFor = 'for\s*\(\s*int\s+i\s*=\s*0\s*;\s*i\s*<\s*permissions\.size\(\)\s*;\s*i\+\+\s*\)'
        $patchedLineFor = 'for (size_t i=0;i<permissions.size();i++)'

        if ($pluginContent -match 'for\s*\(\s*size_t\s+i') {
            Write-BuildLog -Context $Context -Message "permission_handler_windows loop already patched."
        } elseif ($pluginContent -match $targetLineFor) {
            Write-BuildLog -Context $Context -Message "Patching permission_handler_windows loop..."
            $pluginContent = $pluginContent -replace $targetLineFor, $patchedLineFor
            $changed = $true
        }

        if ($changed) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pluginFile, $pluginContent, $utf8NoBom)
            Write-BuildLog -Context $Context -Message "Successfully applied permission_handler_windows patches."
        }
    }
}

function Sync-FastLocalArtifactsToHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object] $Context,

        [Parameter(Mandatory=$true)]
        [string] $BuildRoot,

        [Parameter(Mandatory=$true)]
        [string] $OriginalBuildRoot,

        [Parameter(Mandatory=$false)]
        [string] $CargoTargetDir,

        [Parameter(Mandatory=$false)]
        [string] $HostRustTargetDir
    )

    Write-BuildLog -Context $Context -Message "Syncing fast local build artifacts ($BuildRoot) back to host ($OriginalBuildRoot)..."
    
    if (-not (Test-Path $OriginalBuildRoot)) {
        New-Item -ItemType Directory -Force -Path $OriginalBuildRoot | Out-Null
    }
    
    # /E copies all subdirectories without deleting existing
    # /MT:16 enables extremely fast multithreaded copying across the bind mount
    # /R:1 /W:1 prevents Robocopy from hanging on locked files (1 million retries by default!)
    # /FFT uses 2-second FAT file time granularity (crucial for Docker bind mounts to prevent false "modified" detects)
    # /NOOFFLOAD prevents Windows from trying and failing to use hardware copy offload over the VM boundary
    # /XF and /XD aggressively exclude the thousands of intermediate C++ object and Rust metadata files we don't need on the host
    $robocopyArgs = @(
        $BuildRoot,
        $OriginalBuildRoot,
        "/E", "/MT:16", "/R:1", "/W:1", "/FFT", "/NOOFFLOAD",
        "/XF", "*.obj", "*.tlog", "*.lastbuildstate", "*.idb", "*.ilk", "*.pdb", ".ninja*",
        "/XD", "*.dir", "CMakeFiles", "x64_x64-ClangCL*",
        "/NFL", "/NDL", "/NJH", "/NJS", "/nc", "/ns", "/np", "/LOG:nul"
    )
    & robocopy.exe $robocopyArgs > $null 2>&1
    # Robocopy exit codes 0-7 are success variants (1 = files copied); >= 8
    # means at least one copy failed. Sync-back is best-effort, so a failure
    # warns instead of throwing - but it must not pass silently.
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -ge 8) {
        Write-BuildLogWarning -Context $Context -Message "robocopy sync-back of build artifacts to '$OriginalBuildRoot' failed (exit code $robocopyExit); host copy may be incomplete."
    }
    # Reset so robocopy's non-zero success codes (1-7) never trip callers' exit-code gates.
    $global:LASTEXITCODE = 0

    if (-not [string]::IsNullOrEmpty($CargoTargetDir) -and -not [string]::IsNullOrEmpty($HostRustTargetDir)) {
        Write-BuildLog -Context $Context -Message "Syncing fast local Rust artifacts ($CargoTargetDir) back to host ($HostRustTargetDir)..."
        if (-not (Test-Path $HostRustTargetDir)) {
            New-Item -ItemType Directory -Force -Path $HostRustTargetDir | Out-Null
        }
        
        $robocopyRustArgs = @(
            $CargoTargetDir,
            $HostRustTargetDir,
            "/E", "/MT:16", "/R:1", "/W:1", "/FFT", "/NOOFFLOAD",
            "/XF", "*.rlib", "*.rmeta", "*.d", "*.o",
            "/XD", ".fingerprint", "build", "deps", "incremental",
            "/NFL", "/NDL", "/NJH", "/NJS", "/nc", "/ns", "/np", "/LOG:nul"
        )
        & robocopy.exe $robocopyRustArgs > $null 2>&1
        # Same exit-code contract as the artifact sync above: >= 8 is a real
        # failure (warn, best-effort), 1-7 are success variants (reset).
        $robocopyRustExit = $LASTEXITCODE
        if ($robocopyRustExit -ge 8) {
            Write-BuildLogWarning -Context $Context -Message "robocopy sync-back of Rust artifacts to '$HostRustTargetDir' failed (exit code $robocopyRustExit); host copy may be incomplete."
        }
        $global:LASTEXITCODE = 0
    }
}

# Generates API docs with a pub-activated dartdoc, NOT the SDK-bundled
# `dart doc`. The dartdoc shipped with the pinned Flutter SDK (9.0.4) crashes on
# any Flutter app with a _stripDocImports RangeError; >= 9.0.9 fixes it.
# Docs: docs/windows-reference.md.
function Invoke-FlutterApiDocs {
  param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [string]$OutputPath = 'doc/api'
  )

  Push-Location $WorkspacePath
  try {
    & dart pub global activate dartdoc
    if ($LASTEXITCODE -ne 0) { throw "dart pub global activate dartdoc failed ($LASTEXITCODE)" }
    & dart pub global run dartdoc --output $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "dartdoc failed ($LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
}

# Back-compat aliases: the 2026-08-04 lint wave renamed these exports to
# PSSA-approved verbs, but this module is EXTERNAL-CONSUMER API (see AGENTS.md
# invariants) — other Kataglyphis repos may still call the old names.
Set-Alias -Name Clean-FlutterPluginSymlinks -Value Clear-FlutterPluginSymlink
Set-Alias -Name Fix-FlutterPluginSymlinks -Value Repair-FlutterPluginSymlink
Set-Alias -Name Patch-PermissionHandlerWindows -Value Update-PermissionHandlerWindows

Export-ModuleMember -Function Clear-FlutterPluginSymlink, Repair-FlutterPluginSymlink, Update-PermissionHandlerWindows, Sync-FastLocalArtifactsToHost, Invoke-FlutterApiDocs `
    -Alias Clean-FlutterPluginSymlinks, Fix-FlutterPluginSymlinks, Patch-PermissionHandlerWindows


#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Consumed by OmniAccelerANT's Build-Windows.ps1 with no in-repo caller: see docs/consumer-inventory.md § Why a grep was not enough



# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
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

                $pluginPath = $pluginPath -replace '/', '\'
                $pluginPath = $pluginPath.TrimEnd('\')

                $junctionPath = Join-Path $symlinksDir $pluginName

                if (Test-Path -LiteralPath $junctionPath -ErrorAction SilentlyContinue) {
                    Remove-Item -LiteralPath $junctionPath -Force -Recurse -ErrorAction SilentlyContinue
                }
                # Test-Path misses a broken symlink.
                & cmd.exe /c "rmdir /q /s `"$junctionPath`" 2>nul"
                & cmd.exe /c "del /q /f `"$junctionPath`" 2>nul"

                # A junction, not a copy: copying a deep vendored plugin tree overruns MAX_PATH.
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
    
    # /R:1 /W:1 avoid robocopy's million retries on a locked file; /FFT stops false "modified" on bind mounts.
    $robocopyArgs = @(
        $BuildRoot,
        $OriginalBuildRoot,
        "/E", "/MT:16", "/R:1", "/W:1", "/FFT", "/NOOFFLOAD",
        # CMake state is bound to its dir and generator, and would abort the host's next VS-generator configure.
        "/XF", "*.obj", "*.tlog", "*.lastbuildstate", "*.idb", "*.ilk", "*.pdb", ".ninja*", "CMakeCache.txt",
        "/XD", "*.dir", "CMakeFiles", "x64_x64-ClangCL*",
        "/NFL", "/NDL", "/NJH", "/NJS", "/nc", "/ns", "/np", "/LOG:nul"
    )
    & robocopy.exe $robocopyArgs > $null 2>&1
    # robocopy >= 8 is a failed copy: best-effort sync-back warns, never silently.
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
        $robocopyRustExit = $LASTEXITCODE
        if ($robocopyRustExit -ge 8) {
            Write-BuildLogWarning -Context $Context -Message "robocopy sync-back of Rust artifacts to '$HostRustTargetDir' failed (exit code $robocopyRustExit); host copy may be incomplete."
        }
        $global:LASTEXITCODE = 0
    }
}

# A pub-activated dartdoc: the SDK-bundled 9.0.4 crashes on Flutter apps (_stripDocImports), >= 9.0.9 does not.
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

# Pre-rename names kept for external consumers that may still call them.
Set-Alias -Name Clean-FlutterPluginSymlinks -Value Clear-FlutterPluginSymlink
Set-Alias -Name Fix-FlutterPluginSymlinks -Value Repair-FlutterPluginSymlink
Set-Alias -Name Patch-PermissionHandlerWindows -Value Update-PermissionHandlerWindows

Export-ModuleMember -Function Clear-FlutterPluginSymlink, Repair-FlutterPluginSymlink, Update-PermissionHandlerWindows, Sync-FastLocalArtifactsToHost, Invoke-FlutterApiDocs `
    -Alias Clean-FlutterPluginSymlinks, Fix-FlutterPluginSymlinks, Patch-PermissionHandlerWindows


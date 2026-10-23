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

function Edit-FlutterPluginText {
    param(
        [object]$Context,
        [AllowEmptyString()][string]$Content,
        [hashtable]$Patch
    )

    if ($Content -match $Patch.Already) {
        Write-BuildLog -Context $Context -Message "permission_handler_windows $($Patch.Label) already patched."
    } elseif ($Content -match $Patch.Target) {
        Write-BuildLog -Context $Context -Message "Patching permission_handler_windows $($Patch.Label)..."
        return $Content -replace $Patch.Target, $Patch.Replacement
    } elseif ($Patch.WarnMissing) {
        Write-BuildLogWarning -Context $Context -Message 'Patch target line not found in permission_handler_windows plugin file.'
    }
    return $Content
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

    if (-not (Test-Path $pluginFile)) { return }

    $originalContent = [IO.File]::ReadAllText($pluginFile)
    $pluginContent = $originalContent
    $patches = @(
        @{
            Label = 'Success'
            Already = 'result->Success\(flutter::EncodableValue\(requestResults\)\);'
            Target = 'result->Success\(requestResults\);'
            Replacement = 'result->Success(flutter::EncodableValue(requestResults));'
            WarnMissing = $true
        },
        @{
            Label = 'loop'
            Already = 'for\s*\(\s*size_t\s+i'
            Target = 'for\s*\(\s*int\s+i\s*=\s*0\s*;\s*i\s*<\s*permissions\.size\(\)\s*;\s*i\+\+\s*\)'
            Replacement = 'for (size_t i=0;i<permissions.size();i++)'
            WarnMissing = $false
        }
    )
    foreach ($patch in $patches) {
        $pluginContent = [string](Edit-FlutterPluginText -Context $Context -Content $pluginContent -Patch $patch)
    }
    if ($pluginContent -cne $originalContent) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($pluginFile, $pluginContent, $utf8NoBom)
        Write-BuildLog -Context $Context -Message 'Successfully applied permission_handler_windows patches.'
    }
}


function Sync-FlutterArtifactTree {
    param(
        [object]$Context,
        [string]$Source,
        [string]$Destination,
        [string]$Kind,
        [string[]]$ExcludeFiles,
        [string[]]$ExcludeDirectories
    )

    Write-BuildLog -Context $Context -Message "Syncing fast local $Kind artifacts ($Source) back to host ($Destination)..."
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    # /R:1 /W:1 avoid a locked file's million retries; /FFT avoids false bind-mount changes.
    $copyArgs = @($Source, $Destination, '/E', '/MT:16', '/R:1', '/W:1', '/FFT', '/NOOFFLOAD', '/XF') +
        $ExcludeFiles + @('/XD') + $ExcludeDirectories +
        @('/NFL', '/NDL', '/NJH', '/NJS', '/nc', '/ns', '/np', '/LOG:nul')
    & robocopy.exe @copyArgs > $null 2>&1
    $copyExit = $LASTEXITCODE
    if ($copyExit -ge 8) {
        Write-BuildLogWarning -Context $Context -Message "robocopy sync-back of $Kind artifacts to '$Destination' failed (exit code $copyExit); host copy may be incomplete."
    }
    # Robocopy's success codes 1-7 must not trip the caller's exit-code gate.
    $global:LASTEXITCODE = 0
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

    # CMake state is tied to its directory and generator, so the host receives only artifacts.
    Sync-FlutterArtifactTree -Context $Context -Source $BuildRoot -Destination $OriginalBuildRoot -Kind 'build' `
        -ExcludeFiles @('*.obj', '*.tlog', '*.lastbuildstate', '*.idb', '*.ilk', '*.pdb', '.ninja*', 'CMakeCache.txt') `
        -ExcludeDirectories @('*.dir', 'CMakeFiles', 'x64_x64-ClangCL*')
    if (-not [string]::IsNullOrEmpty($CargoTargetDir) -and -not [string]::IsNullOrEmpty($HostRustTargetDir)) {
        Sync-FlutterArtifactTree -Context $Context -Source $CargoTargetDir -Destination $HostRustTargetDir -Kind 'Rust' `
            -ExcludeFiles @('*.rlib', '*.rmeta', '*.d', '*.o') `
            -ExcludeDirectories @('.fingerprint', 'build', 'deps', 'incremental')
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


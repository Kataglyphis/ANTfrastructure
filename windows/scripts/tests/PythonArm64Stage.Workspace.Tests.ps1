#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Arm64 Python stage interpreter workspace' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/python/New-Arm64PythonTestStage.ps1' -FunctionName 'Initialize-Arm64StageLegPython')

    It 'copies the target interpreter and clears inherited packages while keeping its marker' {
        Invoke-InTestDir {
            param($dir)
            $script:TargetPython = Join-Path $dir 'source'
            $script:TargetFreeThreadedPython = Join-Path $dir 'source-ft'
            $script:out = Join-Path $dir 'stage'
            $site = Join-Path $script:TargetPython 'Lib/site-packages'
            New-Item -ItemType Directory -Path $site -Force | Out-Null
            New-Item -ItemType Directory -Path $script:out -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:TargetPython 'python.exe') -Value fixture
            Set-Content -LiteralPath (Join-Path $site 'README.txt') -Value marker
            Set-Content -LiteralPath (Join-Path $site 'stale.py') -Value stale
            $result = Initialize-Arm64StageLegPython -leg '3.15' -ft:$false
            Assert-Equal 'python.exe' $result.Exe[0].Name
            Assert-True (Test-Path (Join-Path $result.Site 'README.txt'))
            Assert-False (Test-Path (Join-Path $result.Site 'stale.py'))
        }
    }
}

Describe 'Arm64 Python stage locked site install' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/python/New-Arm64PythonTestStage.ps1' -FunctionName 'Install-Arm64StageLegSite')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' -FunctionName 'Get-SourceBuildHostPythonExe')
    $script:gil = @{ Exe = 'gil-python.exe' }
    $script:FreeThreadedExtras = 'gpu test'
    $script:Extras = 'default'
    $script:Store = @('additional-store')
    $script:repo = 'fixture-repo'
    $script:platform = 'aarch64-pc-windows-msvc'
    $script:stageInstall = $null
    function Get-SourceBuildPython { [pscustomobject]@{ Exe = 'ft-python.exe' } }
    function Split-PythonCiList { param([string]$Value) return @($Value -split ' ' | Where-Object { $_ }) }
    function Initialize-PythonAppDirectory { param([string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    function Get-FreeThreadedWheelStore { 'image-store' }
    function Get-PythonWheelTag { 'win_arm64' }
    function Install-PythonCrossSite {
        param($HostPython, $SitePackages, $RepoRoot, $Wheel, $Extras, $AllExtras, $WorkDir, $Platform, $PythonVersion, $Store, $StoreTag)
        $script:stageInstall = [pscustomobject]@{ Python = $HostPython; Extras = @($Extras); AllExtras = $AllExtras; Stores = @($Store); StoreTag = $StoreTag }
    }
    function Invoke-Arm64StageInstallCase {
        param([bool]$FreeThreaded)
        Invoke-InTestDir {
            param($dir)
            $script:work = $dir
            $abi = if ($FreeThreaded) { 'cp315t' } else { 'cp315' }
            $leg = if ($FreeThreaded) { '3.15t' } else { '3.15' }
            $wheel = [pscustomobject]@{ FullName = (Join-Path $dir "fixture-$abi-win_arm64.whl") }
            Install-Arm64StageLegSite -leg $leg -ft:$FreeThreaded -abi $abi -site (Join-Path $dir 'site') -wheel $wheel
        }
    }
    function Assert-Arm64StageInstallResult {
        param($Installed, [string]$ExpectedPython, [string]$ExpectedExtras, [string]$ExpectedStores)
        Assert-Equal $ExpectedPython $Installed.HostPython
        Assert-Equal $ExpectedExtras ($Installed.Extras -join ',')
        Assert-Equal $ExpectedPython $script:stageInstall.Python
        Assert-Equal $ExpectedStores (($script:stageInstall.Stores -join ',') -replace '\\', '/')
    }

    It 'uses the free-threaded host and its extras and wheel stores' {
        $installed = Invoke-Arm64StageInstallCase -FreeThreaded $true
        Assert-Arm64StageInstallResult -Installed $installed -ExpectedPython 'ft-python.exe' -ExpectedExtras 'gpu,test' -ExpectedStores 'image-store/deps,additional-store'
        Assert-False $script:stageInstall.AllExtras
        Assert-Equal 'cp315t-win_arm64' $script:stageInstall.StoreTag
    }

    It 'keeps the GIL host and default extras for a regular leg' {
        $installed = Invoke-Arm64StageInstallCase -FreeThreaded $false
        Assert-Arm64StageInstallResult -Installed $installed -ExpectedPython 'gil-python.exe' -ExpectedExtras default -ExpectedStores additional-store
    }
}

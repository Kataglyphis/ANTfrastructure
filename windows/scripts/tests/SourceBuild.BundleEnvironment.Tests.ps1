#requires -Version 7.0
# Environment projections cover shell syntax and PATH order; copied runtime binaries and DLL loading remain image coverage.

$script:BundleManifestSource = 'windows\scripts\build\Write-BundleManifest.ps1'

function Get-BundleTestEnvironmentAction {
    Get-BundleEnvironmentAction -InstallDir "C:\bundle's tree" -Arch arm64 -DllHome @('C:\bundle\bin', 'C:\ffmpeg') `
        -Environment @([pscustomobject]@{ Name = 'FFMPEG_BIN'; Value = 'C:\ffmpeg'; Exists = $true }, [pscustomobject]@{ Name = 'MISSING_BIN'; Value = 'absent'; Exists = $false }) `
        -PythonRoot 'C:\python' -FreeThreadedExe 'C:\python-ft\python3.14t.exe' -FreeThreadedRoot 'C:\python-ft' -WheelDir 'C:\wheels'
}

Describe 'Bundle shell environment projections' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:BundleManifestSource -FunctionName Get-BundleEnvironmentAction, ConvertTo-BundleEnvironmentScript)

    It 'projects the same ordered environment into cmd and PowerShell with the free-threaded interpreter last' {
        $actions = @(Get-BundleTestEnvironmentAction)
        Assert-Equal 'KATA_BUNDLE_ROOT,KATA_BUNDLE_ARCH,FFMPEG_BIN,PATH,KATA_PYTHON,PATH,KATA_PYTHON_FREETHREADED,PATH,KATA_WHEELS' (($actions | ForEach-Object Name) -join ',')
        $cmd = @(ConvertTo-BundleEnvironmentScript -Syntax Cmd -Action $actions -Header fixture)
        Assert-Equal '@echo off' $cmd[0]
        Assert-True ($cmd -contains 'set "PATH=C:\bundle\bin;C:\ffmpeg;%PATH%"')
        Assert-True ($cmd -contains 'set "PATH=C:\python;%PATH%"')
        Assert-True ($cmd -contains 'set "PATH=%PATH%;C:\python-ft"')
        $ps = @(ConvertTo-BundleEnvironmentScript -Syntax PowerShell -Action $actions -Header fixture)
        Assert-Equal '# fixture' $ps[0]
        Invoke-WithEnv @{ PATH = 'parent'; KATA_BUNDLE_ROOT = $null; KATA_BUNDLE_ARCH = $null; FFMPEG_BIN = $null; MISSING_BIN = $null; KATA_PYTHON = $null; KATA_PYTHON_FREETHREADED = $null; KATA_WHEELS = $null } {
            & ([scriptblock]::Create(($ps -join "`n")))
            Assert-Equal "C:\bundle's tree" $env:KATA_BUNDLE_ROOT
            Assert-Equal arm64 $env:KATA_BUNDLE_ARCH
            Assert-Equal 'C:\python;C:\bundle\bin;C:\ffmpeg;parent;C:\python-ft' $env:PATH
            Assert-Equal 'C:\ffmpeg' $env:FFMPEG_BIN
            Assert-Null ([Environment]::GetEnvironmentVariable('MISSING_BIN'))
            Assert-Equal 'C:\python\python.exe' $env:KATA_PYTHON
            Assert-Equal 'C:\python-ft\python3.14t.exe' $env:KATA_PYTHON_FREETHREADED
            Assert-Equal 'C:\wheels' $env:KATA_WHEELS
        }
    }

    It 'omits both interpreter operations when no interpreter is staged' {
        $actions = @(Get-BundleEnvironmentAction -InstallDir runtime -Arch amd64 -Environment @() -DllHome bin -WheelDir wheels)
        Assert-Equal 'KATA_BUNDLE_ROOT,KATA_BUNDLE_ARCH,PATH,KATA_WHEELS' (($actions | ForEach-Object Name) -join ',')
    }

    It 'detects putting the free-threaded interpreter ahead of the existing PATH' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:BundleManifestSource))
        Invoke-WithFunctionModule -Text $text -FunctionName ConvertTo-BundleEnvironmentScript -Find "if (`$item.Mode -eq 'Append')" -Replace 'if ($false)' -Body {
            $action = @([pscustomobject]@{ Name = 'PATH'; Value = 'C:\python-ft'; Mode = 'Append' })
            $lines = @(ConvertTo-MutBundleEnvironmentScript -Syntax PowerShell -Action $action -Header fixture)
            Invoke-WithEnv @{ PATH = 'parent' } {
                & ([scriptblock]::Create(($lines -join "`n")))
                Assert-Throws { Assert-Equal 'parent;C:\python-ft' $env:PATH } -MessagePattern 'Assert-Equal: expected'
            }
        }
    }
}

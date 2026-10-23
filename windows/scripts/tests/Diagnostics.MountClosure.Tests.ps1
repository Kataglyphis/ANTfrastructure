#requires -Version 7.0
# Mounted import fixtures do not run BuildKit, cache writes or OpenCV.

function Invoke-DiagnosticMountFixture {
    param([Parameter(Mandatory)][string]$Dockerfile, [switch]$OmitShared)
    $repo = Get-RepoRoot
    $text = [IO.File]::ReadAllText((Join-Path $repo "windows/$Dockerfile"))
    if ($OmitShared) {
        $text = $text -replace '(?m)^.*--mount=type=bind,source=windows/scripts/modules/WindowsScripts\.Shared\.psm1[^\r\n]*', ''
    }
    Invoke-InTestDir -Body { param($dir)
        $scriptPath = $null
        $mounts = [regex]::Matches($text, '--mount=type=bind,source=(?<Source>[^,\s]+),target=(?<Target>[^\s`]+)')
        Assert-True ($mounts.Count -ge 2) 'probe fixture must stage real bind mounts'
        foreach ($mount in $mounts) {
            $source = Join-Path $repo $mount.Groups['Source'].Value
            $target = Join-Path $dir ($mount.Groups['Target'].Value -replace '^C:\\', '')
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Copy-Item -LiteralPath $source -Destination $target
            if ($target.EndsWith('.ps1')) { $scriptPath = $target }
        }
        Assert-True ([bool]$scriptPath) 'probe fixture must stage its actual script'
        $imports = @(Get-TestScriptCommands -ScriptPath $scriptPath -Name Import-Module | ForEach-Object { $_.Extent.Text })
        Assert-Equal 1 $imports.Count 'probe fixture must exercise its production import'
        $source = @("`$ErrorActionPreference = 'Stop'") + $imports + @('Write-DiagnosticResult -Name ready -Ok $true')
        [IO.File]::WriteAllText($scriptPath, ($source -join "`n"))
        Invoke-TestPwshProbe -Source ("& '" + $scriptPath.Replace("'", "''") + "'")
    }
}

function Assert-DiagnosticMountReady {
    param([Parameter(Mandatory)]$Probe)
    Assert-Equal 0 $Probe.ExitCode 'probe imports require every mounted companion'
    Assert-Equal '[ OK ] ready' $Probe.Output
}

Describe 'Specialized diagnostic mount closure' {
    It 'imports both probe modules from the actual narrow Dockerfile mount layout' {
        foreach ($file in 'Dockerfile.sccache-write-probe', 'Dockerfile.opencv-video-probe') {
            Assert-DiagnosticMountReady (Invoke-DiagnosticMountFixture -Dockerfile $file)
        }
    }

    It 'rejects a missing shared companion in either container recipe' {
        foreach ($file in 'Dockerfile.sccache-write-probe', 'Dockerfile.opencv-video-probe') {
            $probe = Invoke-DiagnosticMountFixture -Dockerfile $file -OmitShared
            Assert-Throws { Assert-DiagnosticMountReady $probe } -MessagePattern 'probe imports require every mounted companion'
            Assert-Match 'WindowsScripts.Shared.psm1' $probe.Output
        }
    }
}

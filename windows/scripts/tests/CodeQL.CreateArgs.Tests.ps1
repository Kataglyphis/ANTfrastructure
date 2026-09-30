#requires -Version 7.0
# The `codeql database create` argv, whose -CodeScanningConfig seam decides whether a Windows scan is scoped.

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Import-Module (Join-Path $modDir 'WindowsCodeQL.Common.psm1') -Force -DisableNameChecking

Describe 'Get-CodeQLDatabaseCreateArgs' {

    $base = @{
        DbClusterDir = 'C:\ws\codeql-db-cluster'
        Languages    = @('cpp', 'rust')
        InnerCommand = 'cmd /c pwsh -File C:\ws\build.ps1'
        SourceRoot   = 'C:\ws'
    }

    It 'builds the cluster argv in order, one --language per language' {
        $a = @(Get-CodeQLDatabaseCreateArgs @base)
        Assert-Equal 'database' $a[0]
        Assert-Equal 'create' $a[1]
        Assert-Equal 'C:\ws\codeql-db-cluster' $a[2]
        Assert-Equal '--db-cluster' $a[3]
        Assert-Equal '--language=cpp' $a[4]
        Assert-Equal '--language=rust' $a[5]
        Assert-Equal '--command=cmd /c pwsh -File C:\ws\build.ps1' $a[6]
        Assert-True ($a -contains '--source-root=C:\ws') 'source root forwarded'
    }

    It 'passes no --codescanning-config and no --overwrite by default' {
        $a = @(Get-CodeQLDatabaseCreateArgs @base)
        Assert-Equal 0 @($a | Where-Object { $_ -like '--codescanning-config*' }).Count
        Assert-False ($a -contains '--overwrite') 'overwrite only on request'
    }

    It 'forwards an existing config as an absolute --codescanning-config' {
        Invoke-InTestDir { param($dir)
            $cfg = Join-Path $dir 'codeql-config.yml'
            Set-Content -LiteralPath $cfg -Value 'paths-ignore: [build]'
            $a = @(Get-CodeQLDatabaseCreateArgs @base -CodeScanningConfig $cfg)
            $flag = @($a | Where-Object { $_ -like '--codescanning-config=*' })
            Assert-Equal 1 $flag.Count 'exactly one config flag'
            Assert-Equal "--codescanning-config=$((Resolve-Path -LiteralPath $cfg).Path)" $flag[0]
        }
    }

    It 'refuses a named config that does not exist instead of scanning unscoped' {
        Assert-Throws -MessagePattern 'code-scanning config not found' {
            Get-CodeQLDatabaseCreateArgs @base -CodeScanningConfig 'C:\does-not-exist\codeql-config.yml'
        }
    }

    It 'adds --overwrite on request' {
        $a = @(Get-CodeQLDatabaseCreateArgs @base -Overwrite)
        Assert-True ($a -contains '--overwrite') 'overwrite forwarded'
    }
}

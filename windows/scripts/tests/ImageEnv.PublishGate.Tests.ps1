#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The Windows publish gate (WindowsImageEnv.Common + Dockerfile.publish-gate + the
# driver's call before any export). The matcher is graded by the fixture its Python
# twin reads, and each rule is mutated in a temp copy to prove the fixture bites.
# docs/windows-build-resources.md#what-the-published-image-carries

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Import-Module (Join-Path $modDir 'WindowsImageEnv.Common.psm1') -Force -DisableNameChecking

$script:imageEnvRoot = Get-RepoRoot
$script:imageEnvModule = Join-Path $modDir 'WindowsImageEnv.Common.psm1'
$script:imageEnvCases = @(Get-Content -Raw (Join-Path $script:imageEnvRoot 'linux\scripts\tests\image-env-cases.json') | ConvertFrom-Json)

# Cases whose verdict from $Leak (name, value -> reasons) disagrees with the fixture.
function Get-ImageEnvCaseMismatch {
    param([Parameter(Mandatory)][scriptblock]$Leak)
    @($script:imageEnvCases | Where-Object { ([bool]@(& $Leak $_.name $_.value).Count) -ne [bool]$_.leak } |
        ForEach-Object { "$($_.name)=$($_.value)" })
}

# Imports a copy of the gate module with one literal edit, as Get-Mut* functions.
function Import-ImageEnvMutant {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Find, [AllowEmptyString()][string]$Replace = '')
    $text = [IO.File]::ReadAllText($script:imageEnvModule)
    if (-not $text.Contains($Find)) { throw "mutant: find text is gone from the module: $Find" }
    $path = Join-Path $Dir 'WindowsImageEnv.Mutant.psm1'
    [IO.File]::WriteAllText($path, $text.Replace($Find, $Replace))
    Import-Module $path -Prefix Mut -Force -PassThru -DisableNameChecking
}

Describe 'WindowsImageEnv.Common: the matcher' {

    It 'agrees with every case of the shared fixture (verify_image_env.py reads the same file)' {
        Assert-True ($script:imageEnvCases.Count -ge 20) "fixture parse found only $($script:imageEnvCases.Count) cases"
        $bad = Get-ImageEnvCaseMismatch -Leak { param($n, $v) Get-ImageEnvLeak -Name $n -Value $v }
        Assert-Equal '' ($bad -join '; ') 'the PowerShell matcher disagrees with the fixture'
    }

    It 'the fixture holds both verdicts, so neither rule set can pass by saying one word' {
        $leaks = @($script:imageEnvCases | Where-Object { $_.leak }).Count
        Assert-True ($leaks -ge 8) "only $leaks leaking cases"
        Assert-True (($script:imageEnvCases.Count - $leaks) -ge 8) "only $($script:imageEnvCases.Count - $leaks) clean cases"
    }

    It 'names the reason, so a red gate says what to fix' {
        $r = @(Get-ImageEnvLeak -Name 'SCCACHE_WEBDAV_ENDPOINT' -Value 'http://192.168.188.116:5000')
        Assert-Equal 2 $r.Count 'the name rule and the address rule both fire on the 2026-09-23 value'
        Assert-Match '192\.168\.188\.116' ($r -join ' ')
    }

    foreach ($mutant in @(
            @{ Why = 'the name rule'; Find = 'if ($Name -match $script:BuildHostName)'; Replace = 'if ($false)' },
            @{ Why = 'the address rule'; Find = 'if ((Test-PrivateIPv4 -Text $g.Value) -and'; Replace = 'if ($false -and' },
            @{ Why = 'the VERSION exemption'; Find = "return (`$Name.ToUpperInvariant() -notlike '*VERSION*')"; Replace = 'return $true' },
            @{ Why = 'the path-fragment rule'; Find = 'if ($before.Length -gt 0 -and -not $script:Lead.Contains($before[-1])) { return $false }'; Replace = '' })) {
        It "a mutant without $($mutant.Why) fails the fixture (mutation)" {
            Invoke-InTestDir { param($dir)
                $m = Import-ImageEnvMutant -Dir $dir -Find $mutant.Find -Replace $mutant.Replace
                try {
                    $bad = @(Get-ImageEnvCaseMismatch -Leak { param($n, $v) Get-MutImageEnvLeak -Name $n -Value $v })
                    Assert-True ($bad.Count -gt 0) "the fixture did not notice $($mutant.Why) was removed"
                } finally { Remove-Module $m -Force }
            }
        }
    }
}

Describe 'WindowsImageEnv.Common: Assert-ImageEnvPublishable' {

    $clean = [ordered]@{
        Process = @{ PATH = 'C:\Windows'; SCCACHE_DIR = 'C:\sccache\v2'; SCCACHE_LOG = 'warn'; A = '1'; B = '2' }
        Machine = @{ CUDA_WINDOWS_ARM64_CURAND_VERSION = '10.4.4.72'; C = '3'; D = '4'; E = '5'; F = '6' }
        User    = @{}
    }

    It 'passes an environment with local defaults only' {
        Assert-Null (Assert-ImageEnvPublishable -Scopes $clean 6>$null)
    }

    It 'fails a Machine-scope leak and names the scope (a RUN that set it publishes it too)' {
        $leaky = [ordered]@{ Process = $clean.Process; Machine = @{} + $clean.Machine; User = @{} }
        $leaky.Machine['SCCACHE_WEBDAV_ENDPOINT'] = 'http://192.168.188.116:5000'
        Assert-Throws { Assert-ImageEnvPublishable -Scopes $leaky 6>$null } -MessagePattern 'SCCACHE_WEBDAV_ENDPOINT'
        # The throw is asserted above; here only the LEAK lines it printed first matter.
        $lines = @(& { try { Assert-ImageEnvPublishable -Scopes $leaky } catch { $null = $_ } } 6>&1 | ForEach-Object { "$_" })
        Assert-Match '\[Machine\] SCCACHE_WEBDAV_ENDPOINT' ($lines -join "`n")
    }

    It 'refuses to pass an environment it never read' {
        Assert-Throws { Assert-ImageEnvPublishable -Scopes ([ordered]@{ Process = @{ A = '1' } }) 6>$null } -MessagePattern 'never read'
    }
}

Describe 'Dockerfile.publish-gate' {

    $df = Get-Content -Raw (Join-Path $script:imageEnvRoot 'windows\Dockerfile.publish-gate')
    $afterFrom = ($df -split '(?m)^FROM ', 2)[1]

    It 'mounts the one gate module and runs the assertion' {
        Assert-Match 'source=windows/scripts/modules/WindowsImageEnv\.Common\.psm1,target=C:\\gate\\WindowsImageEnv\.Common\.psm1' $df
        Assert-Match '(?m)^\s*Assert-ImageEnvPublishable\s*$' $df
    }

    It 'declares no ARG after FROM, so nothing of its own joins the environment under test' {
        Assert-False ($afterFrom -match '(?m)^ARG ') 'an ARG after FROM is in the RUN environment the gate grades'
    }

    It 'does not run through the entrypoint (the config ENV is what ships)' {
        Assert-False ($df -match 'entrypoint\.cmd') 'VsDevCmd would add variables the image does not carry'
    }

    It 'the gate module imports nothing (the RUN mounts it alone)' {
        Assert-False ((Get-Content -Raw $script:imageEnvModule) -match '(?m)^\s*Import-Module') 'a dependency would be missing inside the gate'
    }
}

# '' when Build-Buildkit.ps1 solves the publish gate once, -NoOutput, against the final
# tag, BEFORE both exports and outside every -SkipSmokeGate branch; else the problem.
function Get-PublishGateWiringProblem {
    param([Parameter(Mandatory)][string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Invoke-BkStage' }, $true))
    $gate = @($calls | Where-Object { $_.Extent.Text -match 'Dockerfile\.publish-gate' })
    if ($gate.Count -ne 1) { return "expected one publish-gate solve, found $($gate.Count)" }
    $g = $gate[0]
    if ($g.Extent.Text -notmatch '-NoOutput') { return 'the publish gate must not export anything' }
    if ($g.Extent.Text -notmatch 'BASE_IMAGE\s*=\s*Get-BkTag \$script:FinalTagName') { return 'the gate does not grade the final tag' }
    foreach ($label in 'final-tar', 'final-push') {
        $export = @($calls | Where-Object { $_.Extent.Text -match "-Label '$label'" })
        if ($export.Count -eq 0) { return "no $label solve found (scanner rot?)" }
        if ($export[0].Extent.StartOffset -lt $g.Extent.StartOffset) { return "$label runs before the publish gate" }
    }
    for ($p = $g.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst] -and
            @($p.Clauses | Where-Object { $_.Item1.Extent.Text -match 'SkipSmokeGate' }).Count -gt 0) {
            return 'the publish gate sits in a -SkipSmokeGate branch'
        }
    }
    return ''
}

Describe 'Build-Buildkit.ps1: the publish gate runs before every export' {

    $drv = Get-Content -Raw (Join-Path $script:imageEnvRoot 'windows\Build-Buildkit.ps1')

    It 'solves Dockerfile.publish-gate against the final tag, before final-tar and final-push, never skipped' {
        Assert-Equal '' (Get-PublishGateWiringProblem -Text $drv)
    }

    It 'a driver without the call is caught (mutation)' {
        $mutant = [regex]::Replace($drv, "(?s)Invoke-BkStage -Dockerfile 'windows/Dockerfile\.publish-gate'.*?-MaxAttempts 1", '')
        Assert-True ($mutant -ne $drv) 'mutation did not apply'
        Assert-Match 'found 0' (Get-PublishGateWiringProblem -Text $mutant)
    }

    It 'a gate moved under -SkipSmokeGate is caught (mutation)' {
        $call = [regex]::Match($drv, "(?s)Invoke-BkStage -Dockerfile 'windows/Dockerfile\.publish-gate'.*?-MaxAttempts 1").Value
        Assert-True ($call.Length -gt 0) 'call not found'
        $mutant = $drv.Replace($call, "if (-not `$SkipSmokeGate) { $call }")
        Assert-Match 'SkipSmokeGate' (Get-PublishGateWiringProblem -Text $mutant)
    }
}

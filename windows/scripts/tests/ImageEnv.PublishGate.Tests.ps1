#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The Windows publish gate (WindowsImageEnv.Common + Dockerfile.publish-gate + the driver's
# three call sites). The matcher is graded by its Python twin's fixture; the driver's parent
# gate runs lifted out with a fake buildctl. docs/windows-build-resources.md#what-the-published-image-carries

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

# The scope names Assert-ImageEnvPublishable reads when no -Scopes is given, from its loop literal.
function Get-DefaultImageEnvScope {
    param([Parameter(Mandatory)][string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Assert-ImageEnvPublishable' }, $true))
    if ($fn.Count -ne 1) { throw 'Assert-ImageEnvPublishable not found' }
    $loops = @($fn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
                $n.Body.Extent.Text -match "GetEnvironmentVariables\(\`$$($n.Variable.VariablePath.UserPath)\)" }, $true))
    if ($loops.Count -ne 1) { throw "expected one loop over GetEnvironmentVariables, found $($loops.Count)" }
    @($loops[0].Condition.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
        ForEach-Object Value)
}

# Splatted into Invoke-WithFunctionModule: a mutant is a copy of the whole gate module.
$imageEnvMutantSource = @{ Text = [IO.File]::ReadAllText($script:imageEnvModule) }

# Runs $Body, given the variable's name, with a uniquely named Process variable that leaks a LAN
# address: unique, because this host's own Machine scope may leak too.
function Invoke-WithLeakingProcessVariable {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $name = 'KATA_PUBLISH_GATE_PROBE_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Invoke-WithEnv @{ $name = 'http://10.0.0.1:5000' } { & $Body $name }
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
            Invoke-WithFunctionModule @imageEnvMutantSource -Find $mutant.Find -Replace $mutant.Replace -Body {
                $bad = @(Get-ImageEnvCaseMismatch -Leak { param($n, $v) Get-MutImageEnvLeak -Name $n -Value $v })
                Assert-True ($bad.Count -gt 0) "the fixture did not notice $($mutant.Why) was removed"
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

    It 'with no -Scopes it grades the live Process environment (the path the gate''s RUN takes)' {
        Invoke-WithLeakingProcessVariable { param($name)
            Assert-Throws { Assert-ImageEnvPublishable 6>$null } -MessagePattern $name
        }
    }

    # A test cannot write the Machine scope without admin, so the list itself is pinned.
    It 'with no -Scopes it reads exactly Process, Machine and User' {
        Assert-Equal 'Process,Machine,User' ((Get-DefaultImageEnvScope -Text ([IO.File]::ReadAllText($script:imageEnvModule))) -join ',')
    }

    It 'a mutant that skips the Process scope misses a leaking variable, so the live test above bites (mutation)' {
        Invoke-WithFunctionModule @imageEnvMutantSource -Find "foreach (`$s in 'Process', 'Machine', 'User')" -Replace "foreach (`$s in 'Machine', 'User')" -Body {
            Invoke-WithLeakingProcessVariable { param($name)
                $msg = try { Assert-MutImageEnvPublishable 6>$null; '' } catch { $_.Exception.Message }
                Assert-False ($msg -match $name) 'the mutant read the Process scope after all'
            }
        }
    }

    It 'a mutant that drops Machine and User fails the scope-list pin (mutation)' {
        $text = [IO.File]::ReadAllText($script:imageEnvModule)
        $find = "'Process', 'Machine', 'User'"
        Assert-True $text.Contains($find) 'mutation target is gone'
        Assert-Equal 'Process' ((Get-DefaultImageEnvScope -Text $text.Replace($find, "'Process'")) -join ',')
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

# The CommandAsts named $Name, and the name of the function a node sits in ('' at script level).
function Find-DriverCall {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq $Name }.GetNewClosure(), $true))
}
function Get-EnclosingFunctionName {
    param([Parameter(Mandatory)]$Node)
    for ($p = $Node.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
    }
    ''
}

# '' when Build-Buildkit.ps1 wires the publish gate as documented, else the first problem. ONE
# Dockerfile.publish-gate solve, in Invoke-BkPublishGate (-NoOutput -NoParentGate, BASE_IMAGE =
# $Image). The helper runs on the final tag before both exports and outside every -SkipSmokeGate
# branch, on the toolchain right after its solve, and in Invoke-BkStage before buildctl.
function Get-PublishGateWiringProblem {
    param([Parameter(Mandatory)][string]$Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $stages = Find-DriverCall $ast 'Invoke-BkStage'
    $solve = @($stages | Where-Object { $_.Extent.Text -match 'Dockerfile\.publish-gate' })
    if ($solve.Count -ne 1) { return "expected one publish-gate solve, found $($solve.Count)" }
    $s = $solve[0]
    if ((Get-EnclosingFunctionName $s) -ne 'Invoke-BkPublishGate') { return 'the publish-gate solve is not inside Invoke-BkPublishGate' }
    if ($s.Extent.Text -notmatch '-NoOutput') { return 'the publish gate must not export anything' }
    if ($s.Extent.Text -notmatch '-NoParentGate') { return 'the publish gate would gate its own BASE_IMAGE' }
    if ($s.Extent.Text -notmatch 'BASE_IMAGE\s*=\s*\$Image\b') { return 'the gate does not grade the image it is handed' }

    $gates = Find-DriverCall $ast 'Invoke-BkPublishGate'
    $final = @($gates | Where-Object { $_.Extent.Text -match '-Image \(Get-BkTag \$script:FinalTagName\)' })
    if ($final.Count -ne 1) { return "expected one publish gate on the final tag, found $($final.Count)" }
    $g = $final[0]
    foreach ($label in 'final-tar', 'final-push') {
        $export = @($stages | Where-Object { $_.Extent.Text -match "-Label '$label'" })
        if ($export.Count -eq 0) { return "no $label solve found (scanner rot?)" }
        if ($export[0].Extent.StartOffset -lt $g.Extent.StartOffset) { return "$label runs before the publish gate" }
    }
    for ($p = $g.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst] -and
            @($p.Clauses | Where-Object { $_.Item1.Extent.Text -match 'SkipSmokeGate' }).Count -gt 0) {
            return 'the publish gate sits in a -SkipSmokeGate branch'
        }
    }

    $tcSolve = @($stages | Where-Object { $_.Extent.Text -match 'Dockerfile\.toolchain-builder' })
    $tcGate = @($gates | Where-Object { $_.Extent.Text -match "-Image \(Get-BkTag 'windows-toolchain'\)" })
    if ($tcSolve.Count -ne 1 -or $tcGate.Count -ne 1) {
        return "expected one toolchain solve and one gate on the toolchain, found $($tcSolve.Count) and $($tcGate.Count)"
    }
    if (-not [object]::ReferenceEquals($tcGate[0].Parent.Parent, $tcSolve[0].Parent.Parent) -or
        $tcGate[0].Extent.StartOffset -lt $tcSolve[0].Extent.EndOffset) {
        return 'the toolchain is not graded right after its solve, in the same block'
    }

    $hook = @($gates | Where-Object { (Get-EnclosingFunctionName $_) -eq 'Invoke-BkStage' })
    if ($hook.Count -ne 1) { return "expected Invoke-BkStage to gate an unbuilt parent once, found $($hook.Count)" }
    if ($hook[0].Extent.Text -notmatch '-Image \$parent\b') { return 'the parent gate grades something other than BASE_IMAGE' }
    $buildctl = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -eq '$BuildCtl' }, $true) |
            Where-Object { (Get-EnclosingFunctionName $_) -eq 'Invoke-BkStage' })
    if ($buildctl.Count -eq 0) { return 'no buildctl call in Invoke-BkStage (scanner rot?)' }
    if ($hook[0].Extent.StartOffset -gt $buildctl[0].Extent.StartOffset) { return 'the parent gate runs after the stage solves' }
    ''
}

Describe 'Build-Buildkit.ps1: where the publish gate runs' {

    $drv = Get-Content -Raw (Join-Path $script:imageEnvRoot 'windows\Build-Buildkit.ps1')
    $finalCall = 'Invoke-BkPublishGate -Image (Get-BkTag $script:FinalTagName)'

    It 'one solve, in Invoke-BkPublishGate: final tag before both exports and never skipped, the toolchain, an unbuilt parent' {
        Assert-Equal '' (Get-PublishGateWiringProblem -Text $drv)
    }

    foreach ($mutant in @(
            @{ Why = 'a driver without the final call'; Find = $finalCall; Replace = ''; Want = 'final tag, found 0' },
            @{ Why = 'a final gate moved under -SkipSmokeGate'; Find = $finalCall
                Replace = "if (-not `$SkipSmokeGate) { $finalCall }"; Want = 'SkipSmokeGate' },
            @{ Why = 'a driver that stops grading the fresh toolchain'; Replace = ''; Want = 'gate on the toolchain'
                Find = "Invoke-BkPublishGate -Image (Get-BkTag 'windows-toolchain') -Label 'publish-gate:toolchain'" },
            @{ Why = 'a gate solve without -NoParentGate (it would recurse into itself)'; Find = '-NoOutput -NoParentGate'
                Replace = '-NoOutput'; Want = 'its own BASE_IMAGE' })) {
        It "$($mutant.Why) is caught (mutation)" {
            Assert-True $drv.Contains($mutant.Find) 'mutation target is gone'
            Assert-Match $mutant.Want (Get-PublishGateWiringProblem -Text $drv.Replace($mutant.Find, $mutant.Replace))
        }
    }
}

# What Invoke-BkStage reads besides the driver's own state, and a buildctl that records each
# solve as '<Dockerfile>|<BASE_IMAGE>' and fails the one named $FailDockerfile.
$script:gateScenarioPrelude = @'
param($Dir, $FailDockerfile)
$script:Solves = [System.Collections.Generic.List[string]]::new()
$script:LogDir = $Dir; $script:RunId = 'test'; $script:StageTimings = @{}
$repoRoot = $Dir; $SkipHostChecks = $true; $NoCacheStage = @(); $NoCache = $false
$ImportCacheRef = ''; $ExportCacheRef = ''; $TargetArch = 'amd64'; $BuildArg = @()
function Assert-StageDiskHeadroom { }
function Set-BuildPhase { param($Name) }
function Invoke-TransientCooldown { $false }
$BuildCtl = {
    $file = "$($args | Where-Object { "$_" -like 'filename=*' })" -replace '^filename=', ''
    $base = "$($args | Where-Object { "$_" -like 'build-arg:BASE_IMAGE=*' })" -replace '^build-arg:BASE_IMAGE=', ''
    $script:Solves.Add("$file|$base")
    $global:LASTEXITCODE = if ($FailDockerfile -and $file -eq $FailDockerfile) { 1 } else { 0 }
}
'@

# Lifts Invoke-BkStage and Invoke-BkPublishGate (plus the driver's own initialisers of the state
# they keep) out of $Driver over the prelude above, runs $Scenario there, and returns the solves
# in order and the error message, if any, from a fresh test directory. -Find/-Replace mutate
# the lifted functions.
function Invoke-GateScenario {
    param([Parameter(Mandatory)][string]$Driver, [Parameter(Mandatory)][scriptblock]$Scenario,
        [string]$FailDockerfile = '', [string]$Find = '', [AllowEmptyString()][string]$Replace = '')
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Driver, [ref]$null, [ref]$null)
    $state = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -in @('$script:NoCacheStageMatched', '$script:BkBuiltTags', '$script:BkGatedImages') }, $true) |
            ForEach-Object { $_.Extent.Text })
    if ($state.Count -ne 3) { throw "scenario: found $($state.Count) of the driver's three state initialisers" }
    Invoke-InTestDir { param($dir)
        $m = Import-FunctionModule -Text $Driver -FunctionName 'Invoke-BkStage', 'Invoke-BkPublishGate' -Dir $dir -Prefix Scn `
            -Prelude ($script:gateScenarioPrelude + "`n" + ($state -join "`n")) -Find $Find -Replace $Replace -ArgumentList $dir, $FailDockerfile
        try {
            $err = ''
            try { $null = & $m $Scenario 6>$null } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Solves = (@(& $m { $script:Solves }) -join '; '); Error = $err }
        } finally { Remove-Module $m -Force }
    }
}

Describe 'Build-Buildkit.ps1: a parent this run did not build is graded before a stage inherits its ENV' {

    $drv = Get-Content -Raw (Join-Path $script:imageEnvRoot 'windows\Build-Buildkit.ps1')
    $oneStage = { Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Tag 'img:media' -BuildArgs @{ BASE_IMAGE = 'img:toolchain' } }
    $chain = {
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Tag 'img:toolchain' -BuildArgs @{ BASE_IMAGE = 'img:sdk' }
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Tag 'img:media' -BuildArgs @{ BASE_IMAGE = 'img:toolchain' }
        Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm-migraphx' -Tag 'img:mgx' -BuildArgs @{ BASE_IMAGE = 'img:sdk' }
    }

    # Want is a regex over the solves; a case without Find runs the real driver, one with Find a mutant.
    foreach ($case in @(
            @{ Why = 'grades an unbuilt BASE_IMAGE first, then solves the stage'; Scenario = $oneStage
                Want = '^' + [regex]::Escape('Dockerfile.publish-gate|img:toolchain; Dockerfile.media-builder|img:toolchain') + '$' },
            @{ Why = 'grades neither a parent this run built nor one it already graded'; Scenario = $chain
                Want = '^' + [regex]::Escape('Dockerfile.publish-gate|img:sdk; Dockerfile.toolchain-builder|img:sdk; ' +
                    'Dockerfile.media-builder|img:toolchain; Dockerfile.rocm-migraphx|img:sdk') + '$' },
            @{ Why = 'the gate grades exactly the image it is handed, never that image''s own parent'
                Scenario = { Invoke-BkPublishGate -Image 'img:final' }; Want = '^Dockerfile\.publish-gate\|img:final$' },
            @{ Why = 'a driver without the parent gate solves the stage ungraded, so the first case bites (mutation)'
                Scenario = $oneStage; Find = 'if (-not $NoParentGate -and $parent -and'; Replace = 'if ($false -and'
                Want = '^Dockerfile\.media-builder\|img:toolchain$' },
            @{ Why = 'a driver that forgets what it built re-grades its own output, so the second case bites (mutation)'
                Scenario = $chain; Find = 'if ($Tag) { $null = $script:BkBuiltTags.Add($Tag) }'; Replace = ''
                Want = 'Dockerfile\.publish-gate\|img:toolchain' })) {
        It $case.Why {
            $find = if ($case.ContainsKey('Find')) { $case.Find } else { '' }
            $replace = if ($case.ContainsKey('Replace')) { $case.Replace } else { '' }
            $r = Invoke-GateScenario -Driver $drv -Scenario $case.Scenario -Find $find -Replace $replace
            Assert-Equal '' $r.Error
            Assert-Match $case.Want $r.Solves
        }
    }

    It 'a stale parent stops the run before the stage solves, and the error says to rebuild it' {
        $r = Invoke-GateScenario -Driver $drv -Scenario $oneStage -FailDockerfile 'Dockerfile.publish-gate'
        Assert-Equal 'Dockerfile.publish-gate|img:toolchain' $r.Solves 'the stage must not solve on a stale parent'
        Assert-Match 'img:toolchain was not built by this run' $r.Error
        Assert-Match 'Rebuild it' $r.Error
    }
}

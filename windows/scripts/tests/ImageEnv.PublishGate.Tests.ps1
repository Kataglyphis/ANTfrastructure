#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The publish gate, graded by its Python twin's fixture: see docs/windows-build-resources.md#what-the-published-image-carries

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Import-Module (Join-Path $modDir 'WindowsImageEnv.Common.psm1') -Force -DisableNameChecking

$script:imageEnvRoot = Get-RepoRoot
$script:bkDriver = Get-Content -Raw (Join-Path $script:imageEnvRoot 'windows\Build-Buildkit.ps1')
# Three solves: one unbuilt parent graded first, one built parent, one parent already graded.
$script:gateChain = {
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.toolchain-builder' -Tag 'img:toolchain' -BuildArgs @{ BASE_IMAGE = 'img:sdk' }
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Tag 'img:media' -BuildArgs @{ BASE_IMAGE = 'img:toolchain' }
    Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm-migraphx' -Tag 'img:mgx' -BuildArgs @{ BASE_IMAGE = 'img:sdk' }
}
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
    $ast = ConvertTo-TestScriptAst -Text $Text
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

# Uniquely named, because this host's own Machine scope may leak a LAN address too.
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
        $r = @(Get-ImageEnvLeak -Name 'SCCACHE_WEBDAV_ENDPOINT' -Value 'http://10.0.0.16:5000')
        Assert-Equal 2 $r.Count 'the name rule and the address rule both fire on the 2026-09-23 value'
        Assert-Match '10\.0\.0\.16' ($r -join ' ')
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
        $leaky.Machine['SCCACHE_WEBDAV_ENDPOINT'] = 'http://10.0.0.16:5000'
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
    Get-TestAstCommands -Ast $Ast -Name $Name
}
function Get-EnclosingFunctionName {
    param([Parameter(Mandatory)]$Node)
    $parent = Get-TestAstAncestor -Node $Node -Type ([Management.Automation.Language.FunctionDefinitionAst]) -First
    if ($parent) { return $parent.Name }
    ''
}
function Find-DriverCallText {
    param([object[]]$Calls, [string]$Pattern)
    $Calls | Where-Object { $_.Extent.Text -match $Pattern }
}
function Get-UniqueDriverCall {
    param([object[]]$Calls, [string]$Pattern, [string]$Label)
    $foundCalls = @(Find-DriverCallText -Calls $Calls -Pattern $Pattern)
    $problem = if ($foundCalls.Count -eq 1) { '' } else { "expected one $Label, found $($foundCalls.Count)" }
    $call = if ($foundCalls.Count -eq 1) { $foundCalls[0] } else { $null }
    return [pscustomobject]@{ Call = $call; Problem = $problem }
}

function Get-DriverCallProblem {
    param([object[]]$Calls, [string]$Pattern, [string]$Label, [scriptblock]$Check)
    $match = Get-UniqueDriverCall -Calls $Calls -Pattern $Pattern -Label $Label
    if ($match.Problem) { return $match.Problem }
    return & $Check $match.Call
}

function Get-PublishGateSolveExportProblem {
    param([Parameter(Mandatory)][object[]]$Stages, [Parameter(Mandatory)][object[]]$Gates)
    $problem = Get-DriverCallProblem -Calls $Stages -Pattern 'Dockerfile\.publish-gate' -Label 'publish-gate solve' -Check { param($s)
        if ((Get-EnclosingFunctionName $s) -ne 'Invoke-BkPublishGate') { return 'the publish-gate solve is not inside Invoke-BkPublishGate' }
        if ($s.Extent.Text -notmatch '-NoOutput') { return 'the publish gate must not export anything' }
        if ($s.Extent.Text -notmatch '-NoParentGate') { return 'the publish gate would gate its own BASE_IMAGE' }
        if ($s.Extent.Text -notmatch 'BASE_IMAGE\s*=\s*\$Image\b') { return 'the gate does not grade the image it is handed' }
        return ''
    }
    if ($problem) { return $problem }
    return Get-DriverCallProblem -Calls $Gates -Pattern '-Image \(Get-BkTag \$script:FinalTagName\)' -Label 'publish gate on the final tag' -Check { param($g)
    foreach ($label in 'final-tar', 'final-push') {
        $export = @(Find-DriverCallText -Calls $Stages -Pattern "-Label '$label'")
        if ($export.Count -eq 0) { return "no $label solve found (scanner rot?)" }
        if ($export[0].Extent.StartOffset -lt $g.Extent.StartOffset) { return "$label runs before the publish gate" }
    }
    if (Get-TestAstAncestor -Node $g -Type ([Management.Automation.Language.IfStatementAst]) -First -Predicate {
        param($branch) @($branch.Clauses | Where-Object { $_.Item1.Extent.Text -match 'SkipSmokeGate' }).Count -gt 0
    }) { return 'the publish gate sits in a -SkipSmokeGate branch' }
    return ''
    }
}

function Get-PublishGateToolchainProblem {
    param([Parameter(Mandatory)][object[]]$Stages, [Parameter(Mandatory)][object[]]$Gates)
    $tcSolve = @(Find-DriverCallText -Calls $Stages -Pattern 'Dockerfile\.toolchain-builder')
    $tcGate = @(Find-DriverCallText -Calls $Gates -Pattern "-Image \(Get-BkTag 'windows-toolchain'\)")
    if ($tcSolve.Count -ne 1 -or $tcGate.Count -ne 1) {
        return "expected one toolchain solve and one gate on the toolchain, found $($tcSolve.Count) and $($tcGate.Count)"
    }
    if (-not [object]::ReferenceEquals($tcGate[0].Parent.Parent, $tcSolve[0].Parent.Parent) -or
        $tcGate[0].Extent.StartOffset -lt $tcSolve[0].Extent.EndOffset) {
        return 'the toolchain is not graded right after its solve, in the same block'
    }
    return ''
}

function Get-ParentStageBuildctlCall {
    param([Parameter(Mandatory)]$Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.InvocationOperator -eq 'Ampersand' -and $n.CommandElements[0].Extent.Text -eq '$BuildCtl' }, $true) |
            Where-Object { (Get-EnclosingFunctionName $_) -eq 'Invoke-BkStage' })
}

function Get-ParentGateBuildctlProblem {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)]$Hook)
    $buildctl = @(Get-ParentStageBuildctlCall -Ast $Ast)
    if ($buildctl.Count -eq 0) { return 'no buildctl call in Invoke-BkStage (scanner rot?)' }
    if ($Hook.Extent.StartOffset -gt $buildctl[0].Extent.StartOffset) { return 'the parent gate runs after the stage solves' }
    return ''
}

function Get-PublishGateParentProblem {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][object[]]$Gates)
    $hook = @($Gates | Where-Object { (Get-EnclosingFunctionName $_) -eq 'Invoke-BkStage' })
    if ($hook.Count -ne 1) { return "expected Invoke-BkStage to gate an unbuilt parent once, found $($hook.Count)" }
    if ($hook[0].Extent.Text -notmatch '-Image \$parent\b') { return 'the parent gate grades something other than BASE_IMAGE' }
    return Get-ParentGateBuildctlProblem -Ast $Ast -Hook $hook[0]
}

# '' when Build-Buildkit.ps1 wires the publish gate as documented, else the first problem.
function Get-PublishGateWiringProblem {
    param([Parameter(Mandatory)][string]$Text)
    $ast = ConvertTo-TestScriptAst -Text $Text
    $stages = @(Find-DriverCall $ast 'Invoke-BkStage')
    $gates = @(Find-DriverCall $ast 'Invoke-BkPublishGate')
    $problem = Get-PublishGateSolveExportProblem -Stages $stages -Gates $gates
    if ($problem) { return $problem }
    $problem = Get-PublishGateToolchainProblem -Stages $stages -Gates $gates
    if ($problem) { return $problem }
    return Get-PublishGateParentProblem -Ast $ast -Gates $gates
}

Describe 'Build-Buildkit.ps1: where the publish gate runs' {

    $drv = $script:bkDriver
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

# A fake buildctl records each solve as '<Dockerfile>|<BASE_IMAGE>', fails $FailDockerfile, and serves $Config to `debug get`.
$script:gateScenarioPrelude = @'
param($Dir, $FailDockerfile, $ImageEnvModule, $Config, $NoMetadata, $FailAttempts)
Import-Module $ImageEnvModule -Force -DisableNameChecking
$script:Solves = [System.Collections.Generic.List[string]]::new()
$script:ConfigReads = 0
$script:SolveAttemptCount = 0
$script:CooldownCalls = [System.Collections.Generic.List[string]]::new()
$script:LogDir = $Dir; $script:RunId = 'test'; $script:StageTimings = @{}
$script:BkHistoryGateValue = @{ EndpointHost = @('10.0.0.26'); Bucket = 'kata-bucket'; Region = 'kata-region' }
$repoRoot = $Dir; $SkipHostChecks = $true; $NoCacheStage = @(); $NoCache = $false
$ImportCacheRef = ''; $ExportCacheRef = ''; $TargetArch = 'amd64'; $BuildArg = @()
function Assert-StageDiskHeadroom { }
function Set-BuildPhase { param($Name) }
function Invoke-TransientCooldown {
    param($Tail, $PreviousTail, $Attempt, $MaxAttempts, $Label, $CooldownSeconds)
    [void]$script:CooldownCalls.Add("$Attempt/$MaxAttempts")
    return ($FailAttempts -gt 0 -and $Attempt -lt $MaxAttempts)
}
$BuildCtl = {
    if ($args[0] -eq 'debug') { $script:ConfigReads++; $global:LASTEXITCODE = 0; return $Config }
    $file = "$($args | Where-Object { "$_" -like 'filename=*' })" -replace '^filename=', ''
    $base = "$($args | Where-Object { "$_" -like 'build-arg:BASE_IMAGE=*' })" -replace '^build-arg:BASE_IMAGE=', ''
    $script:Solves.Add("$file|$base")
    $script:SolveAttemptCount++
    $meta = [array]::IndexOf([string[]]$args, '--metadata-file')
    if ($meta -ge 0 -and -not $NoMetadata) { Set-Content -LiteralPath $args[$meta + 1] -Value ('{"containerimage.config.digest":"sha256:' + ('ab' * 32) + '"}') }
    $global:LASTEXITCODE = if ($FailAttempts -gt 0 -and $script:SolveAttemptCount -le $FailAttempts) { 1 }
        elseif ($FailDockerfile -and $file -eq $FailDockerfile) { 1 } else { 0 }
}
'@

# Image configs for the fake: what the secret form leaves, and the 2026-10-17 S3 ARG.
$script:cleanConfigJson = @{ history = @(@{ created_by = 'RUN |1 SCCACHE_LOG=warn pwsh -Command echo' }); config = @{ Env = @('PATH=C:\Windows') } } | ConvertTo-Json -Depth 5 -Compress
$script:leakyConfigJson = @{ history = @(@{ created_by = 'ARG SCCACHE_ENDPOINT=http://10.0.0.26:3900' }); config = @{ Env = @('PATH=C:\Windows') } } | ConvertTo-Json -Depth 5 -Compress

# Runs $Scenario over the driver's lifted gate functions; -Find/-Replace mutate them.
function Invoke-GateScenario {
    param([Parameter(Mandatory)][string]$Driver, [Parameter(Mandatory)][scriptblock]$Scenario,
        [string]$FailDockerfile = '', [string]$Find = '', [AllowEmptyString()][string]$Replace = '',
        [string]$Config = $script:cleanConfigJson, [switch]$NoMetadata, [int]$FailAttempts = 0)
    $ast = ConvertTo-TestScriptAst -Text $Driver
    $state = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -in @('$script:NoCacheStageMatched', '$script:BkBuiltTags', '$script:BkGatedImages') }, $true) |
            ForEach-Object { $_.Extent.Text })
    if ($state.Count -ne 3) { throw "scenario: found $($state.Count) of the driver's three state initialisers" }
    Invoke-InTestDir { param($dir)
        $m = Import-FunctionModule -Text $Driver -FunctionName 'Test-BkParentNeedsGate', 'Get-BkStageCacheArguments',
            'Get-BkStageBaseArguments', 'Get-BkStageBuildArgOptions', 'Get-BkStageMetadataFile', 'Get-BkStageRetryTail',
            'Invoke-BkStage', 'Invoke-BkPublishGate', 'Invoke-BkHistoryGate' -Dir $dir -Prefix Scn `
            -Prelude ($script:gateScenarioPrelude + "`n" + ($state -join "`n")) -Find $Find -Replace $Replace `
            -ArgumentList $dir, $FailDockerfile, $script:imageEnvModule, $Config, ([bool]$NoMetadata), $FailAttempts
        try {
            $err = ''
            try { $null = & $m $Scenario 6>$null } catch { $err = $_.Exception.Message }
            [pscustomobject]@{ Solves = (@(& $m { $script:Solves }) -join '; '); Error = $err; Reads = (& $m { $script:ConfigReads })
                Cooldowns = (@(& $m { $script:CooldownCalls }) -join '; '); Leftover = @(Get-ChildItem -LiteralPath $dir -Filter '*.metadata.json').Count }
        } finally { Remove-Module $m -Force }
    }
}

Describe 'Build-Buildkit.ps1: a parent this run did not build is graded before a stage inherits its ENV' {

    $drv = $script:bkDriver
    $oneStage = { Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-builder' -Tag 'img:media' -BuildArgs @{ BASE_IMAGE = 'img:toolchain' } }
    $chain = $script:gateChain

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
                Scenario = $oneStage; Find = 'if (Test-BkParentNeedsGate -Parent $parent -NoParentGate:$NoParentGate) {'; Replace = 'if ($false) {'
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

Describe 'Build-Buildkit.ps1: the history gate grades every image a stage exports' {

    $drv = $script:bkDriver
    # The chain above, then the push re-export of a solve already graded.
    $chain = [scriptblock]::Create("$script:gateChain`nInvoke-BkStage -Dockerfile 'windows/Dockerfile' -Label 'final-push' -OutputSpec 'type=image,name=x,push=true' -BuildArgs @{ BASE_IMAGE = 'img:mgx' }")
    $gateCall = 'if ($metaFile) { Invoke-BkHistoryGate -MetadataFile $metaFile -Image $Tag -Label $Label }'

    It 'reads the config of each exported image, never of a -NoOutput gate or an -OutputSpec re-export, and leaves no metadata file' {
        $r = Invoke-GateScenario -Driver $drv -Scenario $chain
        Assert-Equal '' $r.Error
        Assert-Equal 3 $r.Reads 'the three stage images; the publish gate and the push re-export are not read'
        Assert-Equal 0 $r.Leftover
    }

    It 'fails a stage whose history names the S3 endpoint, after its solve, naming the image and the entry' {
        $r = Invoke-GateScenario -Driver $drv -Scenario $chain -Config $script:leakyConfigJson
        Assert-Match 'history gate FAILED: \d+ finding\(s\) in the history and config of img:toolchain \(history\[0\]\)' $r.Error
        Assert-Equal 'Dockerfile.publish-gate|img:sdk; Dockerfile.toolchain-builder|img:sdk' $r.Solves 'the next stage must not solve on it'
        Assert-False $r.Error.Contains('10.0.0.26') 'the error names the value'
    }

    It 'fails closed when buildctl wrote no config digest' {
        $r = Invoke-GateScenario -Driver $drv -Scenario $chain -NoMetadata
        Assert-Match 'buildctl wrote no config digest for img:toolchain' $r.Error
        Assert-Equal 0 $r.Reads
    }

    It 'a driver without the gate call ships the leaking history, so the second case bites (mutation)' {
        Assert-True $drv.Contains($gateCall) 'mutation target is gone'
        $r = Invoke-GateScenario -Driver $drv -Scenario $chain -Config $script:leakyConfigJson -Find $gateCall -Replace ''
        Assert-Equal '' $r.Error
    }
}

function Assert-BkRetryBudget {
    param([Parameter(Mandatory)][string]$Driver, [Parameter(Mandatory)][scriptblock]$Scenario,
        [Parameter(Mandatory)][int]$FailAttempts, [Parameter(Mandatory)][int]$ExpectedAttempts,
        [Parameter(Mandatory)][string]$ExpectedCooldowns)
    $result = Invoke-GateScenario -Driver $Driver -Scenario $Scenario -FailAttempts $FailAttempts
    Assert-Equal '' $result.Error
    Assert-Equal $ExpectedAttempts @($result.Solves -split '; ').Count
    Assert-Equal $ExpectedCooldowns $result.Cooldowns
}

Describe 'Build-Buildkit.ps1: per-stage retry budgets' {
    $driver = $script:bkDriver
    $defaultStage = { Invoke-BkStage -Dockerfile 'windows/Dockerfile.base' -NoOutput }
    $mergeStage = { Invoke-BkStage -Dockerfile 'windows/Dockerfile.media-merge-builder' -NoOutput -MaxAttempts 5 }

    It 'uses the three-attempt default and forwards the full budget to cooldown' {
        Assert-BkRetryBudget -Driver $driver -Scenario $defaultStage -FailAttempts 2 -ExpectedAttempts 3 `
            -ExpectedCooldowns '1/3; 2/3'
    }

    It 'lets the media merge use five attempts and fails after the fifth' {
        Assert-BkRetryBudget -Driver $driver -Scenario $mergeStage -FailAttempts 4 -ExpectedAttempts 5 `
            -ExpectedCooldowns '1/5; 2/5; 3/5; 4/5'
        $red = Invoke-GateScenario -Driver $driver -Scenario $mergeStage -FailAttempts 5
        Assert-Match 'buildctl failed \(exit 1\)' $red.Error
        Assert-Equal 5 @($red.Solves -split '; ').Count
        Assert-Equal '1/5; 2/5; 3/5; 4/5; 5/5' $red.Cooldowns
    }

    It 'detects a loop that stops one attempt early (mutation)' {
        $mutant = Invoke-GateScenario -Driver $driver -Scenario $mergeStage -FailAttempts 4 `
            -Find 'for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)' `
            -Replace 'for ($attempt = 1; $attempt -lt $MaxAttempts; $attempt++)'
        Assert-Throws -Body { Assert-Equal 5 @($mutant.Solves -split '; ').Count } -MessagePattern 'expected \[5\] but got \[4\]'
    }
}

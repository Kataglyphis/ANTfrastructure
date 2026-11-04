#requires -Version 7.0
# Invoke-BkVariantChain.ps1 and the driver's -PushOnly: order, failure verdicts and wiring with fake builds; not a real solve or upload.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsBkVariantChain.Common.psm1') -Force

function New-ChainPlan {
    param([string[]]$Variant = @('default', 'nvidia', 'rocm'), [switch]$ConcurrentPush, [string[]]$BuildArg = @(), [hashtable]$BuildOption = @{}, [string[]]$Stages = @('torch', 'final'), [string]$TargetArch = 'amd64')
    return @(Get-BkVariantChainPlan -Variant $Variant -Repository 'ghcr.io/o/r' -ChainId '20261104-120000' -BuildDate '2026-11-04T11:00:00Z' `
            -ConcurrentPush:$ConcurrentPush -BuildArg $BuildArg -BuildOption $BuildOption -Stages $Stages -TargetArch $TargetArch)
}

# A process stand-in: exited with -ExitCode, or running until waited for or killed.
function New-FakePush {
    param([int]$ExitCode = 0, [switch]$Running, [System.Collections.Generic.List[string]]$Log, [string]$Name)
    $p = [pscustomobject]@{ HasExited = (-not $Running); ExitCode = $ExitCode; Name = $Name; Log = $Log }
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { $this.HasExited = $true; $this.Log.Add("wait $($this.Name)") }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($tree) $this.HasExited = $true; $this.Log.Add("kill $($this.Name) tree=$tree") }
    return $p
}

# Records the order; -FailBuild throws for that variant and -PushExit names a push's exit code.
function Invoke-FakeChain {
    param([object[]]$Plan, [switch]$ConcurrentPush, [string]$FailBuild = '', [hashtable]$PushExit = @{}, [switch]$PushRunning)
    $log = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.List[hashtable]]::new()
    $message = ''
    $build = {
        param($Parameters)
        $name = if ($Parameters.ContainsKey('Variant')) { $Parameters['Variant'] } else { 'default' }
        $log.Add("build $name")
        $seen.Add($Parameters)
        if ($name -eq $FailBuild) { throw "stage died in $name" }
    }.GetNewClosure()
    $start = {
        param($Step)
        $log.Add("push $($Step.Name)")
        $code = if ($PushExit.ContainsKey($Step.Name)) { $PushExit[$Step.Name] } else { 0 }
        return New-FakePush -ExitCode $code -Running:$PushRunning -Log $log -Name $Step.Name
    }.GetNewClosure()
    try {
        Invoke-BkVariantChain -Plan $Plan -ConcurrentPush:$ConcurrentPush -InvokeBuild $build -StartPush $start
    } catch { $message = $_.Exception.Message }
    return [pscustomobject]@{ Log = @($log); Parameters = @($seen); Error = $message }
}

Describe 'Get-BkVariantChainPlan' {
    It 'names each lane''s own tag, one stamp on build and push, and a final-only push child' {
        $plan = New-ChainPlan -ConcurrentPush
        Assert-Equal 'ghcr.io/o/r:winamd64,ghcr.io/o/r:winamd64-nvidia,ghcr.io/o/r:winamd64-rocm' (($plan | ForEach-Object PushRef) -join ',') 'lane tags'
        $rocm = $plan[2]
        Assert-Equal 'rocm' $rocm.BuildParameters['Variant'] 'in-process variant'
        Assert-Equal '2026-11-04T11:00:00Z' $rocm.BuildParameters['BuildDate'] 'build stamp'
        Assert-Equal 'torch,final' ($rocm.BuildParameters['Stages'] -join ',') 'the array stays an array in process'
        Assert-Equal '-TargetArch amd64 -BuildDate 2026-11-04T11:00:00Z -Stages final -PushOnly -PushRef ghcr.io/o/r:winamd64-rocm -ParentRunId 20261104-120000 -NoResourceLog -Variant rocm' ($rocm.PushArguments -join ' ') 'the push child'
        Assert-False ($plan[0].BuildParameters.ContainsKey('Variant')) 'default passes no -Variant'
        Assert-False ($plan[0].PushArguments -contains '-Variant') 'default push passes no -Variant'
    }

    It 'forwards the one -BuildArg to the build and the push alike' {
        $step = (New-ChainPlan -Variant nvidia -BuildArg 'A=1' -ConcurrentPush)[0]
        Assert-Equal 'A=1' ($step.BuildParameters['BuildArg'] -join ',') 'build'
        Assert-Match '-BuildArg A=1$' ($step.PushArguments -join ' ') 'push'
    }

    It 'refuses a repeated variant' {
        Assert-Throws { New-ChainPlan -Variant nvidia, nvidia } -MessagePattern 'named twice'
    }

    It 'refuses rocm off amd64 before any variant builds' {
        Assert-Throws { New-ChainPlan -Variant default, rocm -TargetArch arm64 } -MessagePattern 'amd64-only'
    }

    It 'refuses a chain with no final image' {
        Assert-Throws { New-ChainPlan -Stages media, torch } -MessagePattern 'builds none'
    }

    It 'refuses a knob that would re-key the final solve' {
        Assert-Throws { New-ChainPlan -BuildOption @{ NoCache = $true } } -MessagePattern 'not a build-only knob'
    }

    It 'refuses two -BuildArg over the process boundary, and lets the serial mode keep them' {
        Assert-Throws { New-ChainPlan -ConcurrentPush -BuildArg 'A=1', 'B=2' } -MessagePattern 'one KEY=VALUE'
        Assert-Equal 'A=1,B=2' ((New-ChainPlan -Variant nvidia -BuildArg 'A=1', 'B=2')[0].BuildParameters['BuildArg'] -join ',') 'serial build-args'
    }
}

Describe 'Invoke-BkVariantChain' {
    It 'serial: the build itself pushes, and no child starts' {
        $r = Invoke-FakeChain -Plan (New-ChainPlan)
        Assert-Equal '' $r.Error 'green'
        Assert-Equal 'build default|build nvidia|build rocm' ($r.Log -join '|') 'order'
        Assert-Equal 'ghcr.io/o/r:winamd64-nvidia' $r.Parameters[1]['PushRef'] 'serial PushRef'
    }

    It 'concurrent: each push starts before the next build, builds carry no PushRef, and all are waited for' {
        $r = Invoke-FakeChain -Plan (New-ChainPlan -ConcurrentPush) -ConcurrentPush -PushRunning
        Assert-Equal '' $r.Error 'green'
        Assert-Equal 'build default|push default|build nvidia|push nvidia|build rocm|push rocm|wait default|wait nvidia|wait rocm' ($r.Log -join '|') 'order'
        Assert-False ($r.Parameters[0].ContainsKey('PushRef')) 'no in-driver push'
    }

    It 'a failed push fails the run and starts no further variant' {
        $r = Invoke-FakeChain -Plan (New-ChainPlan -ConcurrentPush) -ConcurrentPush -PushExit @{ default = 1 }
        Assert-Match 'default push failed \(exit 1, ghcr.io/o/r:winamd64\)' $r.Error 'the verdict'
        Assert-Equal 'build default|push default|wait default' ($r.Log -join '|') 'nvidia never started'
    }

    It 'the last variant''s failed push fails the run too' {
        $r = Invoke-FakeChain -Plan (New-ChainPlan -ConcurrentPush) -ConcurrentPush -PushExit @{ rocm = 7 }
        Assert-Match 'rocm push failed \(exit 7' $r.Error 'the verdict'
    }

    It 'a failed build fails the run, starts nothing more, and lets the finished variant''s push end' {
        $r = Invoke-FakeChain -Plan (New-ChainPlan -ConcurrentPush) -ConcurrentPush -FailBuild nvidia -PushRunning
        Assert-Match 'nvidia failed: stage died in nvidia' $r.Error 'the verdict'
        Assert-Equal 'build default|push default|build nvidia|wait default' ($r.Log -join '|') 'rocm never started; default not killed'
    }

    It 'an interrupted wait kills the running push tree' {
        $killed = [System.Collections.Generic.List[string]]::new()
        $p = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
        $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { throw 'interrupted' }
        $p | Add-Member -MemberType NoteProperty -Name Killed -Value $killed
        $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($tree) $this.Killed.Add("tree=$tree"); $this.HasExited = $true }
        $plan = New-ChainPlan -Variant nvidia -ConcurrentPush
        $start = { param($Step) return $p }.GetNewClosure()
        $call = { Invoke-BkVariantChain -Plan $plan -ConcurrentPush -InvokeBuild { param($Parameters) } -StartPush $start }.GetNewClosure()
        Assert-Throws $call -MessagePattern 'interrupted'
        Assert-Equal 'tree=True' ($killed -join ',') 'the whole tree goes'
    }
}

Describe 'Build-Buildkit.ps1 -PushOnly' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/Build-Buildkit.ps1' -FunctionName 'Assert-BkPushOnlyRequest')
    $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')
    $ok = @{ PushOnly = $true; Stages = @('final'); PushRef = 'r:t'; ParentRunId = '20261104-120000'; BuildDate = '2026-11-04T11:00:00Z'; SkipSmokeGate = $false }

    It 'takes a complete push request and ignores an ordinary run' {
        Assert-BkPushOnlyRequest @ok
        Assert-BkPushOnlyRequest -PushOnly $false -Stages @('base', 'final') -PushRef '' -ParentRunId '' -BuildDate '' -SkipSmokeGate $true
    }

    foreach ($case in @(
            @{ Key = 'Stages'; Value = @('torch', 'final'); Pattern = 'final stage alone' }
            @{ Key = 'PushRef'; Value = ''; Pattern = 'needs -PushRef' }
            @{ Key = 'ParentRunId'; Value = ''; Pattern = 'needs -ParentRunId' }
            @{ Key = 'BuildDate'; Value = ''; Pattern = 'needs -BuildDate' }
            @{ Key = 'SkipSmokeGate'; Value = $true; Pattern = 'cannot take -SkipSmokeGate' }
        )) {
        It "refuses a bad $($case.Key)" {
            $bad = $ok.Clone(); $bad[$case.Key] = $case.Value
            $message = ''
            try { Assert-BkPushOnlyRequest @bad } catch { $message = $_.Exception.Message }
            Assert-Match $case.Pattern $message 'the refusal'
        }
    }

    It 'keeps the shared host state away from a push child, and stamps with the caller''s date' {
        Assert-Match 'if \(\$SccacheEndpoint -and -not \$PushOnly\) \{\s+Publish-BkHostPreseed' $src 'no preseed or memory publish beside a build'
        Assert-Match '(?s)function Set-BuildPhase \{.{0,200}if \(\$PushOnly\) \{ return \}' $src 'no phase write'
        Assert-Match 'BUILD_DATE = Get-BkBuildDate' $src 'the shared stamp'
        Assert-Match '(?s)function Get-BkBuildDate \{\s+if \(\$BuildDate\) \{ return \$BuildDate \}' $src 'the caller''s date wins'
        Assert-Match '(?s)function Set-BkPushOnlyRunId \{.{0,60}\$script:RunId = "\$ParentRunId-push-' $src 'its logs join the chain'
        Assert-Match '(?m)^Set-BkPushOnlyRunId\s*$' $src 'the id is set'
    }
}

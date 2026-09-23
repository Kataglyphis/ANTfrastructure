#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Build-TorchApp.ps1's ORT census (its ort-venv-census.py copy, runner, verdict, wiring) and uv sync's ORT skips.
# NOT covered: the census's own verdicts (test-ort-venv-census.sh), a real venv, ORT under a non-onnxruntime lock name.

# Rooted = as given, so a mutation run can point this at a broken copy of the script.
$script:TorchAppScript = 'windows\scripts\build\Build-TorchApp.ps1'
$script:TorchAppPath = if ([System.IO.Path]::IsPathRooted($script:TorchAppScript)) { $script:TorchAppScript } else { Join-Path (Get-RepoRoot) $script:TorchAppScript }
$script:LinuxCensus = Join-Path (Get-RepoRoot) 'linux\scripts\03-media\runtime\ort-venv-census.py'

Describe 'Build-TorchApp.ps1: the embedded census is ort-venv-census.py' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName 'Get-TorchAppOrtCensusSource')

    It 'embeds the Linux lane''s census verbatim (mutation)' {
        $linux = [System.IO.File]::ReadAllText($script:LinuxCensus).Replace("`r`n", "`n").TrimEnd("`n")
        $embedded = (Get-TorchAppOrtCensusSource).Replace("`r`n", "`n").TrimEnd("`n")
        Assert-True ($linux.Length -gt 1000) 'the Linux census was read'
        Assert-True ($embedded -ceq $linux) 'Build-TorchApp.ps1 embeds a different census; copy linux/scripts/03-media/runtime/ort-venv-census.py into Get-TorchAppOrtCensusSource'
        Assert-False ($embedded -match "(?m)^'@") 'no line of the census can close the here-string'
    }
}

Describe 'Build-TorchApp.ps1: the census verdict' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName 'Get-TorchAppOrtCensusFinding')

    It 'passes exit 0 with a PASS line and no finding' {
        $lines = @('ORT-CENSUS chain onnxruntime 1.30.0 at C:\v = onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'ORT-CENSUS PASS: 1 chain distribution(s) from C:\runtime\wheels')
        Assert-Equal 0 @(Get-TorchAppOrtCensusFinding -ExitCode 0 -Output $lines).Count 'healthy'
    }

    It 'returns every FAIL line, whatever the exit code (mutation)' {
        $lines = @('ORT-CENSUS FAIL onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel', 'ORT-CENSUS FAIL the onnxruntime import package has 2 owners', 'ORT-CENSUS FAILED: 2 finding(s)')
        foreach ($rc in 1, 0) {
            $f = @(Get-TorchAppOrtCensusFinding -ExitCode $rc -Output $lines)
            Assert-Equal 2 $f.Count "exit $rc"
            Assert-Equal 'onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel' $f[0] 'the finding, prefix stripped'
        }
        $withPass = $lines + 'ORT-CENSUS PASS: 1'
        Assert-Equal 2 @(Get-TorchAppOrtCensusFinding -ExitCode 0 -Output $withPass).Count 'a PASS line never outweighs a FAIL line'
    }

    It 'fails an empty run, a PASS that does not start its line, and a non-zero exit (mutation)' {
        Assert-Match 'no PASS line' ((Get-TorchAppOrtCensusFinding -ExitCode 0 -Output @()) -join '|') 'exit 0, no output'
        Assert-Match 'no PASS line' ((Get-TorchAppOrtCensusFinding -ExitCode 0 -Output $null) -join '|') 'exit 0, null output'
        Assert-Match 'no PASS line' ((Get-TorchAppOrtCensusFinding -ExitCode 0 -Output @('noise ORT-CENSUS PASS')) -join '|') 'mid-line PASS'
        Assert-Match '^the census exited 1 without a finding: Traceback' ((Get-TorchAppOrtCensusFinding -ExitCode 1 -Output @('Traceback', 'ORT-CENSUS PASS: 1')) -join '|') 'exit 1'
    }
}

Describe 'Build-TorchApp.ps1: the census runner' {
    $names = 'Get-TorchAppOrtCensusSource', 'Invoke-TorchAppOrtCensus', 'Get-TorchAppOrtCensusFinding', 'Get-TorchAppOrtPurgeName', 'Assert-TorchAppOrtChainOnly'
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName $names)
    # A fake interpreter: argv to args.txt, stdin (the census) to stdin.txt, then out.txt, exit $Rc.
    $fake = { param([string]$Dir, [string]$Out, [int]$Rc)
        [System.IO.File]::WriteAllText((Join-Path $Dir 'out.txt'), $Out)
        $cmd = Join-Path $Dir 'python.cmd'
        [System.IO.File]::WriteAllText($cmd, "@echo off`r`n>`"%~dp0args.txt`" echo %*`r`nfindstr `"^`" > `"%~dp0stdin.txt`"`r`ntype `"%~dp0out.txt`"`r`nexit /b $Rc`r`n")
        $cmd
    }

    It 'runs the interpreter with -I and the census on stdin, then the mode and the store' {
        Invoke-InTestDir { param($dir)
            $py = & $fake $dir "ORT-CENSUS PASS: 2 chain distribution(s) from C:\runtime\wheels`r`n" 0
            $run = Invoke-TorchAppOrtCensus -Mode check -Python $py -Store 'C:\runtime\wheels'
            Assert-Equal 0 $run.ExitCode 'exit code'
            Assert-Equal 'ORT-CENSUS PASS: 2 chain distribution(s) from C:\runtime\wheels' ($run.Lines -join '|') 'output lines'
            Assert-Equal '-I - --check --store C:\runtime\wheels' ([System.IO.File]::ReadAllText((Join-Path $dir 'args.txt')).Trim()) 'isolated, program from stdin'
            $fed = [System.IO.File]::ReadAllText((Join-Path $dir 'stdin.txt')).Replace("`r`n", "`n").TrimEnd("`n")
            Assert-True ($fed -ceq (Get-TorchAppOrtCensusSource).Replace("`r`n", "`n").TrimEnd("`n")) 'the census source reaches stdin verbatim'
            [void](Invoke-TorchAppOrtCensus -Mode purge-list -Python $py -Store 'C:\s')
            Assert-Equal '-I - --purge-list --store C:\s' ([System.IO.File]::ReadAllText((Join-Path $dir 'args.txt')).Trim()) 'purge-list mode'
        }
    }

    It 'throws on a missing interpreter instead of reading a stale exit code (mutation)' {
        $global:LASTEXITCODE = 0
        Assert-Throws { Invoke-TorchAppOrtCensus -Mode check -Python 'C:\nope\python.exe' -Store 'C:\s' } -MessagePattern '^ORT census: no interpreter at '
    }

    It 'purges only well-formed PURGE names, and a failing census stops the purge (mutation)' {
        Invoke-InTestDir { param($dir)
            $py = & $fake $dir "noise`r`nORT-CENSUS PURGE onnxruntime`r`nORT-CENSUS PURGE onnxruntime-genai-cuda`r`nORT-CENSUS PURGE bad&name`r`nORT-CENSUS PURGE Upper`r`n" 0
            Assert-Equal 'onnxruntime|onnxruntime-genai-cuda' ((Get-TorchAppOrtPurgeName -Python $py -Store 'C:\s') -join '|') 'names only, nothing a shell would read'
            $py = & $fake $dir "Traceback`r`nORT-CENSUS PURGE onnxruntime`r`n" 1
            Assert-Throws { Get-TorchAppOrtPurgeName -Python $py -Store 'C:\s' } -MessagePattern 'could not list the venv''s ONNX Runtime distributions \(exit 1\)'
        }
    }

    It 'Assert-TorchAppOrtChainOnly passes a PASS run and throws with the findings otherwise (mutation)' {
        Invoke-InTestDir { param($dir)
            $py = & $fake $dir "ORT-CENSUS PASS: 2 chain distribution(s) from C:\s`r`n" 0
            Assert-TorchAppOrtChainOnly -Python $py -Store 'C:\s' 6>$null
            $py = & $fake $dir "ORT-CENSUS FAIL onnxruntime-ep-webgpu 0.4.0 at C:\v is not a chain wheel`r`nORT-CENSUS FAILED: 1 finding(s)`r`n" 1
            Assert-Throws { Assert-TorchAppOrtChainOnly -Python $py -Store 'C:\s' 6>$null } -MessagePattern 'not the chain''s \(1 finding\(s\)\): onnxruntime-ep-webgpu 0\.4\.0'
            $py = & $fake $dir "" 0
            Assert-Throws { Assert-TorchAppOrtChainOnly -Python $py -Store 'C:\s' 6>$null } -MessagePattern 'no PASS line'
        }
    }
}

Describe 'Build-TorchApp.ps1: uv sync leaves the lock''s ORT to the chain wheels' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName 'Get-TorchAppLockOrtName', 'Get-TorchAppOrtFamily', 'Get-TorchAppOrtSyncArg')
    # A uv.lock of one [[package]] table per name; the indented references must never count as packages.
    $newLock = { param([string]$Dir, [string[]]$Name)
        $tables = foreach ($n in $Name) { "[[package]]`nname = `"$n`"`nversion = `"1.0`"`ndependencies = [`n    { name = `"onnxruntime-extensions`" },`n]`n" }
        $path = Join-Path $Dir 'uv.lock'
        [System.IO.File]::WriteAllText($path, "version = 1`nrevision = 3`n`n" + ($tables -join "`n"))
        $path
    }
    $newStore = { param([string]$Dir, [string[]]$Wheel)
        $store = (New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'wheels')).FullName
        $Wheel | ForEach-Object { Set-Content -LiteralPath (Join-Path $store $_) -Value 'whl' }
        $store
    }
    $v28 = 'onnxruntime', 'onnxruntime-directml', 'onnxruntime-genai', 'onnxruntime-genai-cuda', 'onnxruntime-genai-directml', 'onnxruntime-gpu', 'onnxruntime-rocm', 'onnxruntime-webgpu'
    $chainWheels = 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime_genai_cuda-0.15.2-cp314-cp314-win_amd64.whl', 'tvm-0.25.0-cp314-cp314-win_amd64.whl'

    It 'reads every onnxruntime or onnxruntime-* package of the lock by pattern, normalized and once (mutation)' {
        Invoke-InTestDir { param($dir)
            $lock = & $newLock $dir 'numpy', 'onnxruntime', 'ONNXRuntime.Rocm', 'onnxruntime_genai_cuda', 'onnxruntimex', 'onnx', 'onnxruntime', 'onnxruntime-webgpu'
            Assert-Equal 'onnxruntime|onnxruntime-genai-cuda|onnxruntime-rocm|onnxruntime-webgpu' ((Get-TorchAppLockOrtName -LockPath $lock) -join '|') 'ORT names only'
            $lock = & $newLock $dir 'numpy', 'torch'
            Assert-Equal 0 @(Get-TorchAppLockOrtName -LockPath $lock).Count 'a lock without ORT'
        }
    }

    It 'fails on a lock whose package names it cannot read, never returns an empty list (mutation)' {
        Invoke-InTestDir { param($dir)
            $lock = & $newLock $dir 'onnxruntime'
            [System.IO.File]::AppendAllText($lock, "`n[[package]]`nname=`"onnxruntime-gpu`"`n")
            Assert-Throws { Get-TorchAppLockOrtName -LockPath $lock } -MessagePattern 'cannot read the packages of .*: 1 name\(s\) for 2 \[\[package\]\] table\(s\)'
            [System.IO.File]::WriteAllText($lock, "version = 1`n`n[[manifest.dependency-metadata]]`nname = `"foo`"`n`n[[package]]`nname = `"onnxruntime`"`n")
            Assert-Throws { Get-TorchAppLockOrtName -LockPath $lock } -MessagePattern ': 2 name\(s\) for 1 ' 'a name outside a package table'
            [System.IO.File]::WriteAllText($lock, "version = 1`n")
            Assert-Throws { Get-TorchAppLockOrtName -LockPath $lock } -MessagePattern '0 name\(s\) for 0'
        }
    }

    It 'refuses an ORT name that is not a plain package name (mutation)' {
        Invoke-InTestDir { param($dir)
            $lock = & $newLock $dir 'onnxruntime', 'onnxruntime-x&calc'
            Assert-Throws { Get-TorchAppLockOrtName -LockPath $lock } -MessagePattern 'pins an ORT name uv sync cannot be handed: onnxruntime-x&calc$'
        }
    }

    It 'maps every ORT flavour to the chain wheel family that replaces it (mutation)' {
        foreach ($n in 'onnxruntime', 'onnxruntime-gpu', 'onnxruntime-directml', 'onnxruntime-rocm', 'onnxruntime-webgpu', 'onnxruntime-dnnl') {
            Assert-Equal 'onnxruntime' (Get-TorchAppOrtFamily -Name $n) $n
        }
        foreach ($n in 'onnxruntime-genai', 'onnxruntime-genai-cuda', 'onnxruntime-genai-directml', 'onnxruntime-genai-trt-rtx') {
            Assert-Equal 'onnxruntime-genai' (Get-TorchAppOrtFamily -Name $n) $n
        }
        Assert-Equal 'onnxruntime-extensions' (Get-TorchAppOrtFamily -Name 'onnxruntime-extensions') 'extensions'
        Assert-Equal 'onnxruntime-ep-webgpu' (Get-TorchAppOrtFamily -Name 'onnxruntime-ep-webgpu') 'a plugin EP is not the runtime'
    }

    It 'skips every ORT name of the lock when each family has a chain wheel (mutation)' {
        Invoke-InTestDir { param($dir)
            $store = & $newStore $dir $chainWheels
            $want = ($v28 | ForEach-Object { "--no-install-package $_" }) -join ' '
            Assert-Equal $want (Get-TorchAppOrtSyncArg -LockPath (& $newLock $dir (@('numpy') + $v28)) -Store $store 6>$null) 'the v0.0.28 lock'
            $beyond = & $newLock $dir 'onnxruntime-qnn', 'onnxruntime-genai-rocm'
            Assert-Equal '--no-install-package onnxruntime-genai-rocm --no-install-package onnxruntime-qnn' (Get-TorchAppOrtSyncArg -LockPath $beyond -Store $store 6>$null) 'flavours no v0.0.28 lock pins: skipped by name, never by a list'
            Assert-Equal '' (Get-TorchAppOrtSyncArg -LockPath (& $newLock $dir 'numpy') -Store $store 6>$null) 'no ORT in the lock'
        }
    }

    It 'fails when a locked ORT family has no chain wheel in the store (mutation)' {
        Invoke-InTestDir { param($dir)
            $lock = & $newLock $dir $v28
            $store = & $newStore $dir 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl'
            Assert-Throws { Get-TorchAppOrtSyncArg -LockPath $lock -Store $store 6>$null } -MessagePattern '^uv\.lock pins onnxruntime-genai, onnxruntime-genai-cuda, onnxruntime-genai-directml and .* has no chain wheel'
            Assert-Throws { Get-TorchAppOrtSyncArg -LockPath $lock -Store (Join-Path $dir 'none') 6>$null } -MessagePattern 'pins onnxruntime, onnxruntime-directml, '
            Remove-Item -LiteralPath $store -Recurse -Force
            $store = & $newStore $dir 'onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl'
            Assert-Throws { Get-TorchAppOrtSyncArg -LockPath (& $newLock $dir 'onnxruntime-gpu') -Store $store 6>$null } -MessagePattern 'pins onnxruntime-gpu and' 'a GenAI wheel is not the runtime'
            $store = & $newStore $dir $chainWheels
            foreach ($n in 'onnxruntime-extensions', 'onnxruntime-ep-webgpu') {
                Assert-Throws { Get-TorchAppOrtSyncArg -LockPath (& $newLock $dir 'onnxruntime', $n) -Store $store 6>$null } -MessagePattern "pins $n and" $n
            }
        }
    }
}

Describe 'Build-TorchApp.ps1: the census gates install and verify' {
    $script:TorchAppFns = @{}
    foreach ($def in (Get-Command $script:TorchAppPath).ScriptBlock.Ast.EndBlock.Statements) {
        if ($def -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $script:TorchAppFns[$def.Name] = $def }
    }
    # Every call of $Command inside function $In whose text matches $Like, in source order.
    function Find-TorchAppCall([string]$In, [string]$Command, [string]$Like = '') {
        $script:TorchAppFns[$In].Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Command -and $n.Extent.Text -match $Like }, $true)
    }
    # $Node's ancestors inside function $In, innermost first; and the assignment statement $Node sits in.
    function Get-TorchAppAncestor($Node, [string]$In) { for ($p = $Node.Parent; $p -and $p -ne $script:TorchAppFns[$In]; $p = $p.Parent) { $p } }
    function Get-TorchAppAssignment($Node) { @($Node) + @(Get-TorchAppAncestor $Node 'Install-TorchAppEnvironment') | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] } | Select-Object -First 1 }
    # Every whole-word mention of $Word in function $In outside comments, as file offset and line.
    function Find-TorchAppMention([string]$In, [string]$Word) {
        $fn = $script:TorchAppFns[$In].Extent
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($fn.Text, [ref]$tokens, [ref]$null)
        $code = $fn.Text.ToCharArray()
        foreach ($c in @($tokens | Where-Object Kind -EQ 'Comment')) { for ($i = $c.Extent.StartOffset; $i -lt $c.Extent.EndOffset; $i++) { $code[$i] = ' ' } }
        [regex]::Matches(-join $code, "(?i)(?<!\w)$Word(?!\w)") | ForEach-Object {
            [pscustomobject]@{ At = $fn.StartOffset + $_.Index; Line = $fn.StartLineNumber + ($fn.Text.Substring(0, $_.Index) -split "`n").Count - 1 }
        }
    }

    It 'uninstalls the census''s names, never a fixed ORT list (mutation)' {
        $uninstall = @(Find-TorchAppCall 'Install-TorchAppEnvironment' 'Invoke-ShieldedNative' 'uv pip uninstall')
        Assert-Equal 1 $uninstall.Count 'one uninstall'
        $cmd = $uninstall[0].Extent.Text
        Assert-Match '\$\(\$ortPurge -join '' ''\)' $cmd 'the census names reach the command line'
        Assert-False ($cmd -match '\bonnxruntime') "a literal ORT name is back in the uninstall: $cmd"
        $listing = @(Find-TorchAppCall 'Install-TorchAppEnvironment' 'Get-TorchAppOrtPurgeName')
        Assert-Equal 1 $listing.Count 'one census listing'
        Assert-Equal '$ortPurge = @(Get-TorchAppOrtPurgeName -Python $venvPython -Store $WheelDir)' "$((Get-TorchAppAssignment $listing[0]).Extent.Text)" 'the venv against the store, into $ortPurge'
        Assert-True ($listing[0].Extent.EndOffset -lt $uninstall[0].Extent.StartOffset) 'listed before the uninstall'
    }

    It 'censuses the finished install and every verify, with the venv and the store (mutation)' {
        foreach ($fn in 'Install-TorchAppEnvironment', 'Test-TorchAppEnvironment') {
            $a = @(Find-TorchAppCall $fn 'Assert-TorchAppOrtChainOnly')
            Assert-Equal 1 $a.Count "${fn}: one census"
            Assert-Equal 'Assert-TorchAppOrtChainOnly -Python $venvPython -Store $WheelDir' $a[0].Extent.Text "${fn}: the venv against the store"
            foreach ($p in Get-TorchAppAncestor $a[0] $fn) {
                $gated = $p -is [System.Management.Automation.Language.IfStatementAst] -or $p -is [System.Management.Automation.Language.CatchClauseAst]
                Assert-False $gated "${fn}: the census is conditional: $($p.Extent.Text.Split("`n")[0])"
            }
        }
        $census = (Find-TorchAppCall 'Install-TorchAppEnvironment' 'Assert-TorchAppOrtChainOnly')[0].Extent.StartOffset
        $force = (Find-TorchAppCall 'Install-TorchAppEnvironment' 'Invoke-ShieldedNative' 'force-reinstall')[0].Extent.EndOffset
        $staged = (Find-TorchAppCall 'Install-TorchAppEnvironment' 'Copy-Item' 'venvSite')[0].Extent.EndOffset
        Assert-True ($census -gt $force -and $census -gt $staged) 'install: after the force-reinstall and the base-site staging'
        $imports = (Find-TorchAppCall 'Test-TorchAppEnvironment' 'Invoke-ShieldedNative' 'venv import verification')[0].Extent.StartOffset
        Assert-True ((Find-TorchAppCall 'Test-TorchAppEnvironment' 'Assert-TorchAppOrtChainOnly')[0].Extent.StartOffset -lt $imports) 'verify: before the imports'
    }

    It 'every uv sync skips the lock''s ORT as read, outside any try and re-read after uv lock (mutation)' {
        $syncs = @(Find-TorchAppCall 'Install-TorchAppEnvironment' 'Invoke-ShieldedNative' 'CommandLine "uv sync ')
        $reads = @(Find-TorchAppCall 'Install-TorchAppEnvironment' 'Get-TorchAppOrtSyncArg')
        $lock = @(Find-TorchAppCall 'Install-TorchAppEnvironment' 'Invoke-ShieldedNative' 'CommandLine "uv lock ')
        Assert-Equal '2 2 1' "$($syncs.Count) $($reads.Count) $($lock.Count)" 'two uv syncs, one lock read each, one uv lock'
        Assert-True (@($syncs | Where-Object { $_.Extent.Text -cnotmatch '-CommandLine "uv sync \$syncArgs( --frozen)?"$' }).Count -eq 0) 'every uv sync takes $syncArgs'
        $want = '$syncArgs = "$baseSyncArgs $(Get-TorchAppOrtSyncArg -LockPath $lockPath -Store $WheelDir)"'
        Assert-Equal "$want|$want" (($reads | ForEach-Object { (Get-TorchAppAssignment $_).Extent.Text }) -join '|') 'the skips join the base args'
        # Only the two reads and the two syncs may name syncArgs: a reset, Set-Variable or -replace in between drops the skips.
        $own = @($reads | ForEach-Object { (Get-TorchAppAssignment $_).Left.Extent }) + @($syncs | ForEach-Object { $_.Extent })
        $mentions = @(Find-TorchAppMention 'Install-TorchAppEnvironment' 'syncArgs')
        $stray = @($mentions | Where-Object { $at = $_.At; -not @($own | Where-Object { $at -ge $_.StartOffset -and $at -lt $_.EndOffset }).Count })
        Assert-Equal '4 0' "$($mentions.Count) $($stray.Count)" "syncArgs mentions, and those outside the reads and syncs (line(s) $(($stray | ForEach-Object Line) -join ', '))"
        $caught = @($reads | ForEach-Object { Get-TorchAppAncestor $_ 'Install-TorchAppEnvironment' } | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.CatchClauses.Count })
        Assert-Equal 0 $caught.Count 'a read inside a try/catch turns a missing chain wheel into a lock regeneration'
        $order = $reads[0], $syncs[0], $lock[0], $reads[1], $syncs[1]
        $late = @(1..4 | Where-Object { $order[$_ - 1].Extent.EndOffset -ge $order[$_].Extent.StartOffset })
        Assert-Equal 0 $late.Count 'order: read, frozen sync, uv lock, re-read, sync'
        Assert-Match '(?m)^\s*\$lockPath = Join-Path \$AppDir ''uv\.lock''\r?$' $script:TorchAppFns['Install-TorchAppEnvironment'].Extent.Text 'the app''s own lock'
    }
}

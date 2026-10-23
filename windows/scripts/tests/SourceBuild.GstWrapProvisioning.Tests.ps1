#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: live downloads or real 7-Zip extraction; both operations are stubbed.

# Failures must be returned, since the caller owns the fail-closed throw and a module's $script: is module scope.

function script:Invoke-GstWrapFixture {
    param([string]$Wrap = '')
    Invoke-InTestDir -Prefix gstwrap- -Body { param($dir)
        New-Item -ItemType Directory -Path (Join-Path $dir 'libffi') -Force | Out-Null
        if ($Wrap) { Set-Content -LiteralPath (Join-Path $dir 'doomed.wrap') -Value $Wrap }
        Invoke-GstWrapProvisioning -SubprojectDir $dir -TempDir $dir -LibffiVersion '0.0' -Logger { param($m) }
    }.GetNewClosure()
}

function script:Invoke-GstArchiveFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = [pscustomobject]@{
        Downloads = [Collections.Generic.List[object]]::new()
        Extractions = [Collections.Generic.List[object]]::new()
        Extracted = $true
        ThrowDownload = $false
        ThrowExtract = $false
    }
    $prelude = @'
$script:State = $State
function Invoke-WrapDownload {
    param($Url, $DestinationPath, $Description, $Logger)
    $script:State.Downloads.Add([pscustomobject]@{ Url = $Url; Path = $DestinationPath; Description = $Description })
    [IO.File]::WriteAllText($DestinationPath, 'archive')
    if ($script:State.ThrowDownload) { throw 'fixture download failed' }
}
function Expand-SubprojectArchive {
    param($Archive, $Target)
    $script:State.Extractions.Add([pscustomobject]@{ Archive = $Archive; Target = $Target })
    if ($script:State.ThrowExtract) { throw 'fixture extraction failed' }
    return $script:State.Extracted
}
'@
    Invoke-WithFunctionModule -ScriptPath $script:modPath `
        -FunctionName Invoke-GstWrapProvisioning, Invoke-MesonSubprojectArchive -Find $Find -Replace $Replace `
        -FixtureState $state -Prelude $prelude -Body $Body
}

Describe 'Invoke-GstWrapProvisioning (#88 failure collection)' {
    BeforeAll { $script:modPath = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMeson.Common.psm1' }

    It 'returns an EMPTY COUNTABLE result when there is nothing to provision' {
        $r = @(Invoke-GstWrapFixture)
        $r.Count | Should -Be 0
    }

    It 'RETURNS a failure (never swallows it) when a wrap-git tarball cannot be fetched' {
        $r = @(Invoke-GstWrapFixture -Wrap @'
[wrap-git]
directory = doomed
url = https://invalid.invalid/kataglyphis/doomed.git
revision = deadbeef
'@)
        $r.Count | Should -BeGreaterThan 0 -Because 'a dead wrap must reach the caller, not just the log'
        ($r -join ' ') | Should -Match 'doomed'

    }

    It 'accumulates into a LOCAL list, not the module scope' {
        # A `$script:` accumulator would live in module scope, and the returned list would stop being the truth.
        $fn = (Get-ScriptFunctionDefinition -ScriptPath $script:modPath -FunctionName Invoke-GstWrapProvisioning).ToString()
        $fn | Should -Not -Match '\$script:' -Because 'a module script-scope list would not reach the caller'
        # The call site @()-wraps; a comma-wrap would nest the array and make .Count read 1 either way.
        $fn | Should -Not -Match 'return\s*,' -Because 'the caller @()-wraps; a comma-wrap nests the result and breaks the #88 count'
    }

    It 'shares archive download and cleanup while keeping wrap failure policy in the caller' {
        Invoke-GstArchiveFixture -Body {
            param($state)
            Invoke-InTestDir -Prefix gst-archive- -Body {
                param($dir)
                $subprojects = Join-Path $dir subprojects
                $temp = Join-Path $dir temp
                New-Item -ItemType Directory -Path (Join-Path $subprojects 'libffi'), $temp -Force | Out-Null
                $wrapPath = Join-Path $subprojects 'doomed.wrap'
                $wrapContent = "[wrap-git]`ndirectory = doomed`nurl = https://github.com/example/doomed.git`nrevision = deadbeef`n"
                $writeWrap = { Set-Content -LiteralPath $wrapPath -Value $wrapContent }.GetNewClosure()
                $provision = {
                    param($version)
                    Invoke-MutGstWrapProvisioning -SubprojectDir $subprojects -TempDir $temp -LibffiVersion $version -Logger { param($message) }
                }.GetNewClosure()

                & $writeWrap
                $failures = @(& $provision '0.0')
                $archivePath = Join-Path $temp 'doomed-deadbeef.tar.gz'
                Assert-Equal 0 $failures.Count
                Assert-Equal 1 $state.Downloads.Count
                Assert-Equal $state.Downloads[0].Path $state.Extractions[0].Archive
                Assert-False (Test-Path -LiteralPath $archivePath) 'successful extraction removes its temporary archive'
                Assert-False (Test-Path -LiteralPath $wrapPath) 'successful extraction removes the processed wrap file'

                $state.Extracted = $false
                & $writeWrap
                $failures = @(& $provision '0.0')
                Assert-Match 'downloaded but extraction into doomed failed' ($failures -join '|')
                Assert-True (Test-Path -LiteralPath $wrapPath) 'failed extraction leaves the wrap for diagnosis'
                Assert-False (Test-Path -LiteralPath $archivePath) 'failed extraction removes its temporary archive'

                Remove-Item -LiteralPath $wrapPath -Force
                Remove-Item -LiteralPath (Join-Path $subprojects 'libffi') -Recurse -Force
                $libffiWrap = Join-Path $subprojects 'libffi.wrap'
                Set-Content -LiteralPath $libffiWrap -Value 'fixture'
                $state.Extracted = $true
                $state.ThrowExtract = $true
                $failures = @(& $provision '1.2')
                Assert-Match 'libffi : fixture extraction failed' ($failures -join '|')
                Assert-False (Test-Path -LiteralPath (Join-Path $temp 'libffi.tar.bz2')) 'the shared lifecycle removes the failed archive'
                Assert-False (Test-Path -LiteralPath $libffiWrap) 'the libffi caller drops its wrap file after failure'
            }
        }
    }

    It 'detects the shared archive lifecycle skipping temporary-file cleanup' {
        Assert-Throws {
            Invoke-GstArchiveFixture -Find 'Remove-Item -Path $Archive -Force -ErrorAction SilentlyContinue' -Replace '$null = $Archive' -Body {
                param($state)
                $dir = New-TestDir -Prefix gst-archive-mutation-
                try {
                    $archivePath = Join-Path $dir 'fixture.tar.gz'
                    $target = Join-Path $dir target
                    $null = Invoke-MutMesonSubprojectArchive -Url fixture -Archive $archivePath -Target $target `
                        -Description fixture -Logger { param($message) }
                    Assert-False (Test-Path -LiteralPath $archivePath) 'temporary archive must be removed'
                } finally { Remove-TestDir -Path $dir }
            }
        } -MessagePattern 'temporary archive must be removed'
    }
}

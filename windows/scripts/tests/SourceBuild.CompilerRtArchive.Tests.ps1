#requires -Version 7.0
# Stubbed tar and downloads cover archive selection and caller policies, not LLVM artifacts or actual linking.

function Invoke-CompilerRtArchiveFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $source = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' `
        -FunctionName Expand-CompilerRtLibrary, Assert-FileSha256, Find-FirstTreeFile).ToString()
    $source += "`n" + (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Install-AArch64CompilerRt).ToString()
    $exercise = $Body
    Invoke-InTestDir -Body { param($dir)
        $work = Join-Path $dir 'work space'
        $destination = Join-Path $dir 'installed libs'
        $null = [IO.Directory]::CreateDirectory($work)
        $null = [IO.Directory]::CreateDirectory($destination)
        $state = New-TestCallState @{ Root = $dir; Work = $work; Destination = $destination; Action = $exercise
            Archive = (Join-Path $work 'clang+llvm-fixture-aarch64-pc-windows-msvc.tar.xz')
            Extract = (Join-Path $work 'llvm-aarch64-rt'); LibraryName = 'clang_rt.builtins-aarch64.lib'
            Tool = 'Invoke-CompilerRtTarFixture'; CreateLibrary = $true; Code = 17; DownloadFails = $false
            Events = [Collections.Generic.List[object]]::new(); Candidate = @() }
        [IO.File]::WriteAllText($state.Archive, 'compiler archive bytes')
        $state | Add-Member -NotePropertyName Sha -NotePropertyValue (Get-FileHash -LiteralPath $state.Archive -Algorithm SHA256).Hash
        $prelude = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-PreferredToolPath { param($CommandName, $CandidatePaths) $State.Events.Add($CommandName); $State.Candidate = $CandidatePaths; $State.Tool }
function Invoke-DownloadWithRetry { param($Url, $DestinationPath, $Description) $State.Events.Add("fetch:$Url"); if ($State.DownloadFails) { throw 'fixture fetch failed' }; [IO.File]::WriteAllText($DestinationPath, 'compiler archive bytes') }
'@
        Invoke-WithTestNativeCommand -Name Invoke-CompilerRtTarFixture -FixtureState $state -Implementation { param($record)
            if ($record.CreateLibrary) { Write-TestFileTree -Root $record.Extract -Files @{ "nested/$($record.LibraryName)" = 'target library' } }
            'tar stdout'
        } -Body { param($record)
            Invoke-WithFunctionModule -Text $source -Find $Find -Replace $Replace -Prelude $prelude -FixtureState $record -Body { param($record)
                & $record.Action $record
            }
        }
    }
}

function Invoke-CompilerRtArchiveExpansion {
    param($State, [ref]$LibraryPath, [string]$Sha = $State.Sha)
    Expand-MutCompilerRtLibrary -ArchivePath $State.Archive -ExtractDirectory $State.Extract -LibraryPath $LibraryPath -ExpectedSha256 $Sha
}

function Invoke-CompilerRtSourceInstall {
    param($State)
    Install-MutAArch64CompilerRt -Url 'https://example.invalid/clang%2Bllvm-fixture-aarch64-pc-windows-msvc.tar.xz' `
        -DestinationDir $State.Destination -WorkDir $State.Work -ExpectedSha256 $State.Sha
}

Describe 'Shared compiler-rt archive extraction' {
    It 'keeps optional lookup silent and required lookup failures terminating' {
        Invoke-InTestDir { param($dir)
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Find-FirstTreeFile -BodyArgumentList $dir -Body { param($root)
                $missing = Join-Path $root 'missing'
                Assert-Equal 0 @(Find-MutFirstTreeFile -Root $missing -Filter '*.lib').Count
                Assert-Throws { Find-MutFirstTreeFile -Root $missing -Filter '*.exe' -ScanErrorAction Stop } -MessagePattern 'missing'
            }
        }
    }

    It 'discovers prerequisite files recursively under literal bracket paths and ignores matching directories' {
        Invoke-InTestDir -Files @{ 'sdk [exact]/nested/opensslv.h' = 'header'; 'sdk [exact]/opensslv.h/other.txt' = 'directory decoy' } -Body { param($dir)
            Invoke-TestFunctionMutations -IncludeControl -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Find-FirstTreeFile `
                -BodyArgumentList $dir -Find '-LiteralPath $Root' -Replace '-Path $Root' -Expected 'literal prerequisite root must resolve' -Body { param($root)
                    $found = @(Find-MutFirstTreeFile -Root (Join-Path $root 'sdk [exact]') -Filter opensslv.h)
                    Assert-Equal 1 $found.Count 'literal prerequisite root must resolve'
                    Assert-Equal (Join-Path $root 'sdk [exact]/nested/opensslv.h') $found[0].FullName
                    Assert-Equal header ([IO.File]::ReadAllText($found[0].FullName))
                }
        }
    }

    It 'finds installed host and target libraries under the LLVM prefix and rejects the wrong layout' {
        Invoke-InTestDir -Files @{ 'lib/clang/fixture/lib/clang_rt.builtins-x86_64.lib' = 'host'; 'lib/clang/fixture/lib/clang_rt.builtins-aarch64.lib' = 'target' } -Body { param($dir)
            Invoke-TestFunctionMutations -IncludeControl -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Find-FirstTreeFile, Find-InstalledCompilerRtLibrary `
                -BodyArgumentList $dir -Find "Join-Path `$LlvmRoot 'lib\clang'" -Replace "Join-Path `$LlvmRoot 'wrong'" -Expected 'installed target library must resolve' -Body { param($root)
                    $target = @(Find-MutInstalledCompilerRtLibrary -LlvmRoot $root)
                    Assert-Equal 1 $target.Count 'installed target library must resolve'
                    Assert-Equal target ([IO.File]::ReadAllText($target[0].FullName))
                    $hostLibrary = Find-MutInstalledCompilerRtLibrary -LlvmRoot $root -LibraryName 'clang_rt.builtins-x86_64.lib'
                    Assert-Equal host ([IO.File]::ReadAllText($hostLibrary.FullName))
                    Assert-Equal 0 @(Find-MutInstalledCompilerRtLibrary -LlvmRoot $root -LibraryName 'missing.lib').Count
                }
        }
    }

    It 'verifies before extraction and separates the selected path from native stdout' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $library = 'stale'
            $output = @(Invoke-CompilerRtArchiveExpansion -State $state -LibraryPath ([ref]$library) 6>$null)
            Assert-Equal 'tar stdout' ($output -join '|')
            Assert-Equal (Join-Path $state.Extract "nested/$($state.LibraryName)") $library
            Assert-Equal "-xf|$($state.Archive)|-C|$($state.Extract)|*clang_rt.builtins-aarch64.lib" ($state.Calls[0] -join '|')
            Assert-Equal tar $state.Events[0]
            Assert-Equal "$env:SystemRoot\System32\tar.exe" $state.Candidate[0]
            Assert-Equal 17 $global:LASTEXITCODE
        }
    }

    It 'clears a previous result when the archive has no matching library' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $state.CreateLibrary = $false
            $library = 'stale'
            Invoke-CompilerRtArchiveExpansion -State $state -LibraryPath ([ref]$library) 6>$null | Out-Null
            Assert-Null $library 'missing libraries cannot retain an old selection'
        }
    }

    It 'rejects a bad hash before tool lookup or extraction' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $library = 'stale'
            Assert-Throws { Invoke-CompilerRtArchiveExpansion -State $state -LibraryPath ([ref]$library) -Sha ('0' * 64) } -MessagePattern 'SHA256 mismatch'
            Assert-Null $library
            Assert-Equal 0 $state.Events.Count
            Assert-Equal 0 $state.Calls.Count
            Assert-False (Test-Path -LiteralPath $state.Extract)
        }
    }

    It 'reports a missing tar without claiming to select a library' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $state.Tool = $null
            $library = 'stale'
            Assert-Throws { Invoke-CompilerRtArchiveExpansion -State $state -LibraryPath ([ref]$library) 6>$null } -MessagePattern 'No tar.exe found'
            Assert-Null $library
            Assert-Equal 0 $state.Calls.Count
        }
    }

    It 'detects a disabled hash check' {
        Invoke-CompilerRtArchiveFixture -Find "Assert-FileSha256 -Path `$ArchivePath -Expected `$ExpectedSha256 -Label 'aarch64 compiler-rt archive' -PinName `$PinName" -Replace '' -Body { param($state)
            $library = $null
            Assert-Throws {
                Assert-Throws { Invoke-CompilerRtArchiveExpansion -State $state -LibraryPath ([ref]$library) -Sha ('0' * 64) | Out-Null } -MessagePattern 'SHA256 mismatch'
            } -MessagePattern 'expected an exception but none was thrown'
        }
    }
}

Describe 'Compiler-rt caller policies' {
    It 'copies the source-build library, keeps stdout and cleans its decoded archive and extraction tree' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $result = @(Invoke-CompilerRtSourceInstall -State $state 6>$null)
            $destination = Join-Path $state.Destination $state.LibraryName
            Assert-Equal "tar stdout|$destination" ($result -join '|')
            Assert-Equal 'target library' ([IO.File]::ReadAllText($destination))
            Assert-False (Test-Path -LiteralPath $state.Archive)
            Assert-False (Test-Path -LiteralPath $state.Extract)
        }
    }

    It 'keeps missing source-build libraries fatal and cleans scratch on failure' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $state.CreateLibrary = $false
            Assert-Throws { Invoke-CompilerRtSourceInstall -State $state 6>$null } -MessagePattern 'not found inside.*upstream archive layout changed'
            Assert-False (Test-Path -LiteralPath $state.Archive)
            Assert-False (Test-Path -LiteralPath $state.Extract)
        }
    }

    It 'does not accept a matching stale archive after a failed fetch' {
        Invoke-CompilerRtArchiveFixture { param($state)
            $state.DownloadFails = $true
            Assert-Throws { Invoke-CompilerRtSourceInstall -State $state } -MessagePattern 'fixture fetch failed'
            Assert-Equal 0 $state.Calls.Count
            Assert-False (Test-Path -LiteralPath $state.Archive)
        }
    }

    It 'preserves base-stage advisory and explicitly strict final verdicts' {
        $ast = Get-TestScriptAst -ScriptPath 'windows/scripts/host/Install-ScoopTools.ps1'
        $checks = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$rtTarget.Count -eq 0'
        }, $true))
        Assert-Equal 1 $checks.Count
        $check = [scriptblock]::Create('param($rtTarget, $llvmAppRoot, $armStrict); ' + $checks[0].Extent.Text)
        $warning = & $check -rtTarget @() -llvmAppRoot 'fixture LLVM' -armStrict 0 3>&1 | Out-String
        Assert-Match 'Set WINDOWS_ARM64_STRICT=1 to make this a hard failure' $warning
        Assert-Throws { & $check -rtTarget @() -llvmAppRoot 'fixture LLVM' -armStrict 1 } -MessagePattern 'WINDOWS_ARM64_STRICT=1 made this a hard gate'
        $calls = @(Get-TestAstCommands -Ast $ast -Name Install-AArch64CompilerRt)
        Assert-Equal 1 $calls.Count
        $arguments = Get-TestCommandArguments $calls[0]
        Assert-Equal '$rtUrl' $arguments.Url
        Assert-Equal '$rtDestDir' $arguments.DestinationDir
        Assert-Equal '$rtSha' $arguments.ExpectedSha256
        Assert-Equal '$env:TEMP' $arguments.WorkDir
        Assert-Equal 0 @(Get-TestAstCommands -Ast $ast -Name Expand-CompilerRtLibrary) 'the host must use the shared acquisition operation'
        $imports = @(Get-TestAstCommands -Ast $ast -Name Import-Module | Where-Object { $_.Extent.Text -match '\$sharedHelpersPath' })
        Assert-Equal 1 $imports.Count
        Assert-Equal Stop (Get-TestCommandArguments $imports[0]).ErrorAction
    }
}

#requires -Version 7.0
# A module cannot see its caller's scope, so state once read by dynamic scoping must fail loudly here.

$modulePath = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'modules\WindowsSmokeTest.Common.psm1'
Import-Module $modulePath -Force

function Assert-SmokeCounters {
    param($Summary, [int]$Passed, [int]$Failed, [int]$Skipped, [int]$Total, [bool]$Aborted)
    Assert-Equal $Passed $Summary.Passed 'passed count'
    Assert-Equal $Failed $Summary.Failed 'failed count'
    Assert-Equal $Skipped $Summary.Skipped 'skipped count'
    Assert-Equal $Total $Summary.Total 'total count'
    Assert-Equal $Aborted $Summary.Aborted 'abort state'
}

# One pass and one failure always land; only an exit-on-failure run aborts at the failure.
function Assert-SmokeCounterScenario {
    param([bool]$ExitOnFirstFailure, [scriptblock]$AfterFailure, [int]$Skipped, [int]$Total)
    Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure
    Assert-Test -Name 'true' -Condition { $true }
    Assert-Test -Name 'false' -Condition { $false } -FailMessage 'deliberate'
    & $AfterFailure
    Assert-SmokeCounters -Summary (Get-SmokeTestSummary) -Passed 1 -Failed 1 -Skipped $Skipped -Total $Total -Aborted $ExitOnFirstFailure
}

function Assert-SmokeRunContinued([string]$AbortWhy, [string]$PassWhy) {
    $s = Get-SmokeTestSummary
    Assert-False $s.Aborted $AbortWhy
    Assert-Equal 1 $s.Passed $PassWhy
}

function New-SmokeMsixFixture {
    param([string]$Path, [string]$Manifest = '<Package><Identity Name="Fixture" /></Package>', [switch]$OmitManifest)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        if (-not $OmitManifest) {
            $writer = [System.IO.StreamWriter]::new($zip.CreateEntry('AppxManifest.xml').Open())
            try { $writer.Write($Manifest) } finally { $writer.Dispose() }
        }
        $null = $zip.CreateEntry('Assets/logo.png')
    } finally { $zip.Dispose() }
}

Describe 'Smoke harness counters' {

    It 'Initialize-SmokeTestRun zeroes every counter' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'seed' -Condition { $true }
        Initialize-SmokeTestRun
        $s = Get-SmokeTestSummary
        Assert-Equal 0 $s.Passed  'passed reset'
        Assert-Equal 0 $s.Failed  'failed reset'
        Assert-Equal 0 $s.Skipped 'skipped reset'
        Assert-Equal 0 $s.Total   'total reset'
        Assert-False $s.Aborted   'abort flag reset'
    }

    It 'counts a passing, a failing and a skipped assertion into the summary' {
        Assert-SmokeCounterScenario -ExitOnFirstFailure $false -AfterFailure { Skip-Test 'deliberate skip' } -Skipped 1 -Total 3
    }

    It 'records the failure message in FailureDetails' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'named' -Condition { $false } -FailMessage 'because reasons'
        $s = Get-SmokeTestSummary
        Assert-Equal 1 @($s.FailureDetails).Count 'one detail recorded'
        Assert-Match 'named.*because reasons' $s.FailureDetails[0] 'name and message both kept'
    }

    It 'treats a throwing condition as a failure, not a crash' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'throws' -Condition { throw 'boom' }
        $s = Get-SmokeTestSummary
        Assert-Equal 1 $s.Failed 'exception counted as failure'
        Assert-Match 'boom' $s.FailureDetails[0] 'exception message surfaced'
    }
}

Describe '-ExitOnFirstFailure across the module boundary' {
    # Inside a module the dynamic-scope lookup finds nothing, so the abort would silently never fire.

    It 'aborts at the first failure and short-circuits later assertions' {
        Assert-SmokeCounterScenario -ExitOnFirstFailure $true -AfterFailure {
            Assert-Test -Name 'later' -Condition { $true }
            Skip-Test 'later skip'
        } -Skipped 0 -Total 2
    }

    It 'keeps running after a failure when the switch is absent (default)' {
        Initialize-SmokeTestRun
        Assert-Test -Name 'boom'  -Condition { $false } -FailMessage 'first failure'
        Assert-Test -Name 'later' -Condition { $true }
        Assert-SmokeRunContinued 'no abort' 'later assertion still ran'
    }

    It 'does not leak the switch into the next run' {
        Initialize-SmokeTestRun -ExitOnFirstFailure
        Assert-Test -Name 'boom' -Condition { $false }
        Initialize-SmokeTestRun          # no switch this time
        Assert-Test -Name 'boom2' -Condition { $false }
        Assert-Test -Name 'after' -Condition { $true }
        Assert-SmokeRunContinued 'module state reset with the run' 'run continued'
    }
}

Describe 'Path and command assertions' {

    It 'Assert-FileExists / Assert-DirectoryExists distinguish files from directories' {
        Invoke-InTestDir { param($dir)
            $file = Join-Path $dir 'a.txt'
            Set-Content $file 'x' -Encoding ASCII
            Initialize-SmokeTestRun
            Assert-FileExists      -Path $file -Description 'file as file'
            Assert-DirectoryExists -Path $dir  -Description 'dir as dir'
            Assert-FileExists      -Path $dir  -Description 'dir as file (must fail)'
            $s = Get-SmokeTestSummary
            Assert-Equal 2 $s.Passed 'file and dir both found'
            Assert-Equal 1 $s.Failed 'a directory does not satisfy -PathType Leaf'
        }
    }

    It 'Assert-CommandExists queries the NAME, not the test title' {
        # Assert-Test's own $Name shadows this one under dynamic scoping; the .GetNewClosure() capture prevents it.
        Initialize-SmokeTestRun
        Assert-CommandExists -Name 'Get-ChildItem'
        Assert-CommandExists -Name 'definitely-not-a-real-command-xyzzy'
        $s = Get-SmokeTestSummary
        Assert-Equal 1 $s.Passed 'the real command resolved'
        Assert-Equal 1 $s.Failed 'the bogus one did not'
    }

    It 'Assert-ArtifactPresent counts recursively, and -Informational downgrades a miss to a skip' {
        Invoke-InTestDir { param($dir)
            $sub = Join-Path $dir 'nested'
            New-Item -ItemType Directory -Path $sub | Out-Null
            Set-Content (Join-Path $sub 'x.dll') 'x' -Encoding ASCII
            Initialize-SmokeTestRun
            Assert-ArtifactPresent -Root $dir -Filter '*.dll' -Description 'nested dll found'
            Assert-ArtifactPresent -Root $dir -Filter '*.nope' -Description 'absent, informational' -Informational
            Assert-ArtifactPresent -Root $dir -Filter '*.nope' -Description 'absent, mandatory'
            $s = Get-SmokeTestSummary
            Assert-Equal 1 $s.Passed  'recursive match counted'
            Assert-Equal 1 $s.Skipped 'informational miss is a skip'
            Assert-Equal 1 $s.Failed  'mandatory miss is a failure'
        }
    }

    It 'Assert-EnvVarSet checks the variable, and honours an expected prefix' {
        Invoke-WithEnv @{ SMOKE_HARNESS_PROBE = 'C:\some\path' } {
            Initialize-SmokeTestRun
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE' -ExpectedPrefix 'C:\some'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_PROBE' -ExpectedPrefix 'D:\other'
            Assert-EnvVarSet -Name 'SMOKE_HARNESS_ABSENT'
            $s = Get-SmokeTestSummary
            Assert-Equal 2 $s.Passed 'set, and matching prefix'
            Assert-Equal 2 $s.Failed 'wrong prefix, and unset'
        }
    }
}

Describe 'The native DLL probe type' {

    # KataNativeProbe is session-global, so the first function to Add-Type it decides its members; the order is the test.

    It 'a DLL sweep does not poison the -Export check that runs after it' {
        Invoke-InTestDir { param($dir)
            $sys = Join-Path $env:WINDIR 'System32'
            Copy-Item (Join-Path $sys 'version.dll') $dir
            Initialize-SmokeTestRun
            Assert-AllDllsLoad -Name 'sweep first' -Root $dir -MinimumChecked 1
            Assert-DllLoads -Name 'then an export check' `
                -DllPath (Join-Path $sys 'kernel32.dll') -Export 'GetProcAddress'
            $s = Get-SmokeTestSummary
            Assert-Equal 2 $s.Passed 'the sweep and the export check both pass in this order'
            Assert-Equal 0 $s.Failed 'GetProcAddress resolved on the shared probe type'
        }
    }

    It 'the export check reports a REAL missing export as a failure' {
        # Guards the test above: it must fail for a genuinely absent export, not pass because nothing was checked.
        Initialize-SmokeTestRun
        Assert-DllLoads -Name 'absent export' `
            -DllPath (Join-Path $env:WINDIR 'System32\kernel32.dll') `
            -Export 'NoSuchExportXyzzy'
        $s = Get-SmokeTestSummary
        Assert-Equal 0 $s.Passed 'a missing export is not a pass'
        Assert-Equal 1 $s.Failed 'a missing export is a failure'
    }
}

Describe 'TensorRT staged-state detection' {

    # A plain Test-Path would call the always-empty C:\tensorrt staged and demand an EP the build compiled out.

    It 'is false for an unset, empty, or missing root' {
        Invoke-WithEnv @{ TENSORRT_ROOT = '' } {
            Assert-False (Test-TensorRtTreeStaged) 'empty root is not staged'
        }
        Invoke-WithEnv @{ TENSORRT_ROOT = (Join-Path $env:TEMP 'no-such-trt-root-xyzzy') } {
            Assert-False (Test-TensorRtTreeStaged) 'a missing directory is not staged'
        }
    }

    It 'is false for the guaranteed-empty directory the nvidia stage creates' {
        Invoke-InTestDir { param($dir)
            Assert-False (Test-TensorRtTreeStaged -Root $dir) 'empty dir is the zip-less normal state'
        }
    }

    It 'is true once a TensorRT tree is staged' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Path (Join-Path $dir 'TensorRT-11.3.0.99') | Out-Null
            Assert-True (Test-TensorRtTreeStaged -Root $dir) 'a versioned tree counts as staged'
        }
    }
}

# Archive fixtures cannot prove desktop AppX deployment or the caller's identity policy.
Describe 'MSIX archive facts' {
    It 'returns the manifest and entry names from a closed archive' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'fixture.msix'
            New-SmokeMsixFixture -Path $path
            $facts = Get-MsixArchiveInfo -Path $path
            Assert-Equal 'Fixture' $facts.Manifest.Package.Identity.Name 'the XML identity survives the archive close'
            Assert-Equal 2 @($facts.Entries).Count 'both archive members are reported'
            Assert-True ($facts.Entries -contains 'Assets/logo.png') 'payload names are retained'
            [System.IO.File]::Delete($path)
            Assert-False (Test-Path -LiteralPath $path) 'archive handle is released'
        }
    }

    It 'fails loudly for a missing manifest or malformed XML' {
        Invoke-InTestDir { param($dir)
            $missing = Join-Path $dir 'missing.msix'
            New-SmokeMsixFixture -Path $missing -OmitManifest
            Assert-Throws { Get-MsixArchiveInfo -Path $missing } -MessagePattern 'no AppxManifest.xml'
            $malformed = Join-Path $dir 'malformed.msix'
            New-SmokeMsixFixture -Path $malformed -Manifest '<Package'
            Assert-Throws { Get-MsixArchiveInfo -Path $malformed }
        }
    }

    It 'catches a reader redirected away from the manifest' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'valid.msix'
            New-SmokeMsixFixture -Path $path
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSmokeTest.Common.psm1' `
                -FunctionName Get-MsixArchiveInfo -Find "GetEntry('AppxManifest.xml')" `
                -Replace "GetEntry('Other.xml')" -BodyArgumentList @($path) -Body {
                    param($msix)
                    Assert-Throws { Get-MutMsixArchiveInfo -Path $msix } -MessagePattern 'no AppxManifest.xml'
                }
        }
    }
}

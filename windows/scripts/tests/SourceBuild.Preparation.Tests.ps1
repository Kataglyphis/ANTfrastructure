#requires -Version 7.0
# Fixtures cover preparation, artifact verdicts and DLL graph policy; they do not compile upstream projects or fetch from the network.

Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.GraphFixture.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.PatchFixture.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop

function New-SourcePreparationArguments {
    param([string[]]$FunctionName, [scriptblock]$Body, [Collections.IDictionary[]]$Mutation,
        [string]$Prelude = '', [object]$FixtureState,
        [string]$ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Common.psm1')
    $module = @{ ScriptPath = $ScriptPath; FunctionName = $FunctionName; Prelude = $Prelude }
    if ($null -ne $FixtureState) { $module.FixtureState = $FixtureState }
    # Literal mutants must match the source module's committed line endings.
    $newline = if ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $ScriptPath)).Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($edit in $Mutation) { $edit.Find = $edit.Find -replace '\r?\n', $newline }
    return @{ ModuleArguments = $module; Case = $Mutation; Body = $Body }
}

function Assert-SourceCachePreparation {
    Invoke-InTestDir -Files @{ 'cache/sccache.exe' = 'stand-in'; 'missing/.keep' = '' } -Body { param($dir)
        $cache = Join-Path $dir cache
        Invoke-WithEnv @{ PATH = $cache; SCCACHE_MAX_JOBS = 'caller-limit' } {
            Assert-Null (Get-MutSourceBuildSccache -RemoteConfigured $false) 'remote backend is required'
            Assert-Equal 'caller-limit' $env:SCCACHE_MAX_JOBS
            $env:PATH = Join-Path $dir missing
            Assert-Null (Get-MutSourceBuildSccache -RemoteConfigured $true)
            Assert-Equal 'caller-limit' $env:SCCACHE_MAX_JOBS 'missing executable keeps caller settings'
            $env:PATH = $cache
            Assert-Equal (Join-Path $cache sccache.exe) (Get-MutSourceBuildSccache -RemoteConfigured $true).Source
            Assert-Equal 'caller-limit' $env:SCCACHE_MAX_JOBS 'explicit job limit survives discovery'
            Remove-Item Env:SCCACHE_MAX_JOBS
            Assert-NotNull (Get-MutSourceBuildSccache -RemoteConfigured $true)
            Assert-Equal ([Environment]::ProcessorCount.ToString()) $env:SCCACHE_MAX_JOBS 'missing job limit defaults to CPU count'
        }.GetNewClosure()
    }
}

function Assert-SourceBuildCopyIfAbsent {
    Invoke-InTestDir -Files @{
        'source/present.txt' = 'new source bytes'
        'destination/existing.txt' = 'keep destination bytes'
    } -Body { param($dir)
        $source = Join-Path $dir 'source/present.txt'
        $destination = Join-Path $dir 'destination/copied.txt'
        $existing = Join-Path $dir 'destination/existing.txt'
        Assert-True (Copy-MutSourceBuildFileIfAbsent -SourcePath $source -DestinationPath $destination) 'a present source is copied to an absent destination'
        Assert-Equal 'new source bytes' ([IO.File]::ReadAllText($destination))
        Assert-False (Copy-MutSourceBuildFileIfAbsent -SourcePath (Join-Path $dir missing.txt) -DestinationPath (Join-Path $dir destination/missing.txt)) 'a missing source is a no-op'
        Assert-False (Copy-MutSourceBuildFileIfAbsent -SourcePath $source -DestinationPath $existing) 'an existing destination is preserved'
        Assert-Equal 'keep destination bytes' ([IO.File]::ReadAllText($existing)) 'copying never overwrites an existing destination'
    }
}

function Assert-PortableZipPreparation {
    param($State)
    Invoke-InTestDir -Body { param($dir)
        $State.Tool = Join-Path $dir 'bin/tool.exe'
        $State.Calls.Clear()
        $State.SkipExpansion = $false; $State.DownloadFailure = $false; $State.ExpansionFailure = $false
        $toolPath = $State.Tool
        $probe = { if (Test-Path -LiteralPath $toolPath) { $toolPath } }.GetNewClosure()
        $options = @{ Url = 'https://fixture.invalid/tool.zip'; ZipPath = (Join-Path $dir tool.zip); Destination = $dir; Description = 'host tool'; Probe = $probe }
        Assert-Equal $State.Tool (Install-MutPortableZipTool @options)
        Assert-Equal 2 $State.Calls.Count 'a cold tool downloads and expands once'
        Assert-Equal PK $State.Calls[0].Signature
        Assert-Equal 'host tool' $State.Calls[0].Description
        Assert-Equal $options.ZipPath $State.Calls[0].Destination
        Assert-True (Test-Path $options.ZipPath) 'the LiteRT-LM archive remains available'
        Assert-Equal $State.Tool (Install-MutPortableZipTool @options)
        Assert-Equal 2 $State.Calls.Count 'a warm tool avoids both download and extraction'
        Remove-Item -LiteralPath $State.Tool
        $State.Calls.Clear()
        $options.Description = ''
        Assert-Equal $State.Tool (Install-MutPortableZipTool @options -ExpectSignature '' -RemoveArchive -QuietDownload)
        Assert-Equal '' $State.Calls[0].Signature 'LiteRT retains its existing signature policy'
        Assert-Equal '' $State.Calls[0].Description 'LiteRT download label remains the URL'
        Assert-False (Test-Path $options.ZipPath) 'LiteRT removes the fetched archive'
        Remove-Item -LiteralPath $State.Tool
        $State.SkipExpansion = $true
        Assert-Throws { Install-MutPortableZipTool @options -QuietDownload -FailureMessage 'caller missing tool verdict' } -MessagePattern 'caller missing tool verdict'
        Assert-Throws { Install-MutPortableZipTool @options -QuietDownload } -MessagePattern 'Failed to obtain.*under'
        $State.DownloadFailure = $true
        Assert-Throws { Install-MutPortableZipTool @options -QuietDownload } -MessagePattern 'fixture fetch failed'
        $State.DownloadFailure = $false
        $State.ExpansionFailure = $true
        Assert-Throws { Install-MutPortableZipTool @options -QuietDownload } -MessagePattern 'fixture extraction failed'
        $State.ExpansionFailure = $false; $State.SkipExpansion = $false
        $State.Calls.Clear()
        $State.Tool = Join-Path $dir 'protoc-1.2.3/bin/protoc.exe'
        Assert-Equal $State.Tool (Install-MutProtobufCompiler -Version 1.2.3 -WorkDir $dir)
        Assert-Equal 'https://github.com/protocolbuffers/protobuf/releases/download/v1.2.3/protoc-1.2.3-win64.zip' $State.Calls[0].Url
        Assert-Equal (Join-Path $dir protoc-1.2.3-win64.zip) $State.Calls[0].Destination
        Assert-Equal 'version-matched protoc v1.2.3' $State.Calls[0].Description
        Remove-Item -LiteralPath $State.Tool
        $State.SkipExpansion = $true
        Assert-Throws { Install-MutProtobufCompiler -Version 1.2.3 -WorkDir $dir -QuietDownload -FailureMessage { param($path) "specific $path unavailable" } } -MessagePattern ('specific ' + [regex]::Escape($State.Tool) + ' unavailable')
    }.GetNewClosure()
}

function Assert-DllDependencyGraphFixture {
    Invoke-InTestDir -Body { param($dir)
        New-OrtTestPe -Path (Join-Path $dir root.dll) -Import a.dll, missingRoot.dll, b.dll, api-ms-skip.dll, EXT-MS-SKIP.dll, dir.dll
        New-OrtTestPe -Path (Join-Path $dir a.dll) -Import missingA.dll, shared.dll, system.dll
        New-OrtTestPe -Path (Join-Path $dir b.dll) -Import missingB.dll, SHARED.DLL
        New-OrtTestPe -Path (Join-Path $dir shared.dll) -Import a.dll
        New-OrtTestPe -Path (Join-Path $dir 'System32/system.dll') -Import child.dll
        New-OrtTestPe -Path (Join-Path $dir second.exe) -Import other.dll, absent.dll
        New-OrtTestPe -Path (Join-Path $dir api-ms-skip.dll) -DelayImport api-child.dll
        foreach ($name in 'other.dll', 'child.dll', 'api-child.dll') { New-OrtTestPe -Path (Join-Path $dir $name) }
        $null = New-Item -ItemType Directory -Path (Join-Path $dir dir.dll)
        $state = New-TestCallState @{ AllowSystem = $false }
        $reader = {
            param($path)
            $name = [IO.Path]::GetFileName($path)
            Assert-False ($name -eq 'system.dll' -and -not $state.AllowSystem) 'OS imports are excluded from recursion'
            $state.Calls.Add($name)
            if ($name -eq 'dir.dll') { return }
            Get-PeImportNames -Path $path -IncludeDelayLoad
        }.GetNewClosure()
        $options = @{ Path = (Join-Path $dir root.dll); SearchDirectory = @($dir, (Join-Path $dir System32)); ReadImports = $reader }
        $breadth = @(Get-MutDllDependencyGraph @options)
        Assert-Equal 'a.dll|missingRoot.dll|b.dll|dir.dll|missingA.dll|shared.dll|system.dll|missingB.dll' ($breadth.Name -join '|') 'breadth-first graph order'
        Assert-Equal 'root.dll|a.dll|b.dll|shared.dll' ($state.Calls -join '|') 'API sets, cycles, duplicates and OS children are not read'
        Assert-Equal 'a.dll' $breadth[4].From
        Assert-Equal (Join-Path $dir a.dll) $breadth[0].Path
        Assert-Null $breadth[3].Path 'a directory is not a loadable file'
        $state.Calls.Clear()
        $depth = @(Get-MutDllDependencyGraph @options -DepthFirst)
        Assert-Equal 'a.dll|missingA.dll|shared.dll|system.dll|missingRoot.dll|b.dll|missingB.dll|dir.dll' ($depth.Name -join '|') 'depth-first graph order'
        Assert-Equal 'root.dll|a.dll|shared.dll|b.dll' ($state.Calls -join '|')
        $known = [Collections.Generic.HashSet[string]]::new()
        [void]$known.Add('b.dll')
        $withDirectory = @(Get-MutDllDependencyGraph @options -Seen $known -DepthFirst -SystemDirectoryPattern '[\\/](System32|SysWOW64|WinSxS)([\\/]|$)' -ResolveImport {
            param($name, $directories)
            if ($name -eq 'dir.dll') { Join-Path $directories[0] $name }
        })
        Assert-Equal (Join-Path $dir dir.dll) ($withDirectory | Where-Object Name -eq dir.dll).Path 'a caller resolver controls which imports can be visited'
        Assert-False ($withDirectory.Name -contains 'b.dll') 'a caller-provided visited set stays authoritative'
        Assert-False ($withDirectory.Name -contains 'missingB.dll')
        Assert-True $known.Contains('missingroot.dll') 'visited keys retain the builder lower-case convention'
        Assert-Throws { Get-MutDllDependencyGraph @options -ReadImports { throw 'import reader failed' } } -MessagePattern 'import reader failed'
        $options.Path = @((Join-Path $dir root.dll), (Join-Path $dir second.exe))
        $state.Calls.Clear()
        $defaults = @(Get-MutDllDependencyGraph @options)
        Assert-Equal 'a.dll|missingRoot.dll|b.dll|dir.dll|other.dll|absent.dll|missingA.dll|shared.dll|system.dll|missingB.dll' ($defaults.Name -join '|') 'multiple seeds are processed before dependency children'
        Assert-Equal 'root.dll|second.exe|a.dll|b.dll|other.dll|shared.dll' ($state.Calls -join '|') 'default exclusions apply to every root'
        $state.Calls.Clear()
        $state.AllowSystem = $true
        $all = @(Get-MutDllDependencyGraph @options -SkipImportPattern '' -SystemDirectoryPattern '')
        Assert-Equal 'a.dll|missingRoot.dll|b.dll|api-ms-skip.dll|EXT-MS-SKIP.dll|dir.dll|other.dll|absent.dll|missingA.dll|shared.dll|system.dll|missingB.dll|api-child.dll|child.dll' ($all.Name -join '|') 'explicit policies retain indexed API sets and system children'
        Assert-Equal 'root.dll|second.exe|a.dll|b.dll|api-ms-skip.dll|other.dll|shared.dll|system.dll|api-child.dll|child.dll' ($state.Calls -join '|') 'breadth-first traversal spans all seed queues'
        Assert-Null ($all | Where-Object Name -eq absent.dll).Path
    }
}

function Get-PortableZipFixturePrelude {
    (Get-TestDownloadPrelude) + [Environment]::NewLine + @'
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    $State.Calls.Add(@{ Archive = $Path; Destination = $DestinationPath; Force = [bool]$Force })
    if ($State.ExpansionFailure) { throw 'fixture extraction failed' }
    if (-not $State.SkipExpansion) { $null = New-Item -ItemType Directory -Force -Path (Split-Path $State.Tool); [IO.File]::WriteAllText($State.Tool, 'tool') }
}
'@
}

function Assert-RequiredBuildArtifactFixture {
    Invoke-InTestDir -Files @{ 'lib/one.lib' = 'archive'; 'lib/deeper/two.lib' = 'archive' } -Body { param($dir)
        $options = @{ Root = (Join-Path $dir lib); Filter = '*.lib'; FailureMessage = { param($files) "artifact count is $($files.Count)" } }
        $single = @(Get-MutRequiredBuildArtifact @options -MaximumCount 1)
        Assert-Equal 1 $single.Count
        Assert-Equal one.lib $single[0].Name
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'lib/dir.lib')
        [IO.File]::WriteAllText((Join-Path $dir 'lib/ignored.txt'), 'unrelated')
        Assert-Equal one.lib (Get-MutRequiredBuildArtifact @options -MaximumCount 1).Name 'adding a matching directory and unrelated file cannot change the result'
        Assert-Throws { Get-MutRequiredBuildArtifact @options -Recurse -MaximumCount 1 | Out-Null } -MessagePattern 'artifact count is 2'
        Assert-Throws { Get-MutRequiredBuildArtifact @options -Recurse -MinimumCount 3 | Out-Null } -MessagePattern 'artifact count is 2'
        Assert-Equal 2 @(Get-MutRequiredBuildArtifact @options -Recurse).Count
        $options.Root = Join-Path $dir absent
        Assert-Throws { Get-MutRequiredBuildArtifact @options } -MessagePattern 'artifact count is 0'
        Assert-Equal 0 @(Get-MutRequiredBuildArtifact @options -MinimumCount 0 -MaximumCount 0).Count
    }
}

function Assert-SourceTreeCopyContract {
    Invoke-InTestDir -Files @{ 'source/nested/header[1].h' = 'header'; 'source/root.cc' = 'impl'; 'outside.h' = 'outside' } -Body { param($dir)
        $source = Join-Path $dir source
        $destination = Join-Path $dir installed
        $header = Get-Item -LiteralPath (Join-Path $source 'nested/header[1].h')
        $bytes = [byte[]](0xef, 0xbb, 0xbf, 0x41, 0x0d, 0x0a, 0, 0xff)
        [IO.File]::WriteAllBytes($header.FullName, $bytes)
        $options = @{ SourceRoot = $source; DestinationRoot = $destination }
        Assert-Equal 2 (Copy-MutSourceBuildFileTree @options -File @($header, (Get-Item (Join-Path $source root.cc))))
        Assert-Equal ([Convert]::ToHexString($bytes)) ([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $destination 'nested/header[1].h')))) 'relative layout and literal file bytes survive staging'
        Assert-Equal impl ([IO.File]::ReadAllText((Join-Path $destination root.cc)))
        [IO.File]::WriteAllText($header.FullName, 'replacement')
        Assert-Equal 1 (Copy-MutSourceBuildFileTree @options -File @($header))
        Assert-Equal replacement ([IO.File]::ReadAllText((Join-Path $destination 'nested/header[1].h'))) 'a repeated stage replaces an existing file'
        $empty = Join-Path $dir empty
        Assert-Equal 0 (Copy-MutSourceBuildFileTree -SourceRoot $source -DestinationRoot $empty -File @())
        Assert-False (Test-Path $empty) 'an empty selection does not create an install tree'
        Assert-Throws { Copy-MutSourceBuildFileTree -SourceRoot $source -DestinationRoot (Join-Path $destination child) -File @(Get-Item (Join-Path $dir outside.h)) } -MessagePattern 'is outside'
        Assert-False (Test-Path (Join-Path $destination outside.h))
        $gone = Get-Item (Join-Path $source root.cc)
        Remove-Item -LiteralPath $gone.FullName
        $ErrorActionPreference = 'Continue'
        Assert-Throws { Copy-MutSourceBuildFileTree @options -File @($gone) } -MessagePattern 'root\.cc'
    }
}

function Assert-SourcePatchSetContract {
    Invoke-InTestDir -Files @{ 'one.cpp' = 'old'; 'noop.cpp' = 'current'; 'two.cpp' = 'old' } -Body { param($dir)
        $files = @('one.cpp', 'noop.cpp', 'two.cpp' | ForEach-Object { Get-Item (Join-Path $dir $_) })
        $state = New-TestCallState
        $patch = {
            param($file, $nextIndex)
            $state.Calls.Add("patch:$($file.Name):$nextIndex")
            Edit-SourceFile -Path $file.FullName -Require -Quiet -Transform { param($text) $text.Replace('old', "new-$nextIndex") }
        }.GetNewClosure()
        $onChanged = {
            param($file, $index)
            $state.Calls.Add("changed:$($file.Name):$index")
            Write-Information "changed $($file.Name)" -InformationAction Continue
            'callback output'
        }.GetNewClosure()
        $records = @(Invoke-MutSourceFilePatchSet -File $files -Patch $patch -OnChanged $onChanged 6>&1)
        $count = @($records | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
        Assert-Equal 1 $count.Count 'callbacks do not pollute the scalar count'
        Assert-Equal 2 $count[0] 'only changed files are counted'
        Assert-Equal 'patch:one.cpp:1|changed:one.cpp:1|patch:noop.cpp:2|patch:two.cpp:2|changed:two.cpp:2' ($state.Calls -join '|') 'unchanged files do not consume a target index and changed callbacks run immediately'
        Assert-Equal 2 @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] }).Count 'information diagnostics retain their stream'
        Assert-Equal new-2 ([IO.File]::ReadAllText($files[2].FullName))
        Assert-Equal 0 (Invoke-MutSourceFilePatchSet -File $files -Patch $patch)
        Assert-Equal 0 (Invoke-MutSourceFilePatchSet -File @() -Patch { throw 'an empty patch set must not run' })
        $state.Calls.Clear()
        $failingPatch = { param($file) $state.Calls.Add($file.Name); throw 'fixture patch failed' }.GetNewClosure()
        Assert-Throws { Invoke-MutSourceFilePatchSet -File $files -Patch $failingPatch } -MessagePattern 'fixture patch failed'
        Assert-Equal one.cpp ($state.Calls -join '|') 'a patch failure stops later files'
        Assert-Throws { Invoke-MutSourceFilePatchSet -File $files -Patch { $true } -OnChanged { throw 'fixture notification failed' } } -MessagePattern 'fixture notification failed'
    }
}

function Assert-SourceRegexGuardFixture {
    $text = 'alpha($value); middle beta({ $1 }); alpha(last);'
    $actual = @(Add-MutSourceRegexGuard -Text $text -Pattern 'alpha\([^;]*\);', 'beta\([^;]*\);' -Condition '!defined(_WIN32)' -Comment 'fixture $1' -Indent '  ')
    $expected = "#if !defined(_WIN32)  // fixture `$1`n  alpha(`$value);`n#endif middle #if !defined(_WIN32)  // fixture `$1`n  beta({ `$1 });`n#endif #if !defined(_WIN32)  // fixture `$1`n  alpha(last);`n#endif"
    Assert-Equal 1 $actual.Count 'a guard transform returns only the transformed text'
    Assert-Equal $expected $actual[0] 'guarded source bytes preserve every literal match and boundary'
    Assert-Equal '#if ENABLED' (Add-MutSourceRegexGuard -Text '#if ENABLED' -Pattern 'absent' -Condition '!defined(_WIN32)')
    Assert-Equal '' (Add-MutSourceRegexGuard -Text '' -Pattern 'alpha' -Condition ENABLED)
    Assert-Equal 'unchanged' (Add-MutSourceRegexGuard -Text unchanged -Pattern @() -Condition ENABLED)
    Assert-Equal "#if ENABLED`nalpha`n#endif" (Add-MutSourceRegexGuard -Text alpha -Pattern alpha -Condition ENABLED) 'comments and indentation are optional'
    Assert-Equal 'done AB' (Edit-MutSourceRegexText -Text 'ab AB' -Map @(
        @{ Pattern = '(a)b'; Replacement = '${1}bc' }
        @{ Pattern = 'abc'; Replacement = 'done' }
    )) 'ordered regex passes retain capture substitution and case sensitivity'

}

function Assert-StaticLibraryReferenceFixture {
    Assert-SourceFileConversion -Case @{
        ChangedCount = 2; CountMessage = 'both selected absl files are patched'
        ResultMessage = 'absl prefix, canonical case and name scope remain exact'; DescriptionPattern = 'Patched ABSL absl/one.cmake'
        Files = @{ 'absl/one.cmake' = 'libabsl_OK_1.a libABSL_UPPER.a libabsl_skip-hyphen.a libother.a'; 'absl/two.cmake' = 'libabsl_SECOND.a'; 'unchanged.cmake' = 'already correct.lib' }
        Expected = @{ 'absl/one.cmake' = 'absl_OK_1.lib absl_UPPER.lib libabsl_skip-hyphen.a libother.a'; 'absl/two.cmake' = 'absl_SECOND.lib'; 'unchanged.cmake' = 'already correct.lib' }
        Operation = { param($dir)
            Edit-MutSourceStaticLibraryReferences -SourceRoot $dir -RelativePath @('absl/one.cmake', 'absl/two.cmake', 'absl/missing.cmake') `
                -NamePrefix 'absl_' -NamePattern '[A-Za-z0-9_]+' -Description { param($relative) "ABSL $relative" }
        }
        Body = { param($dir)
            Assert-False (Test-Path (Join-Path $dir absl/missing.cmake)) 'missing optional inputs remain absent'
            Assert-Equal 0 (Edit-MutSourceStaticLibraryReferences -SourceRoot $dir -RelativePath @())
            Assert-Equal 0 (Edit-MutSourceStaticLibraryReferences -SourceRoot (Join-Path $dir missing) -RelativePath absent.cmake)
            $null = New-Item -ItemType Directory -Path (Join-Path $dir broken.cmake)
            Assert-Throws { Edit-MutSourceStaticLibraryReferences -SourceRoot $dir -RelativePath broken.cmake } -MessagePattern 'broken\.cmake'
        }
    }
    Assert-SourceFileConversion -Case @{
        ChangedCount = 1; ResultMessage = 'protobuf requires and preserves a leading slash'
        Files = @{ 'protobuf/map.cmake' = 'libbare.a /libproto-lib.a /libUPPER_2.A C:\libwindows.a' }
        Expected = @{ 'protobuf/map.cmake' = 'libbare.a /proto-lib.lib /UPPER_2.lib C:\libwindows.a' }
        Operation = { param($dir) Edit-MutSourceStaticLibraryReferences -SourceRoot $dir -RelativePath protobuf/map.cmake -RequireLeadingSlash -NamePattern '[a-z0-9_-]+' }
    }
    Assert-SourceFileConversion -Case @{
        ChangedCount = 1; ResultMessage = 'generic maps retain hyphens, case-insensitive matching and unrelated names'
        Files = @{ 'all/map.cmake' = 'libfoo.a libbar-baz_2.A lib.a libabsl_foo.a libready.lib' }
        Expected = @{ 'all/map.cmake' = 'foo.lib bar-baz_2.lib lib.a absl_foo.lib libready.lib' }
        Operation = { param($dir) Edit-MutSourceStaticLibraryReferences -SourceRoot $dir -RelativePath all/map.cmake }
    }
}

function Assert-OrtRegexFallbackOperation {
    Invoke-InTestDir -Body { param($dir)
        $SourceDir = Join-Path $dir source
        $scriptAssetRoot = Join-Path $dir assets
        Assert-False (Test-Path $scriptAssetRoot) 'the actual ONNX call sites must take the missing-patch fallback'
        $null = New-Item -ItemType Directory -Path $SourceDir
        Write-TestFileTree -Root $SourceDir -Files @{
            'cmake/onnxruntime_providers_cuda.cmake' = 'before target_precompile_headers(t PRIVATE foo.h) after'
            'onnxruntime/core/framework/tunable.h' = '#include "core/framework/tuning_context.h"'
            'onnxruntime/contrib_ops/cuda/bert/xqa/xqa_impl_gen.cuh' = '#elif defined(HAS_SM80_OR_LATER) || !defined(__CUDACC__)'
        }
        $operation = Get-Command Invoke-MutOrtRegexPatchWithFallback
        Invoke-WithTestFunction -Name Invoke-OrtRegexPatchWithFallback -Definition { & $operation @args }.GetNewClosure() -Body {
            $calls = @(Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-OnnxFromSource.ps1' -Name Invoke-OrtRegexPatchWithFallback -ExpectedCount 3)
            foreach ($call in $calls) { Assert-True (& $call 6>$null) 'a real ONNX fallback reports its replacement' }
        }
        Assert-Equal 'before  after' ([IO.File]::ReadAllText((Join-Path $SourceDir cmake/onnxruntime_providers_cuda.cmake))) 'the PCH fallback strips only the call'
        $expected = '#include "core/framework/tuning_context.h"' + "`n`n#ifdef ERROR`n#undef ERROR`n#endif`n#ifdef VERBOSE`n#undef VERBOSE`n#endif"
        Assert-Equal $expected ([IO.File]::ReadAllText((Join-Path $SourceDir onnxruntime/core/framework/tunable.h))) 'the tunable fallback preserves capture text and macro order'
        Assert-Equal '#else' ([IO.File]::ReadAllText((Join-Path $SourceDir onnxruntime/contrib_ops/cuda/bert/xqa/xqa_impl_gen.cuh))) 'the XQA fallback removes the host-pass guard'
        $null = Invoke-TestGitCommand -Path $SourceDir -ArgumentList init
        Write-TestFileTree -Root $SourceDir -Files @{ 'priority.txt' = "old`n"; 'priority.patch' = "--- a/priority.txt`n+++ b/priority.txt`n@@ -1 +1 @@`n-old`n+patched`n" }
        $options = @{ SourceDir = $SourceDir; RelativePath = 'priority.txt'; Pattern = 'old'; Replacement = 'fallback'; WarnMessage = 'fixture anchor missing'; FallbackNote = 'fixture fallback note' }
        Assert-True (Invoke-MutOrtRegexPatchWithFallback @options -PatchFile (Join-Path $SourceDir priority.patch) 6>$null)
        Assert-Equal patched ([IO.File]::ReadAllText((Join-Path $SourceDir priority.txt)).Trim()) 'the reviewable patch takes precedence over the regex fallback'
        $records = @(Invoke-MutOrtRegexPatchWithFallback @options -PatchFile (Join-Path $dir absent.patch) *>&1)
        Assert-Equal 1 @($records | Where-Object { $_ -is [bool] }).Count 'one fallback verdict reaches stdout'
        Assert-False @($records | Where-Object { $_ -is [bool] })[0] 'a missing anchor stays an advisory miss'
        Assert-Match 'fixture anchor missing' ($records -join '|') 'the caller warning survives the adapter'
        Assert-Match 'fixture fallback note' ($records -join '|') 'the caller fallback note survives the adapter'
        $options.RelativePath = 'absent-source.txt'
        Assert-False (Invoke-MutOrtRegexPatchWithFallback @options -PatchFile (Join-Path $dir absent.patch) 6>$null) 'an optional absent source retains the false verdict'
    }
}

function Assert-TvmProbeOperation {
    $state = New-TestCallState @{ Fail = $false; ExitCode = 9; Error = ''; }
    Invoke-WithTestFunction -Name Invoke-PythonJsonProbe -FixtureState $state -Definition {
        param($Python, $Source, $Prefix, $ArgumentList, [switch]$DiagnosticTail, $FailurePrefix)
        $State.Calls.Add(@{
            Python = $Python; Source = $Source; Prefix = $Prefix; ArgumentList = @($ArgumentList)
            DiagnosticTail = $DiagnosticTail.IsPresent; FailurePrefix = $FailurePrefix
        })
        if ($State.Error) { throw $State.Error }
        if ($State.Fail) { throw "$FailurePrefix $($State.ExitCode) without a report: probe stderr detail | value=7" }
        return @{ value = 7 }
    } -Body { param($State)
        $options = @{ Python = 'python-fixture'; Probe = 'runtime'; Source = "print('runtime')`n"; ArgumentList = @('', 'C:\HIP bin', '--literal=one;two') }
        $report = Invoke-MutTvmRocmProbe @options
        Assert-Equal 7 $report.value 'shared transport report reaches TVM findings'
        Assert-Equal $options.Python $State.Calls[0].Python 'interpreter reaches shared transport'
        Assert-Equal $options.Source $State.Calls[0].Source 'source bytes reach shared transport'
        Assert-Equal 'tvm-rocm-runtime' $State.Calls[0].Prefix 'TVM keeps a component-specific temp-file prefix'
        Assert-True $State.Calls[0].DiagnosticTail 'TVM failures retain the child diagnostic tail'
        Assert-Equal 'TVM: the runtime probe exited' $State.Calls[0].FailurePrefix 'TVM findings keep their failure label'
        Assert-Equal '|C:\HIP bin|--literal=one;two' ($State.Calls[0].ArgumentList -join '|') 'empty and spaced arguments remain separate'
        $State.Fail = $true
        foreach ($code in 9, 0) {
            $State.ExitCode = $code
            $thrown = $null
            try { $failure = Invoke-MutTvmRocmProbe @options } catch { $thrown = $_.Exception.Message }
            Assert-Null $thrown 'failed child probes stay findings instead of aborting Test-RocmImage'
            Assert-Match "TVM: the runtime probe exited $code without a report: .*probe stderr detail.*value" $failure 'nonzero or empty reports preserve the caller finding and diagnostic tail'
        }
        $State.Fail = $false; $State.Error = 'python is not executable'
        Assert-Throws { Invoke-MutTvmRocmProbe @options } -MessagePattern 'python is not executable'
    }
}

function Assert-UrlFileNameOperation {
    $examples = @(
        ,@('https://fixture.invalid/wheels/torch.whl', 'torch.whl')
        ,@('https://fixture.invalid/releases/torch%2Brocm%20build.whl?download=1#proof', 'torch+rocm build.whl')
        ,@('https://fixture.invalid/ignored%20parent/kept%2520escape.whl', 'kept%20escape.whl')
        ,@('https://fixture.invalid/encoded%2Fsegment.whl', 'encoded/segment.whl')
    )
    foreach ($example in $examples) {
        Assert-Equal $example[1] (Get-MutUrlFileName -Url $example[0]) 'the final URI segment is decoded exactly once'
    }
    $operation = Get-Command Get-MutUrlFileName
    Invoke-WithTestFunction -Name Get-UrlFileName -Definition { & $operation @args }.GetNewClosure() -Body {
        $url = 'https://stable.repo.amd.com/rocm/releases/torch%2Brocm.whl?download=1'
        Assert-Equal 'torch+rocm.whl' (Get-MutUrlFileName -Url $url) 'AMD runtime URLs retain the wheel local version'
        foreach ($scriptPath in @('windows/scripts/build/Build-TorchRocmFromSource.ps1', 'windows/scripts/build/Copy-Arm64TorchWheels.ps1')) {
            $call = Get-TestScriptCommandBlock -ScriptPath $scriptPath -Name Get-UrlFileName
            Assert-Equal 'torch+rocm.whl' (& $call) 'both build callers delegate the same filename leaf'
        }
    }
}

function Assert-CudaTargetPolicyFixture {
    Assert-True (Test-MutCudaTargetUsable -GpuEnvironment @{ HasCuda = $true } -CrossTarget $false) 'native CUDA does not inspect target payload or root'
    foreach ($cross in $false, $true) {
        Assert-False (Test-MutCudaTargetUsable -GpuEnvironment @{ HasCuda = $false } -CrossTarget $cross) 'disabled CUDA short-circuits without reading its root'
    }
    Invoke-InTestDir -Files @{ 'lib/arm64/cudart.lib' = ''; 'lib/arm64/cudadevrt.lib' = ''; 'lib/x64/cudadevrt.lib' = 'host decoy' } -Body { param($dir)
        $gpu = @{ HasCuda = $true; CudaRoot = $dir }
        $records = @(Test-MutCudaTargetUsable -GpuEnvironment $gpu -CrossTarget $true)
        Assert-Equal 1 $records.Count 'the target decision emits one verdict'
        Assert-True ($records[0] -is [bool]) 'the target decision emits a boolean'
        Assert-True $records[0] 'cross CUDA accepts both target import libraries'
        Assert-False (Test-MutCudaTargetUsable -GpuEnvironment @{ HasCuda = $false; CudaRoot = $dir } -CrossTarget $true) 'a payload cannot override disabled CUDA'
        Remove-Item -LiteralPath (Join-Path $dir lib/arm64/cudadevrt.lib)
        Assert-False (Test-MutCudaTargetUsable -GpuEnvironment $gpu -CrossTarget $true) 'cross CUDA refuses a partial target payload despite host libraries'
        $gpu.CudaRoot = Join-Path $dir absent
        Assert-False (Test-MutCudaTargetUsable -GpuEnvironment $gpu -CrossTarget $true) 'cross CUDA refuses an absent target payload'
    }
}

Describe 'Shared source-build preparation' {
    $patchModule = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1'
    $patchPrelude = "Import-Module '$($patchModule.Replace("'", "''"))' -ErrorAction Stop"
    $scenarios = @(
        @{ Name = 'copies source-build files only when the source exists and destination is absent'
            FunctionName = @('Copy-SourceBuildFileIfAbsent'); Body = { Assert-SourceBuildCopyIfAbsent }; Mutation = @(
                @{ Find = 'if ((Test-Path $SourcePath) -and -not (Test-Path $DestinationPath)) {'; Replace = 'if (Test-Path $SourcePath) {'; Expected = 'an existing destination is preserved' }
            ) }
        @{ Name = 'gates compiler caching on remote configuration plus an executable and preserves the caller job limit'
            FunctionName = @('Get-SourceBuildSccache'); Body = { Assert-SourceCachePreparation }; Mutation = @(
                @{ Find = 'if (-not $RemoteConfigured) { return $null }'; Replace = ''; Expected = 'remote backend is required' }
                @{ Find = 'if (-not $env:SCCACHE_MAX_JOBS)'; Replace = 'if ($true)'; Expected = 'explicit job limit survives discovery' }
            ) }
        @{ Name = 'shares ZIP acquisition while retaining warm probes, signatures, archive cleanup and strict postconditions'
            FunctionName = @('Install-PortableZipTool', 'Install-ProtobufCompiler'); Body = { param($state) Assert-PortableZipPreparation $state }
            FixtureState = (New-TestCallState @{ Tool = ''; SkipExpansion = $false; DownloadFailure = $false; ExpansionFailure = $false; Download = { param($record, $state) if ($state.DownloadFailure) { throw 'fixture fetch failed' } } })
            Mutation = @(@{ Find = @'
    if (-not $found) {
        if ($FailureMessage) { throw $FailureMessage }
        throw "Failed to obtain $Description under $Destination"
    }
'@; Replace = ''; Expected = 'expected an exception but none was thrown' })
            Prelude = (Get-PortableZipFixturePrelude) }
        @{ Name = 'shares DLL traversal while retaining caller order, visited state, resolution predicates and system-library boundaries'
            ScriptPath = 'windows/scripts/modules/WindowsTargetArch.Common.psm1'
            FunctionName = @('Get-DllDependencyEntry', 'Get-DllDependencyGraph'); Body = { Assert-DllDependencyGraphFixture }; Mutation = @(
                @{ Find = 'if ($Context.DepthFirst)'; Replace = 'if ($false)'; Expected = 'depth-first graph order' }
                @{ Find = 'if ($hit -and (-not $Context.SystemDirectoryPattern -or $hit -notmatch $Context.SystemDirectoryPattern))'; Replace = 'if ($hit)'; Expected = 'OS imports are excluded from recursion' }
                @{ Find = 'Pending = [Collections.Generic.List[string]]::new([string[]]$Path)'; Replace = 'Pending = [Collections.Generic.List[string]]::new([string[]]@($Path[0]))'; Expected = 'multiple seeds are processed before dependency children' }
                @{ Find = 'SkipImportPattern = $SkipImportPattern'; Replace = "SkipImportPattern = '^(api|ext)-ms-'"; Expected = 'explicit policies retain indexed API sets and system children' }
                @{ Find = '(-not $Context.SystemDirectoryPattern -or $hit -notmatch $Context.SystemDirectoryPattern)'; Replace = '($hit -notmatch $Context.SystemDirectoryPattern)'; Expected = 'explicit policies retain indexed API sets and system children' }
            ) }
        @{ Name = 'enforces caller artifact cardinality while retaining file filters and recursive policy'
            FunctionName = @('Get-RequiredBuildArtifact'); Body = { Assert-RequiredBuildArtifactFixture }
            Mutation = @(@{ Find = 'if ($files.Count -lt $MinimumCount -or $files.Count -gt $MaximumCount) { throw (& $FailureMessage $files) }'
                Replace = ''; Expected = 'expected an exception but none was thrown' }) }
        @{ Name = 'stages selected files byte-for-byte and fails on escaped or missing inputs'
            FunctionName = @('Copy-SourceBuildFileTree'); Body = { Assert-SourceTreeCopyContract }; Mutation = @(
                @{ Find = "if ([IO.Path]::IsPathRooted(`$relative) -or `$relative -match '^\.\.([\\/]|$)')"; Replace = 'if ($false)'; Expected = 'expected an exception but none was thrown' }
                @{ Find = 'Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop'; Replace = 'Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction SilentlyContinue'; Expected = 'expected an exception but none was thrown' }
            ) }
        @{ Name = 'preserves ordered patch results, next changed indices and notification streams'
            ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1'
            FunctionName = @('Invoke-SourceFilePatchSet'); Body = { Assert-SourcePatchSetContract }; Mutation = @(
                @{ Find = '($changed + 1)'; Replace = '($changed + 2)'; Expected = 'unchanged files do not consume a target index' }
                @{ Find = 'if (& $Patch $item ($changed + 1))'; Replace = 'if ((& $Patch $item ($changed + 1)) -or $true)'; Expected = 'only changed files are counted' }
                @{ Find = '& $OnChanged $item $changed | Out-Null'; Replace = '& $OnChanged $item $changed'; Expected = 'callbacks do not pollute the scalar count' }
            ) }
        @{ Name = 'wraps every ordered regex match in literal source guards without owning file policy'
            ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1'
            FunctionName = @('Add-SourceRegexGuard', 'Edit-SourceRegexText'); Body = { Assert-SourceRegexGuardFixture }; Mutation = @(
                @{ Find = '$prefix + $match.Value + "`n#endif"'; Replace = '$prefix + "`n#endif"'; Expected = 'guarded source bytes' }
                @{ Find = '$prefix + $match.Value + "`n#endif"'; Replace = '$prefix + $match.Value'; Expected = 'guarded source bytes' }
                @{ Find = 'foreach ($expression in $Pattern)'; Replace = 'foreach ($expression in @($Pattern[0]))'; Expected = 'guarded source bytes' }
                @{ Find = 'foreach ($edit in $Map)'; Replace = 'foreach ($edit in @($Map[0]))'; Expected = 'guarded source bytes|ordered regex passes' }
            ) }
        @{ Name = 'shares breadth-first traversal while retaining indexed API sets, system children and per-DLL machine verdicts'
            ScriptPath = 'windows/scripts/modules/WindowsCrossBundle.Common.psm1'
            FunctionName = @('Get-PeImportClosure'); Body = { Assert-ClosureRootPolicies }; Mutation = @(
                @{ Find = "-SkipImportPattern ''"; Replace = ''; Expected = 'every seed stays ahead of its imported children' }
                @{ Find = "-SystemDirectoryPattern ''"; Replace = ''; Expected = 'every seed stays ahead of its imported children' }
                @{ Find = '$null = & $assertMachine -Path $source -Arch $Arch -Context "closure DLL imported as $name, which the device could not load"'; Replace = ''; Expected = 'expected an exception but none was thrown' }
            ) }
        @{ Name = 'shares static-library reference conversion while retaining prefix, slash and optional-file policies'
            ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1'
            FunctionName = @('Read-SourcePatchInput', 'Save-SourcePatchText', 'Invoke-InlineRegexPatch', 'Invoke-SourceFilePatchSet', 'Edit-SourceStaticLibraryReferences')
            Body = { Assert-StaticLibraryReferenceFixture }; Mutation = @(
                @{ Find = "`$slash = if (`$RequireLeadingSlash) { '/' } else { '' }"; Replace = "`$slash = ''"; Expected = 'protobuf requires and preserves a leading slash' }
                @{ Find = "[regex]::Escape(`$NamePrefix)"; Replace = "''"; Expected = 'absl prefix, canonical case and name scope remain exact|both selected absl files are patched' }
                @{ Find = '-Guard $pattern'; Replace = ''; Expected = 'already-converted inputs remain quiet' }
                @{ Find = '-File $RelativePath'; Replace = '-File @($RelativePath[0])'; Expected = 'both selected absl files are patched' }
            ) }
        @{ Name = 'preserves ONNX patch precedence, all three regex callbacks and caller diagnostics'
            ScriptPath = 'windows/scripts/build/Build-OnnxFromSource.ps1'; FunctionName = @('Invoke-OrtRegexPatchWithFallback'); Prelude = $patchPrelude
            Body = { Assert-OrtRegexFallbackOperation }; Mutation = @(
                @{ Find = '-Replacement $Replacement'; Replace = "-Replacement ''"; Expected = 'tunable fallback preserves capture text|real ONNX fallback' }
                @{ Find = '-WarnMessage $WarnMessage'; Replace = "-WarnMessage 'lost warning'"; Expected = 'caller warning survives' }
                @{ Find = '-SourceDir $SourceDir -FallbackNote'; Replace = '-SourceDir (Join-Path $SourceDir absent) -FallbackNote'; Expected = 'reviewable patch takes precedence' }
            ) }
        @{ Name = 'preserves TVM source bytes, argv, merged diagnostics and failed or empty probe verdicts'
            ScriptPath = 'windows/scripts/build/rocm-checks/TVM.ps1'; FunctionName = @('Invoke-TvmRocmProbe')
            Body = { Assert-TvmProbeOperation }; Mutation = @(
                @{ Find = '-ArgumentList $ArgumentList'; Replace = ''; Expected = 'empty and spaced arguments remain separate' }
                @{ Find = '-DiagnosticTail'; Replace = ''; Expected = 'TVM failures retain the child diagnostic tail' }
                @{ Find = '-FailurePrefix "TVM: the $Probe probe exited"'; Replace = '-FailurePrefix $Probe'; Expected = 'TVM findings keep their failure label' }
                @{ Find = 'if ($_.Exception.Message -match ''^TVM: the .+ probe exited \d+ without a report'')'; Replace = 'if ($false)'; Expected = 'failed child probes stay findings instead of aborting Test-RocmImage' }
            ) }
        @{ Name = 'preserves the percent-decoded URL final segment and both wheel builder bindings'
            ScriptPath = 'windows/scripts/modules/WindowsScripts.Shared.psm1'; FunctionName = @('Get-UrlFileName')
            Body = { Assert-UrlFileNameOperation }; Mutation = @(
                @{ Find = 'return [uri]::UnescapeDataString(([uri]$Url).Segments[-1])'; Replace = 'return ([uri]$Url).Segments[-1]'; Expected = 'final URI segment is decoded exactly once' }
                @{ Find = '.Segments[-1]'; Replace = '.Segments[0]'; Expected = 'final URI segment is decoded exactly once' }
            ) }
        @{ Name = 'shares the CUDA native and cross decision with disabled, complete and missing target payloads'
            ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Cuda.psm1'; FunctionName = @('Test-CudaTargetUsable', 'Test-CudaWindowsArm64Payload', 'Get-CudaRoot')
            Body = { Assert-CudaTargetPolicyFixture }; Mutation = @(
                @{ Find = '$GpuEnvironment.HasCuda -and'; Replace = ''; Expected = 'disabled CUDA short-circuits|payload cannot override disabled CUDA' }
                @{ Find = '(-not $CrossTarget)'; Replace = '$false'; Expected = 'CudaRoot|native CUDA does not inspect' }
                @{ Find = 'Test-CudaWindowsArm64Payload -CudaRoot $GpuEnvironment.CudaRoot'; Replace = '$true'; Expected = 'cross CUDA refuses a partial target payload' }
            ) }
    )
    $prepare = Get-Command New-SourcePreparationArguments
    Invoke-TestMutationChecks -Check $scenarios -ArgumentsFactory {
        param($scenario)
        $parameters = $scenario.Clone()
        $parameters.Remove('Name')
        & $prepare @parameters
    }.GetNewClosure()

    It 'keeps LLVM bare launchers, GStreamer shims and each ZIP consumer policy at the actual call sites' {
        $llvm = Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-LlvmFromSource.ps1' -Name Get-SourceBuildSccache
        Assert-Equal 1 @($llvm).Count
        $gst = Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -Name Get-SourceBuildSccache
        Assert-Equal 1 @($gst).Count
        $lite = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-LitertFromSource.ps1' -Name Install-ProtobufCompiler)
        Assert-Equal 1 $lite.Count
        $options = Get-TestCommandArguments -Command $lite[0]
        Assert-Equal "''" $options.ExpectSignature
        Assert-True $options.ContainsKey('RemoveArchive')
        Assert-True $options.ContainsKey('QuietDownload')
        Assert-Match 'LiteRT cross: host protoc missing' $options.FailureMessage
        $lmCalls = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-LitertLmFromSource.ps1' -Name Install-ProtobufCompiler)
        Assert-Equal 1 $lmCalls.Count
        foreach ($call in $lmCalls) {
            $arguments = Get-TestCommandArguments -Command $call
            Assert-False $arguments.ContainsKey('ExpectSignature') 'LiteRT-LM keeps PK validation by default'
            Assert-False $arguments.ContainsKey('RemoveArchive') 'LiteRT-LM retains its archives'
        }
        $gstArtifacts = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -Name Get-RequiredBuildArtifact)
        Assert-Equal 1 $gstArtifacts.Count
        Assert-Equal 1 (Get-TestCommandArguments -Command $gstArtifacts[0]).MaximumCount
        $liteArtifacts = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-LitertFromSource.ps1' -Name Get-RequiredBuildArtifact)
        Assert-Equal 1 $liteArtifacts.Count
        Assert-False (Get-TestCommandArguments -Command $liteArtifacts[0]).ContainsKey('MaximumCount') 'LiteRT retains every installed library'
    }

    It 'keeps the GStreamer dumpbin provider and depth-first missing-name stream in the actual wrapper' {
        Invoke-InTestDir -Body { param($dir)
            New-OrtTestPe -Path (Join-Path $dir plugin.dll) -Import child.dll, parent-missing.dll, api-ms-loader.dll
            New-OrtTestPe -Path (Join-Path $dir child.dll) -Import child-missing.dll
            $state = New-TestCallState @{ Root = $dir; Code = 0 }
            Invoke-WithTestNativeCommand -Name Invoke-DependencyDumpbin -FixtureState $state -Implementation { param($State, $ArgumentList)
                Assert-Equal /dependents $ArgumentList[0]
                if ([IO.Path]::GetFileName($ArgumentList[1]) -eq 'plugin.dll') { '    child.dll'; '    parent-missing.dll'; '    api-ms-loader.dll' }
                else { '    child-missing.dll' }
            } -Body { param($state)
                $recipe = New-SourcePreparationArguments -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -FunctionName Get-UnresolvedDeps `
                    -FixtureState $state -Mutation @(@{ Find = '-ReadImports $readImports -DepthFirst -Seen $Seen'; Replace = '-ReadImports $readImports -Seen $Seen'; Expected = 'the builder emits child findings before parent findings' }) `
                    -Body { param($state)
                        $missing = @(Get-MutUnresolvedDeps (Join-Path $state.Root plugin.dll) Invoke-DependencyDumpbin @($state.Root) ([Collections.Generic.HashSet[string]]::new()))
                        Assert-Equal 'child-missing.dll|parent-missing.dll' ($missing -join '|') 'the builder emits child findings before parent findings'
                    }
                Invoke-TestFunctionMutations @recipe -IncludeControl
            }
        }
    }

    It 'uses the shared copy-if-absent operation while keeping each caller diagnostic local' {
        $graft = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Export-LitertLmBridge.ps1' -Name Copy-SourceBuildFileIfAbsent)
        Assert-Equal 1 $graft.Count
        $pyconfig = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' -Name Copy-SourceBuildFileIfAbsent)
        Assert-Equal 1 $pyconfig.Count
        Assert-Match 're-homed' ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/build/Export-LitertLmBridge.ps1')))
        Assert-Match 'Copied pyconfig.h' ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1')))
    }
}

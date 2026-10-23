#requires -Version 7.0
# Fixtures cover preparation, artifact verdicts and DLL graph policy; they do not compile upstream projects or fetch from the network.

function Invoke-SourcePreparationFixture {
    param([string[]]$FunctionName, [scriptblock]$Body, [Collections.IDictionary[]]$Mutation,
        [string]$Prelude = '', [object]$FixtureState,
        [string]$ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Common.psm1')
    $module = @{ ScriptPath = $ScriptPath; FunctionName = $FunctionName; Prelude = $Prelude }
    if ($null -ne $FixtureState) { $module.FixtureState = $FixtureState }
    # Literal mutants must match the source module's committed line endings.
    $newline = if ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $ScriptPath)).Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($edit in $Mutation) { $edit.Find = $edit.Find -replace '\r?\n', $newline }
    Invoke-WithFunctionModule @module -Body $Body
    Invoke-TestFunctionMutations -ModuleArguments $module -Case $Mutation -Body $Body
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
        New-OrtTestPe -Path (Join-Path $dir 'System32/system.dll')
        $null = New-Item -ItemType Directory -Path (Join-Path $dir dir.dll)
        $read = [Collections.Generic.List[string]]::new()
        $reader = {
            param($path)
            $name = [IO.Path]::GetFileName($path)
            Assert-False ($name -eq 'system.dll') 'OS imports are excluded from recursion'
            $read.Add($name)
            if ($name -eq 'dir.dll') { return }
            Get-PeImportNames -Path $path -IncludeDelayLoad
        }.GetNewClosure()
        $options = @{ Path = (Join-Path $dir root.dll); SearchDirectory = @($dir, (Join-Path $dir System32)); ReadImports = $reader }
        $breadth = @(Get-MutDllDependencyGraph @options)
        Assert-Equal 'a.dll|missingRoot.dll|b.dll|dir.dll|missingA.dll|shared.dll|system.dll|missingB.dll' ($breadth.Name -join '|') 'breadth-first graph order'
        Assert-Equal 'root.dll|a.dll|b.dll|shared.dll' ($read -join '|') 'API sets, cycles, duplicates and OS children are not read'
        Assert-Equal 'a.dll' $breadth[4].From
        Assert-Equal (Join-Path $dir a.dll) $breadth[0].Path
        Assert-Null $breadth[3].Path 'a directory is not a loadable file'
        $read.Clear()
        $depth = @(Get-MutDllDependencyGraph @options -DepthFirst)
        Assert-Equal 'a.dll|missingA.dll|shared.dll|system.dll|missingRoot.dll|b.dll|missingB.dll|dir.dll' ($depth.Name -join '|') 'depth-first graph order'
        Assert-Equal 'root.dll|a.dll|shared.dll|b.dll' ($read -join '|')
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
    }
}

function Get-PortableZipFixturePrelude {
    @'
function Invoke-DownloadWithRetry {
    param($Url, $DestinationPath, $Description, $ExpectSignature)
    $State.Calls.Add(@{ Url = $Url; Destination = $DestinationPath; Description = $Description; Signature = $ExpectSignature })
    if ($State.DownloadFailure) { throw 'fixture fetch failed' }
    [IO.File]::WriteAllText($DestinationPath, 'archive')
}
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

Describe 'Shared source-build preparation' {
    $scenarios = @(
        @{ Name = 'gates compiler caching on remote configuration plus an executable and preserves the caller job limit'
            FunctionName = @('Get-SourceBuildSccache'); Body = { Assert-SourceCachePreparation }; Mutation = @(
                @{ Find = 'if (-not $RemoteConfigured) { return $null }'; Replace = ''; Expected = 'remote backend is required' }
                @{ Find = 'if (-not $env:SCCACHE_MAX_JOBS)'; Replace = 'if ($true)'; Expected = 'explicit job limit survives discovery' }
            ) }
        @{ Name = 'shares ZIP acquisition while retaining warm probes, signatures, archive cleanup and strict postconditions'
            FunctionName = @('Install-PortableZipTool', 'Install-ProtobufCompiler'); Body = { param($state) Assert-PortableZipPreparation $state }
            FixtureState = (New-TestCallState @{ Tool = ''; SkipExpansion = $false; DownloadFailure = $false; ExpansionFailure = $false })
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
                @{ Find = 'if ($hit -and $hit -notmatch $Context.SystemDirectoryPattern)'; Replace = 'if ($hit)'; Expected = 'OS imports are excluded from recursion' }
            ) }
        @{ Name = 'enforces caller artifact cardinality while retaining file filters and recursive policy'
            FunctionName = @('Get-RequiredBuildArtifact'); Body = { Assert-RequiredBuildArtifactFixture }
            Mutation = @(@{ Find = 'if ($files.Count -lt $MinimumCount -or $files.Count -gt $MaximumCount) { throw (& $FailureMessage $files) }'
                Replace = ''; Expected = 'expected an exception but none was thrown' }) }
    )
    foreach ($scenario in $scenarios) {
        It $scenario.Name {
            $parameters = $scenario.Clone()
            $parameters.Remove('Name')
            Invoke-SourcePreparationFixture @parameters
        }.GetNewClosure()
    }

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
                Invoke-SourcePreparationFixture -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -FunctionName Get-UnresolvedDeps `
                    -FixtureState $state -Mutation @(@{ Find = '-ReadImports $readImports -DepthFirst -Seen $Seen'; Replace = '-ReadImports $readImports -Seen $Seen'; Expected = 'the builder emits child findings before parent findings' }) `
                    -Body { param($state)
                        $missing = @(Get-MutUnresolvedDeps (Join-Path $state.Root plugin.dll) Invoke-DependencyDumpbin @($state.Root) ([Collections.Generic.HashSet[string]]::new()))
                        Assert-Equal 'child-missing.dll|parent-missing.dll' ($missing -join '|') 'the builder emits child findings before parent findings'
                    }
            }
        }
    }
}

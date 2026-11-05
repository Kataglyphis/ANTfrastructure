#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The native-DLL manifest over synthetic trees and meson records; real DLL origins and a license's legal fit are not covered.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNativeProvenance.Common.psm1') -Force -DisableNameChecking

function New-ProvenanceTree {
    $root = New-TestDir -Prefix 'native-provenance'
    Write-TestFileTree -Root $root -Files @{ 'bin\a.dll' = 'bytes-a'; 'n\LICENSE' = 'text-a' }
    $entryArgs = @{ Root = $root; File = 'bin\a.dll'; Notice = 'n\LICENSE'; Source = @{ Name = 'a'; Version = '1'; Url = 'https://example.invalid/a'; Sha256 = '' } }
    $manifest = Join-Path $root 'm.json'
    $manifestArgs = @{ Path = $manifest; Owner = 'test'; Entry = @(New-NativeProvenanceEntry @entryArgs); Root = $root }
    Write-NativeProvenanceManifest @manifestArgs
    return [pscustomobject]@{ Root = $root; Manifest = $manifest }
}

function Edit-ProvenanceManifest {
    param([string]$Path, [scriptblock]$Edit)
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    & $Edit $doc
    Set-Content -LiteralPath $Path -Value ($doc | ConvertTo-Json -Depth 6)
}

Describe 'Native provenance manifest' {
    It 'accepts an intact tree and drops empty source fields' {
        $t = New-ProvenanceTree
        try {
            Assert-Equal 0 @(Get-NativeProvenanceFinding -Path $t.Manifest -Root $t.Root).Count 'an intact tree has no finding'
            $doc = Get-Content -LiteralPath $t.Manifest -Raw | ConvertFrom-Json
            Assert-False ($doc.entries[0].source.PSObject.Properties.Name -contains 'sha256') 'an empty hash is left out, not recorded blank'
        } finally { Remove-TestDir $t.Root }
    }

    It 'refuses every defect the consumer notice gate relies on (mutation)' {
        $cases = @(
            @{ Pattern = 'differs from its recorded bytes'; Break = { param($t) [IO.File]::WriteAllText((Join-Path $t.Root 'bin\a.dll'), 'other') } }
            @{ Pattern = 'a\.dll is missing'; Break = { param($t) Remove-Item -LiteralPath (Join-Path $t.Root 'bin\a.dll') } }
            @{ Pattern = 'notice n\\LICENSE differs'; Break = { param($t) [IO.File]::WriteAllText((Join-Path $t.Root 'n\LICENSE'), 'other') } }
            @{ Pattern = 'notice n\\LICENSE is missing'; Break = { param($t) Remove-Item -LiteralPath (Join-Path $t.Root 'n\LICENSE') } }
            @{ Pattern = 'has no notice text'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries[0].notices = @() } } }
            @{ Pattern = 'has no source name'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries[0].source.url = '' } } }
            @{ Pattern = 'listed twice'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries = @($d.entries[0], $d.entries[0]) } } }
            @{ Pattern = 'climbs out'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries[0].file = '..\a.dll' } } }
            @{ Pattern = 'is rooted'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries[0].notices[0].path = 'C:\n\LICENSE' } } }
            @{ Pattern = 'expected 1'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.schema = 2 } } }
            @{ Pattern = 'lists nothing'; Break = { param($t) Edit-ProvenanceManifest $t.Manifest { param($d) $d.entries = @() } } }
            @{ Pattern = 'manifest .* is missing'; Break = { param($t) Remove-Item -LiteralPath $t.Manifest } }
        )
        foreach ($case in $cases) {
            $t = New-ProvenanceTree
            try {
                & $case.Break $t
                $found = @(Get-NativeProvenanceFinding -Path $t.Manifest -Root $t.Root) -join '; '
                Assert-True ($found -match $case.Pattern) "expected /$($case.Pattern)/, got: $found"
                Assert-Throws { Assert-NativeProvenanceManifest -Path $t.Manifest -Root $t.Root } -MessagePattern 'fails:'
            } finally { Remove-TestDir $t.Root }
        }
    }

    It 'requires a named file and refuses an empty manifest' {
        $t = New-ProvenanceTree
        try {
            Assert-True ((@(Get-NativeProvenanceFinding -Path $t.Manifest -Root $t.Root -RequiredFile 'bin\b.dll') -join ';') -match 'b\.dll is not in the manifest') 'a required file must be listed'
            Assert-Throws { Write-NativeProvenanceManifest -Path (Join-Path $t.Root 'e.json') -Owner 'x' -Entry @() -Root $t.Root } -MessagePattern 'empty'
        } finally { Remove-TestDir $t.Root }
    }

    It 'walks the import closure, stops at unstaged names and reports only unlisted DLLs' {
        $t = New-ProvenanceTree
        try {
            Write-TestFileTree -Root $t.Root -Files @{ 'bin\b.dll' = 'b'; 'bin\c.dll' = 'c' }
            $imports = @{ 'plugin.dll' = 'a.dll KERNEL32.dll'; 'a.dll' = 'b.dll'; 'b.dll' = 'c.dll a.dll'; 'c.dll' = '' }
            $get = { param($path) $imports[(Split-Path -Leaf $path)] -split ' ' | Where-Object { $_ } }.GetNewClosure()
            $gap = @(Get-NativeClosureGap -ManifestPath $t.Manifest -Directory (Join-Path $t.Root 'bin') -Importer 'plugin.dll' -GetImport $get)
            Assert-Equal 'b.dll,c.dll' ($gap -join ',') 'transitive unlisted DLLs are named; listed and system ones are not'
        } finally { Remove-TestDir $t.Root }
    }
}

Describe 'Meson records to manifest entries' {
    It 'maps a wrap, an in-tree subproject and the root project, and fails a source without notices' {
        $root = New-TestDir -Prefix 'meson-provenance'
        try {
            $src = Join-Path $root 'src'
            $install = Join-Path $root 'inst'
            $info = Join-Path $root 'b\meson-info'
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $src 'subprojects\zlib-1.3'), (Join-Path $src 'subprojects\gst-good'), (Join-Path $src 'subprojects\ffi'), (Join-Path $install 'bin'), $info
            Set-Content -LiteralPath (Join-Path $src 'subprojects\zlib.wrap') -Value "[wrap-file]`ndirectory = zlib-1.3`nsource_url = https://example.invalid/z.tar.xz`nsource_hash = abc`n`n[provide]`ndependency_names = zlib"
            Set-Content -LiteralPath (Join-Path $src 'subprojects\ffi.wrap') -Value "[wrap-file]`ndirectory = ffi-as-released`nsource_url = https://example.invalid/f.tar.xz"
            foreach ($file in 'src\LICENSE', 'src\subprojects\zlib-1.3\LICENSE', 'src\subprojects\gst-good\COPYING', 'src\subprojects\ffi\LICENSE') { Set-Content -LiteralPath (Join-Path $root $file) -Value $file }
            foreach ($dll in 'z-1.dll', 'gstgood.dll', 'gst.dll', 'ffi-7.dll') { Set-Content -LiteralPath (Join-Path $install "bin\$dll") -Value $dll }
            $targets = @(
                @{ installed = $true; subproject = 'zlib'; defined_in = (Join-Path $src 'subprojects\zlib-1.3\meson.build'); install_filename = @((Join-Path $install 'bin\z-1.dll'), (Join-Path $install 'lib\z.lib')) }
                @{ installed = $true; subproject = 'gst-good'; defined_in = (Join-Path $src 'subprojects/gst-good/ext/meson.build'); install_filename = @(Join-Path $install 'bin\gstgood.dll') }
                @{ installed = $true; subproject = 'ffi'; defined_in = (Join-Path $src 'subprojects\ffi\src\meson.build'); install_filename = @(Join-Path $install 'bin\ffi-7.dll') }
                @{ installed = $true; subproject = $null; defined_in = (Join-Path $src 'meson.build'); install_filename = @(Join-Path $install 'bin\gst.dll') }
                @{ installed = $false; subproject = 'zlib'; install_filename = @() }
            )
            Set-Content -LiteralPath (Join-Path $info 'intro-targets.json') -Value ($targets | ConvertTo-Json -Depth 4)
            Set-Content -LiteralPath (Join-Path $info 'intro-projectinfo.json') -Value (@{ version = '1.0'; subprojects = @(@{ name = 'zlib'; version = '1.3' }, @{ name = 'gst-good'; version = '1.0' }, @{ name = 'ffi'; version = '3.2' }) } | ConvertTo-Json -Depth 4)
            $wrap = Get-MesonWrapInventory -SubprojectDir (Join-Path $src 'subprojects')
            Assert-Equal 'zlib-1.3' $wrap['zlib'].Directory 'the wrap names its directory'
            $call = @{ BuildDir = (Join-Path $root 'b'); SourceDir = $src; Root = $install; NoticeDir = 'n'; Wrap = $wrap; RootSource = @{ Name = 'gst'; Version = '1.0'; Url = 'https://example.invalid/g' } }
            $entries = @(Get-MesonProvenanceEntry @call)
            Assert-Equal 4 $entries.Count 'only installed DLLs, never the import library'
            $byFile = @{}
            foreach ($e in $entries) { $byFile[$e.file] = $e }
            Assert-Equal 'abc' $byFile['bin\z-1.dll'].source['sha256'] 'a wrap keeps its source hash'
            Assert-Equal 'gst-good' $byFile['bin\gstgood.dll'].source['name'] 'an in-tree subproject keeps its own name'
            Assert-Equal 'https://example.invalid/g' $byFile['bin\gstgood.dll'].source['url'] 'and the root source URL'
            Assert-True (Test-Path -LiteralPath (Join-Path $install 'n\zlib\LICENSE')) 'the original text is staged'
            Assert-True (Test-Path -LiteralPath (Join-Path $install 'n\ffi\LICENSE')) 'a wrap extracted elsewhere is found through meson''s record'
            Remove-Item -LiteralPath (Join-Path $src 'subprojects\zlib-1.3\LICENSE'), (Join-Path $src 'subprojects\ffi\LICENSE')
            Remove-Item -LiteralPath (Join-Path $install 'n') -Recurse
            Assert-Throws { Get-MesonProvenanceEntry @call } 'every missing notice' -MessagePattern '2 defect.*zlib.*no license or notice.*ffi.*no license or notice'
            $targets[1].defined_in = (Join-Path $root 'elsewhere\meson.build')
            Set-Content -LiteralPath (Join-Path $info 'intro-targets.json') -Value ($targets | ConvertTo-Json -Depth 4)
            Assert-Throws { Get-MesonProvenanceEntry @call } 'a tree outside subprojects' -MessagePattern 'defined outside'
        } finally { Remove-TestDir $root }
    }
}

Describe 'MSVC runtime entries' {
    It 'lists staged runtime DLLs with the install''s notice, and fails without a text or terms (mutation)' {
        $root = New-TestDir -Prefix 'msvc-provenance'
        try {
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'r\bin'), (Join-Path $root 'vs\Licenses\1031')
            $text = Join-Path $root 'vs\Licenses\1031\Redist.txt'
            $call = @{ Root = (Join-Path $root 'r'); NoticeDir = 'n'; GetVsInstallDir = { Join-Path $root 'vs' }.GetNewClosure() }
            Assert-Equal 0 @(Get-MsvcRuntimeProvenanceEntry -Root $call.Root -NoticeDir 'n' -GetVsInstallDir { throw 'a lane without the runtime must not look for Visual Studio' }).Count 'no staged runtime, no entry'
            Copy-Item -LiteralPath (Join-Path $PSHOME 'pwsh.dll') -Destination (Join-Path $root 'r\bin\vcruntime140.dll')
            Set-Content -LiteralPath (Join-Path $root 'r\bin\other.dll') -Value 'x'
            Assert-Throws { Get-MsvcRuntimeProvenanceEntry @call } 'no text' -MessagePattern 'cannot ship with its notice'
            Set-Content -LiteralPath $text -Value 'no link here'
            Assert-Throws { Get-MsvcRuntimeProvenanceEntry @call } 'no terms' -MessagePattern 'names no redistribution terms'
            Set-Content -LiteralPath $text -Value "Distributable Code`nsee https://example.invalid/redist.lic"
            $entries = @(Get-MsvcRuntimeProvenanceEntry @call)
            Assert-Equal 1 $entries.Count 'only the runtime, not another DLL in bin'
            Assert-Equal 'bin\vcruntime140.dll' $entries[0].file 'the staged path'
            Assert-Equal 'https://example.invalid/redist.lic' $entries[0].source['url'] 'the terms the notice names'
            Assert-True (Test-Path -LiteralPath (Join-Path $root 'r\n\msvc-runtime\Redist.txt')) 'the original text is staged'
        } finally { Remove-TestDir $root }
    }
}

Describe 'Wiring' {
    It 'records the staged MSVC runtime in the GStreamer manifest' {
        Assert-TestScriptContains -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -Literal 'Get-MsvcRuntimeProvenanceEntry -Root $resolvedInstallDir'
    }

    It 'lists possibly empty findings through the pipeline, as strict mode throws on .Name of an empty list' {
        $smoke = Get-TestRepoText 'windows\scripts\build\Test-Container.ps1'
        Assert-False ($smoke -match '-ErrorAction SilentlyContinue\)\.(Name|FullName)') 'a healthy empty result would fail the smoke gate'
        Set-StrictMode -Version Latest
        Assert-Equal 0 @(@() | ForEach-Object Name).Count 'the pipeline form stays empty'
        Assert-Throws { $null = @().Name } 'the property form throws' -MessagePattern 'Name'
    }

    It 'writes the manifest before GStreamer cleanup, and pins libvpx through the driver' {
        $gst = Get-TestRepoText 'windows\scripts\build\Build-GstreamerFromSource.ps1'
        Assert-True ($gst.IndexOf('Assert-GstInstalledPlugins -resolvedInstallDir') -lt $gst.IndexOf('Complete-GstBuild -gstSrcDir')) 'the gate that writes it runs before cleanup'
        Assert-TestScriptContains -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -Literal '$libffi.Url = Get-GstLibffiArchiveUrl -Version $libffiVer', '$libffi.Sha256 = '''''
        Assert-TestScriptContains -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -Literal '-Dvpx:default_library=static', '-Dvpx:cpp_std=c++17', '"diff_files = $diffName"'
        Assert-TestScriptContains -ScriptPath 'windows\scripts\patches\gstreamer\002-libvpx-clangcl-simd-flags.patch' -Literal "+if tgt_cc == 'msvs' and c.get_id() != 'clang-cl'"
        Assert-TestScriptContains -ScriptPath 'windows\Dockerfile.media-merge-builder' -Literal 'ARG LIBVPX_MESON_COMMIT', 'ARG LIBVPX_MESON_SHA256', 'WindowsNativeProvenance.Common.psm1'
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\tool-pins.env')
        Assert-Match '^[0-9a-f]{40}$' $pins['LIBVPX_MESON_COMMIT'] 'commit pin'
        foreach ($key in 'LIBVPX_MESON_SHA256', 'DIRECTML_NUPKG_SHA256') { Assert-Match '^[0-9a-f]{64}$' $pins[$key] $key }
        $vpx = @(Get-RequiredGstPlugin -Arch amd64 | Where-Object { $_.Name -eq 'vpx' })
        Assert-Equal 'gst-plugins-good:vpx' $vpx[0].MesonOption 'the contract requires the plugin'
    }

    It 'the CUDA stage stages distributable DLLs with a manifest, drops nvfatbin and refuses an unlisted DLL' {
        $repo = Get-RepoRoot
        $dir = New-TestDir -Prefix 'cuda-stage'
        try {
            Copy-Item -LiteralPath (Join-Path $repo 'windows\scripts\build\Copy-CudaRuntime.ps1'), (Join-Path $repo 'windows\scripts\modules\WindowsNativeProvenance.Common.psm1') -Destination $dir
            $cuda = Join-Path $dir 'CUDA\v13.4'
            $cudnn = Join-Path $dir 'CUDNN\v9.27'
            Write-TestFileTree -Root $dir -Files @{
                'CUDA\v13.4\bin\x64\cudart64_13.dll' = 'rt'; 'CUDA\v13.4\bin\x64\nvfatbin_130_0.dll' = 'fat'; 'CUDA\v13.4\bin\x64\cusparse64_13.dll' = 'sparse'; 'CUDA\v13.4\LICENSE' = 'eula'
                'CUDNN\v9.27\bin\x64\cudnn64_9.dll' = 'dnn'; 'CUDNN\v9.27\LICENSE' = 'dnn eula'
            }
            $stage = Join-Path $dir 'out'
            $run = {
                $text = & pwsh -NoProfile -Command "`$env:CUDA_ROOT='$cuda'; `$env:CUDNN_ROOT='$cudnn'; `$env:WINDOWS_TARGET_ARCH='amd64'; & '$dir\Copy-CudaRuntime.ps1' -StageRoot '$stage'; exit `$LASTEXITCODE" 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
            }
            $ok = & $run
            Assert-Equal 0 $ok.Code "the stage passes: $($ok.Text)"
            Assert-TestPathState -Root $stage -Present 'bin\cudart64_13.dll', 'notices\cudnn\LICENSE' -Absent 'bin\nvfatbin_130_0.dll', 'bin\cusparse64_13.dll'
            Assert-Equal 0 @(Get-NativeProvenanceFinding -Path (Join-Path $stage 'provenance.json') -Root $stage -RequiredFile 'bin\cudart64_13.dll', 'bin\cudnn64_9.dll').Count 'the manifest holds'
            Set-Content -LiteralPath (Join-Path $cuda 'bin\x64\newthing64_1.dll') -Value 'x'
            $refused = & $run
            Assert-True ($refused.Code -ne 0 -and $refused.Text -match 'not on the distributable list') "a new DLL name fails the stage: $($refused.Text)"
        } finally { Remove-TestDir $dir }
    }

    It 'enables Media Foundation only for the amd64 payload' {
        Assert-Match "(?m)^RUN if \(\`$env:WINDOWS_TARGET_ARCH -eq 'amd64'\) \{ .*Enable-WindowsOptionalFeature .*ServerMediaFoundation" (Get-TestRepoText 'windows\Dockerfile') 'amd64 only, and -ErrorAction Stop keeps a failure fatal'
    }
}

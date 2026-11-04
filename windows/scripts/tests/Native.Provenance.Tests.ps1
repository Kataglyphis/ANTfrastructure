#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The native-DLL manifest over synthetic trees and meson records; real DLL origins and a license's legal fit are not covered.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNativeProvenance.Common.psm1') -Force -DisableNameChecking

function New-ProvenanceTree {
    $root = New-TestDir -Prefix 'native-provenance'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin'), (Join-Path $root 'n')
    [IO.File]::WriteAllText((Join-Path $root 'bin\a.dll'), 'bytes-a')
    [IO.File]::WriteAllText((Join-Path $root 'n\LICENSE'), 'text-a')
    $entry = New-NativeProvenanceEntry -Root $root -File 'bin\a.dll' -Notice 'n\LICENSE' -Source @{ Name = 'a'; Version = '1'; Url = 'https://example.invalid/a'; Sha256 = '' }
    $manifest = Join-Path $root 'm.json'
    Write-NativeProvenanceManifest -Path $manifest -Owner 'test' -Entry @($entry)
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
            Assert-Throws { Write-NativeProvenanceManifest -Path (Join-Path $t.Root 'e.json') -Owner 'x' -Entry @() } -MessagePattern 'empty'
        } finally { Remove-TestDir $t.Root }
    }

    It 'walks the import closure, stops at unstaged names and reports only unlisted DLLs' {
        $t = New-ProvenanceTree
        try {
            foreach ($name in 'b.dll', 'c.dll') { [IO.File]::WriteAllText((Join-Path $t.Root "bin\$name"), $name) }
            $imports = @{ 'plugin.dll' = @('a.dll', 'KERNEL32.dll'); 'a.dll' = @('b.dll'); 'b.dll' = @('c.dll', 'a.dll'); 'c.dll' = @() }
            $get = { param($path) $imports[(Split-Path -Leaf $path)] }.GetNewClosure()
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
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $src 'subprojects\zlib-1.3'), (Join-Path $src 'subprojects\gst-good'), (Join-Path $install 'bin'), $info
            Set-Content -LiteralPath (Join-Path $src 'subprojects\zlib.wrap') -Value "[wrap-file]`ndirectory = zlib-1.3`nsource_url = https://example.invalid/z.tar.xz`nsource_hash = abc`n`n[provide]`ndependency_names = zlib"
            foreach ($file in 'src\LICENSE', 'src\subprojects\zlib-1.3\LICENSE', 'src\subprojects\gst-good\COPYING') { Set-Content -LiteralPath (Join-Path $root $file) -Value $file }
            foreach ($dll in 'z-1.dll', 'gstgood.dll', 'gst.dll') { Set-Content -LiteralPath (Join-Path $install "bin\$dll") -Value $dll }
            $targets = @(
                @{ installed = $true; subproject = 'zlib'; install_filename = @((Join-Path $install 'bin\z-1.dll'), (Join-Path $install 'lib\z.lib')) }
                @{ installed = $true; subproject = 'gst-good'; install_filename = @(Join-Path $install 'bin\gstgood.dll') }
                @{ installed = $true; subproject = $null; install_filename = @(Join-Path $install 'bin\gst.dll') }
                @{ installed = $false; subproject = 'zlib'; install_filename = @() }
            )
            Set-Content -LiteralPath (Join-Path $info 'intro-targets.json') -Value ($targets | ConvertTo-Json -Depth 4)
            Set-Content -LiteralPath (Join-Path $info 'intro-projectinfo.json') -Value (@{ version = '1.0'; subprojects = @(@{ name = 'zlib'; version = '1.3' }, @{ name = 'gst-good'; version = '1.0' }) } | ConvertTo-Json -Depth 4)
            $wrap = Get-MesonWrapInventory -SubprojectDir (Join-Path $src 'subprojects')
            Assert-Equal 'zlib-1.3' $wrap['zlib'].Directory 'the wrap names its directory'
            $call = @{ BuildDir = (Join-Path $root 'b'); SourceDir = $src; Root = $install; NoticeDir = 'n'; Wrap = $wrap; RootSource = @{ Name = 'gst'; Version = '1.0'; Url = 'https://example.invalid/g' } }
            $entries = @(Get-MesonProvenanceEntry @call)
            Assert-Equal 3 $entries.Count 'only installed DLLs, never the import library'
            $byFile = @{}
            foreach ($e in $entries) { $byFile[$e.file] = $e }
            Assert-Equal 'abc' $byFile['bin\z-1.dll'].source['sha256'] 'a wrap keeps its source hash'
            Assert-Equal 'gst-good' $byFile['bin\gstgood.dll'].source['name'] 'an in-tree subproject keeps its own name'
            Assert-Equal 'https://example.invalid/g' $byFile['bin\gstgood.dll'].source['url'] 'and the root source URL'
            Assert-True (Test-Path -LiteralPath (Join-Path $install 'n\zlib\LICENSE')) 'the original text is staged'
            Remove-Item -LiteralPath (Join-Path $src 'subprojects\zlib-1.3\LICENSE')
            Remove-Item -LiteralPath (Join-Path $install 'n') -Recurse
            Assert-Throws { Get-MesonProvenanceEntry @call } -MessagePattern 'has no license or notice file'
        } finally { Remove-TestDir $root }
    }
}

Describe 'Wiring' {
    It 'writes the manifest before GStreamer cleanup, and pins libvpx through the driver' {
        $root = Get-RepoRoot
        $gst = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\build\Build-GstreamerFromSource.ps1') -Raw
        Assert-True ($gst.IndexOf('Assert-GstInstalledPlugins -resolvedInstallDir') -lt $gst.IndexOf('Complete-GstBuild -gstSrcDir')) 'the gate that writes it runs before cleanup'
        Assert-True ($gst -match "-Dvpx:default_library=static") 'the port refuses a shared Windows build'
        Assert-True ($gst.Contains('"diff_files = $diffName"')) 'the wrap applies the clang-cl SIMD patch'
        $vpxPatch = Get-Content -LiteralPath (Join-Path $root 'windows\scripts\patches\gstreamer\002-libvpx-clangcl-simd-flags.patch') -Raw
        Assert-True ($vpxPatch.Contains("+if tgt_cc == 'msvs' and c.get_id() != 'clang-cl'")) 'clang-cl takes the per-file flag table'
        $merge = Get-Content -LiteralPath (Join-Path $root 'windows\Dockerfile.media-merge-builder') -Raw
        foreach ($needle in 'ARG LIBVPX_MESON_COMMIT', 'ARG LIBVPX_MESON_SHA256', 'WindowsNativeProvenance.Common.psm1') { Assert-True ($merge.Contains($needle)) "the merge stage carries $needle" }
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path $root 'linux\scripts\01-core\tool-pins.env')
        Assert-True ($pins['LIBVPX_MESON_COMMIT'] -match '^[0-9a-f]{40}$') 'commit pin'
        Assert-True ($pins['LIBVPX_MESON_SHA256'] -match '^[0-9a-f]{64}$') 'hash pin'
        Assert-True ($pins['DIRECTML_NUPKG_SHA256'] -match '^[0-9a-f]{64}$') 'nuget pin'
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
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $cuda 'bin\x64'), (Join-Path $cudnn 'bin\x64')
            foreach ($file in 'bin\x64\cudart64_13.dll', 'bin\x64\nvfatbin_130_0.dll', 'bin\x64\cusparse64_13.dll', 'LICENSE') { Set-Content -LiteralPath (Join-Path $cuda $file) -Value $file }
            foreach ($file in 'bin\x64\cudnn64_9.dll', 'LICENSE') { Set-Content -LiteralPath (Join-Path $cudnn $file) -Value "dnn $file" }
            $stage = Join-Path $dir 'out'
            $run = {
                $text = & pwsh -NoProfile -Command "`$env:CUDA_ROOT='$cuda'; `$env:CUDNN_ROOT='$cudnn'; `$env:WINDOWS_TARGET_ARCH='amd64'; & '$dir\Copy-CudaRuntime.ps1' -StageRoot '$stage'; exit `$LASTEXITCODE" 2>&1 | Out-String
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
            }
            $ok = & $run
            Assert-Equal 0 $ok.Code "the stage passes: $($ok.Text)"
            Assert-True (Test-Path -LiteralPath (Join-Path $stage 'bin\cudart64_13.dll')) 'a listed DLL is staged'
            Assert-False (Test-Path -LiteralPath (Join-Path $stage 'bin\nvfatbin_130_0.dll')) 'nvfatbin is not distributable'
            Assert-False (Test-Path -LiteralPath (Join-Path $stage 'bin\cusparse64_13.dll')) 'the trimmed set stays out'
            Assert-True (Test-Path -LiteralPath (Join-Path $stage 'notices\cudnn\LICENSE')) 'the original license is staged'
            Assert-Equal 0 @(Get-NativeProvenanceFinding -Path (Join-Path $stage 'provenance.json') -Root $stage -RequiredFile 'bin\cudart64_13.dll', 'bin\cudnn64_9.dll').Count 'the manifest holds'
            Set-Content -LiteralPath (Join-Path $cuda 'bin\x64\newthing64_1.dll') -Value 'x'
            $refused = & $run
            Assert-True ($refused.Code -ne 0 -and $refused.Text -match 'not on the distributable list') "a new DLL name fails the stage: $($refused.Text)"
        } finally { Remove-TestDir $dir }
    }

    It 'enables Media Foundation only for the amd64 payload' {
        $text = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Dockerfile') -Raw
        Assert-True ($text -match "(?m)^RUN if \(\`$env:WINDOWS_TARGET_ARCH -eq 'amd64'\) \{ .*Enable-WindowsOptionalFeature .*ServerMediaFoundation") 'amd64 only, and -ErrorAction Stop keeps a failure fatal'
    }
}

#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# WebRTC on Windows broke twice with every gate green: libffi linked a zeroed type table, and OpenSSL 4 read an empty DTLS BIO as EOF.

# New-OrtTestPe's export table retargeted at libffi's three descriptors; -Bss leaves them past the raw data, an uninitialized tail.
function New-LibffiTestPe {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Type = @{}, [switch]$Bss)
    $names = @('ffi_type_pointer', 'ffi_type_sint32', 'ffi_type_void')
    New-OrtTestPe -Path $Path -Export $names
    $pe = [System.IO.File]::ReadAllBytes($Path)
    # Its one section maps RVA 0x1000 to file offset 0x200, in a file padded to 2048 bytes.
    $toFile = { param($rva) [int]($rva - 0x1000 + 0x200) }
    $exportEnd = [BitConverter]::ToUInt32($pe, 0x58 + 112) + [BitConverter]::ToUInt32($pe, 0x58 + 116)
    $dataRva = $exportEnd + (8 - $exportEnd % 8) % 8
    $functions = & $toFile ([BitConverter]::ToUInt32($pe, (& $toFile ([BitConverter]::ToUInt32($pe, 0x58 + 112))) + 28))
    for ($i = 0; $i -lt $names.Count; $i++) {
        [BitConverter]::GetBytes([uint32]($dataRva + 24 * $i)).CopyTo($pe, $functions + 4 * $i)
        $t = if ($Type.ContainsKey($names[$i])) { $Type[$names[$i]] } else { @(0, 0, 0) }
        $at = & $toFile ($dataRva + 24 * $i)
        [BitConverter]::GetBytes([uint64]$t[0]).CopyTo($pe, $at)
        [BitConverter]::GetBytes([uint16]$t[1]).CopyTo($pe, $at + 8)
        [BitConverter]::GetBytes([uint16]$t[2]).CopyTo($pe, $at + 10)
    }
    # The virtual size covers the descriptors; under -Bss the raw size stops before them, though the bytes are in the file.
    [BitConverter]::GetBytes([uint32]($dataRva + 72 - 0x1000)).CopyTo($pe, 0x148 + 8)
    [BitConverter]::GetBytes([uint32]($dataRva - 0x1000 + $(if ($Bss) { 0 } else { 72 }))).CopyTo($pe, 0x148 + 16)
    [System.IO.File]::WriteAllBytes($Path, $pe)
}

$script:goodTypes = @{ ffi_type_sint32 = @(4, 4, 10); ffi_type_pointer = @(8, 8, 14); ffi_type_void = @(1, 1, 0) }

Describe 'Assert-LibffiTypeExport (the shipped-bytes guard for ffi-7.dll)' {

    It 'passes the descriptors types.c defines' {
        Invoke-InTestDir { param($dir)
            New-LibffiTestPe -Path (Join-Path $dir 'ffi-7.dll') -Type $script:goodTypes
            Assert-Match 'sint32 4/4/10' (Assert-LibffiTypeExport -Path (Join-Path $dir 'ffi-7.dll'))
        }
    }

    It 'fails the zeroed table a /FORCE:MULTIPLE link shipped' {
        Invoke-InTestDir { param($dir)
            New-LibffiTestPe -Path (Join-Path $dir 'ffi-7.dll')
            Assert-Throws { Assert-LibffiTypeExport -Path (Join-Path $dir 'ffi-7.dll') } -MessagePattern 'ffi_type_sint32 is size=0 align=0 type=0'
        }
    }

    It 'reads a .bss tail as zeros, the way the loader maps it, and fails it' {
        Invoke-InTestDir { param($dir)
            New-LibffiTestPe -Path (Join-Path $dir 'ffi-7.dll') -Type $script:goodTypes -Bss
            Assert-Throws { Assert-LibffiTypeExport -Path (Join-Path $dir 'ffi-7.dll') } -MessagePattern 'ffi_type_void is size=0'
        }
    }

    It 'fails one wrong field, not only an all-zero table' {
        Invoke-InTestDir { param($dir)
            $types = $script:goodTypes.Clone()
            $types['ffi_type_sint32'] = @(4, 4, 9)
            New-LibffiTestPe -Path (Join-Path $dir 'ffi-7.dll') -Type $types
            Assert-Throws { Assert-LibffiTypeExport -Path (Join-Path $dir 'ffi-7.dll') } -MessagePattern 'ffi_type_sint32 is size=4 align=4 type=9'
        }
    }

    It 'names a missing export and refuses a non-PE file' {
        Invoke-InTestDir { param($dir)
            New-LibffiTestPe -Path (Join-Path $dir 'ffi-7.dll') -Type $script:goodTypes
            Assert-Throws { Read-PeExportData -Path (Join-Path $dir 'ffi-7.dll') -Name 'ffi_type_double' } -MessagePattern 'does not export ffi_type_double'
            Set-Content -Path (Join-Path $dir 'not-pe.dll') -Value 'text'
            Assert-Throws { Read-PeExportData -Path (Join-Path $dir 'not-pe.dll') -Name 'x' } -MessagePattern 'not a PE image'
        }
    }
}

Describe 'ConvertTo-GstDtlsRetryRead (upstream 17d22abe89 for OpenSSL 4)' {

    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -FunctionName 'ConvertTo-GstDtlsRetryRead')
    # bio_method_read as GStreamer 1.29.2 ships it, and the same lines after the upstream commit.
    $before = "  if (!priv->bio_buffer) {`n    GST_LOG_OBJECT (self, `"BIO: EOF`");`n    return 0;`n  }`n"
    $after = "  if (!priv->bio_buffer) {`n    GST_LOG_OBJECT (self, `"BIO: no data available, retry later`");`n    BIO_set_retry_read (bio);`n    return -1;`n  }`n"

    It 'turns the EOF return into upstream''s retry, byte for byte' {
        Assert-Equal $after (ConvertTo-GstDtlsRetryRead -Text $before)
    }

    It 'keeps CRLF sources CRLF' {
        Assert-Equal ($after -replace "`n", "`r`n") (ConvertTo-GstDtlsRetryRead -Text ($before -replace "`n", "`r`n"))
    }

    It 'leaves the fixed text and the other BIO: EOF messages alone' {
        Assert-Equal $after (ConvertTo-GstDtlsRetryRead -Text $after)
        $reset = "      GST_LOG_OBJECT (self, `"BIO: EOF reset`");`n      return 1;`n"
        Assert-Equal $reset (ConvertTo-GstDtlsRetryRead -Text $reset)
    }
}

Describe 'Get-GstRustCargoPlan' {

    $contract = @(Get-RequiredGstPlugin -Arch 'amd64')

    It 'builds exactly the contract''s cargo packages, locked, on amd64' {
        $plan = Get-GstRustCargoPlan -Plugin $contract -Arch 'amd64' -TargetDir 'C:\t' -PkgConfigDir 'C:\p\lib\pkgconfig' -Jobs 8
        $joined = $plan.Args -join ' '
        Assert-Match '^build --release --locked --target-dir C:\\t ' $joined
        Assert-Match '-p gst-plugin-webrtc -p gst-plugin-rtp' $joined
        Assert-Match '--jobs 8$' $joined
        Assert-False ($joined -match '--target ') 'a native build names no target triple'
        Assert-Equal 'C:\p\lib\pkgconfig' $plan.Env['PKG_CONFIG_PATH']
        Assert-Equal 1 $plan.Env.Count 'amd64 needs no cross environment'
        Assert-Equal 'C:\t\release\gstrswebrtc.dll,C:\t\release\gstrsrtp.dll' (@($plan.Dlls | ForEach-Object { $_.Path }) -join ',')
    }

    It 'cross-builds for aarch64-pc-windows-msvc with target compilers and pkg-config allowed to cross' {
        $plan = Get-GstRustCargoPlan -Plugin @(Get-RequiredGstPlugin -Arch 'arm64') -Arch 'arm64' -TargetDir 'C:\t' -PkgConfigDir 'C:\p'
        Assert-Match '--target aarch64-pc-windows-msvc' ($plan.Args -join ' ')
        Assert-Equal '1' $plan.Env['PKG_CONFIG_ALLOW_CROSS']
        Assert-Equal 'lld-link' $plan.Env['CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER']
        Assert-Equal 'clang-cl' $plan.Env['CC_aarch64_pc_windows_msvc']
        Assert-Equal '--target=aarch64-pc-windows-msvc' $plan.Env['CFLAGS_aarch64_pc_windows_msvc']
        Assert-Equal 'C:\t\aarch64-pc-windows-msvc\release\gstrswebrtc.dll' @($plan.Dlls)[0].Path
    }

    It 'refuses a contract without cargo entries, so the step cannot pass by building nothing' {
        $cOnly = @($contract | Where-Object { $_.Detection -ne 'cargo' })
        Assert-Throws { Get-GstRustCargoPlan -Plugin $cOnly -TargetDir 'C:\t' -PkgConfigDir 'C:\p' } -MessagePattern 'nothing to build'
    }
}

Describe 'Get-GstRustSourceMirrorConfig (gitlab.freedesktop.org git sources go to GitHub)' {

    # Three lock entries in upstream's shape: two from one gitlab source, one from GitHub.
    $lock = @(
        '[[package]]', 'name = "gstreamer"', 'source = "git+https://gitlab.freedesktop.org/gstreamer/gstreamer-rs?branch=main#d523456b641b6258889f30f627cf0825eda7759d"', '',
        '[[package]]', 'name = "gstreamer-sys"', 'source = "git+https://gitlab.freedesktop.org/gstreamer/gstreamer-rs?branch=main#d523456b641b6258889f30f627cf0825eda7759d"', '',
        '[[package]]', 'name = "glib"', 'source = "git+https://github.com/gtk-rs/gtk-rs-core?branch=main#7e58f9f00177227296cfb8a5c2892157e7c8767b"'
    ) -join "`n"

    It 'replaces each gitlab source once, with the same branch, by the GStreamer mirror' {
        $toml = Get-GstRustSourceMirrorConfig -CargoLock $lock
        Assert-Equal 1 ([regex]::Matches($toml, 'replace-with').Count) 'one replacement for the one gitlab source spec'
        Assert-Match '(?m)^\[source\.gitlab-gstreamer-rs-branch-main\]\ngit = "https://gitlab\.freedesktop\.org/gstreamer/gstreamer-rs"\nbranch = "main"\nreplace-with = "github-gstreamer-rs-branch-main"' $toml
        Assert-Match '(?m)^\[source\.github-gstreamer-rs-branch-main\]\ngit = "https://github\.com/GStreamer/gstreamer-rs"\nbranch = "main"' $toml
        Assert-False ($toml -match 'gtk-rs-core') 'a GitHub source needs no replacement'
    }

    It 'keeps a tag or rev spec, so --locked still finds the pinned commit' {
        $tagged = 'source = "git+https://gitlab.freedesktop.org/gstreamer/gstreamer-rs?tag=0.25.1#abc"'
        Assert-Match '(?m)^tag = "0\.25\.1"$' (Get-GstRustSourceMirrorConfig -CargoLock $tagged)
    }

    It 'emits nothing for a lock without gitlab git sources' {
        Assert-Equal '' (Get-GstRustSourceMirrorConfig -CargoLock 'source = "registry+https://github.com/rust-lang/crates.io-index"')
    }
}

Describe 'Build-GstreamerFromSource.ps1: the WebRTC wiring stays in place' {

    $text = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-GstreamerFromSource.ps1')

    It 'links without /FORCE:MULTIPLE and compiles C with -fcommon, the build machine included' {
        Assert-False ($text -match "'/FORCE:MULTIPLE'") '/FORCE:MULTIPLE turned the libffi duplicate symbols into a silently zeroed DLL'
        Assert-Match '-Wno-undef -fcommon' $text
        Assert-Match "(?m)^c_args = \['-fcommon'\]$" $text
    }

    It 'pins meson to PY_MESON_VERSION on both pip paths' {
        Assert-False ($text -match 'pip install meson >') 'the first install floated'
        Assert-False ($text -match '--no-deps meson >>') 'the launcher reinstall floated'
        Assert-Match 'pip install meson==\$mesonPin' $text
        Assert-Match '--no-deps meson==\$mesonPin' $text
    }

    It 'fails the build when the DTLS patch neither applies nor is upstream' {
        Assert-Match "ReadAllText\(\`$dtlsConn\)\.Contains\('BIO: no data available, retry later'\)" $text
        Assert-Match 'neither applied nor is upstream' $text
    }

    It 'runs the libffi guard, the OpenSSL staging and the cargo step on both lanes, before the plugin gate' {
        $install = $text.IndexOf("Switch-BuildPhase '8. install'")
        $ssl = $text.IndexOf('$sslRuntimeRoot = if ($script:GstCross)')
        $rs = $text.IndexOf("Switch-BuildPhase '8b. gst-plugins-rs (cargo)'")
        $verify = $text.IndexOf("Switch-BuildPhase '9. verify (plugin + pc gates)'")
        $ffi = $text.IndexOf('Assert-LibffiTypeExport -Path')
        $gate = $text.IndexOf('foreach ($plugin in @(Get-RequiredGstPlugin -Arch $script:GstTargetArch))')
        Assert-True ($install -ge 0 -and $ssl -gt $install -and $rs -gt $ssl -and $verify -gt $rs -and $ffi -gt $verify -and $gate -gt $ffi) 'install, OpenSSL, cargo, verify, libffi guard, plugin gate: in that order'
        Assert-False ($text -match 'if \(\$script:GstCross\) \{\s*\$sslRuntimeRoot') 'the OpenSSL staging must not be arm64-only again'
    }

    It 'hands cargo the GitHub mirror config built from the checkout''s own Cargo.lock' {
        Assert-Match "Get-GstRustSourceMirrorConfig -CargoLock \(\[System\.IO\.File\]::ReadAllText\(\(Join-Path \`$rsSrcDir 'Cargo\.lock'\)\)\)" $text
        Assert-Match "\`$rsArgs = @\(\`$rsPlan\.Args\) \+ @\('--config', \`$rsSources\)" $text
        Assert-Match '& cargo @rsArgs' $text
    }

    It 'finds each plugin DLL by its exact name, never a wildcard that also matches gstrswebrtc.dll' {
        Assert-False ($text -match 'gst\*\$\(\$plugin\.Name\)\*\.dll') 'gst*webrtc*.dll would pick gstrswebrtc.dll for the webrtc entry'
        Assert-Match 'Join-Path \$gstPluginDir "gst\$\(\$plugin\.Name\)\.dll"' $text
    }
}

# A failing smoke-gate consumer's logs, verbatim: EOS after 60 frames at 30/s, then the signaller's teardown error.
$script:teardownOut = @'
Setting pipeline to PAUSED ...
Pipeline is live and does not need PREROLL ...
Setting pipeline to PLAYING ...
Redistribute latency...
Got EOS from element "pipeline0".
EOS received - stopping pipeline...
Execution ended after 0:00:02.169112200
Setting pipeline to NULL ...
Freeing pipeline ...
'@
$script:teardownErr = @'
ERROR: from element /GstPipeline:pipeline0/GstWebRTCSrc:webrtcsrc0: GStreamer encountered a general stream error.
Additional debug info:
net\webrtc\src\webrtcsrc\imp.rs(1736): gstrswebrtc::webrtcsrc::imp::BaseWebRTCSrc::connect_signaller::{{closure}}::{{closure}} (): /GstPipeline:pipeline0/GstWebRTCSrc:webrtcsrc0:
Signalling error: Error: send failed because receiver is gone
'@

Describe 'Get-GstLoopbackTeardownError (BACKLOG CON68: the frames arrived, the exit code says 1)' {

    It 'names the teardown error when EOS came after the frames and webrtcsrc failed alone' {
        $lines = @(Get-GstLoopbackTeardownError -ConsumerOut $script:teardownOut -ConsumerErr $script:teardownErr -Frames 60)
        Assert-True ($lines.Count -gt 0) 'the smoke gate passes this run and shows the lines'
        Assert-Match 'receiver is gone' ($lines -join ' ')
    }

    It 'leaves a run without EOS failed: the signaller died before the frames' {
        $out = $script:teardownOut -replace '(?m)^(Got EOS|EOS received).*\r?\n', ''
        Assert-Equal 0 @(Get-GstLoopbackTeardownError -ConsumerOut $out -ConsumerErr $script:teardownErr -Frames 60).Count
    }

    It 'leaves a run failed when another element errored too' {
        $err = $script:teardownErr + "`nERROR: from element /GstPipeline:pipeline0/GstDtlsDec:dtlsdec0: handshake failed"
        Assert-Equal 0 @(Get-GstLoopbackTeardownError -ConsumerOut $script:teardownOut -ConsumerErr $err -Frames 60).Count
    }

    It 'leaves a run failed whose EOS came before 60 frames could flow at 30/s' {
        $out = $script:teardownOut -replace '0:00:02\.169112200', '0:00:00.400000000'
        Assert-Equal 0 @(Get-GstLoopbackTeardownError -ConsumerOut $out -ConsumerErr $script:teardownErr -Frames 60).Count
    }

    It 'leaves any other signalling error failed' {
        $err = $script:teardownErr -replace 'send failed because receiver is gone', 'Connection refused'
        Assert-Equal 0 @(Get-GstLoopbackTeardownError -ConsumerOut $script:teardownOut -ConsumerErr $err -Frames 60).Count
    }
}

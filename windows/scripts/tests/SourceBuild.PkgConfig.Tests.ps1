#requires -Version 7.0
# Tests for the mandatory-GStreamer-plugin contract and the pkg-config plumbing
# that makes it satisfiable.
#
# The defect these guard against shipped for months: gst-plugins-bad resolves its
# opencv/onnx integrations through pkg-config ONLY, neither library installs a .pc
# file, the meson features were left at `auto` (= skip silently), and the
# healthcheck then printed [PASS] for plugins that did not exist. Nothing in the
# build was ever red. The contract is now data (Get-RequiredGstPlugin) consumed by
# three enforcement points, so the thing most worth testing is that the data and
# the emitter stay correct and mutually consistent.

Describe 'Get-RequiredGstPlugin (the contract)' {

    It 'names the four integrations the media stack is built around' {
        $names = @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
        Assert-Equal 4 $names.Count 'the required set is libav, opencv, onnx, tflite'
        foreach ($expected in 'libav', 'opencv', 'onnx', 'tflite') {
            Assert-True ($names -contains $expected) "'$expected' must be mandatory"
        }
    }

    It 'records HOW each dependency is detected, because it is not uniform' {
        # opencv/onnx/libav go through pkg-config; tflite probes the compiler
        # (cc.find_library + cc.has_header) and consults no .pc at all. Checking
        # the wrong way would pass vacuously or demand a file nothing reads.
        $byName = @{}
        foreach ($p in @(Get-RequiredGstPlugin)) { $byName[$p.Name] = $p }
        foreach ($n in 'libav', 'opencv', 'onnx') {
            Assert-Equal 'pkg-config' $byName[$n].Detection "$n is resolved via pkg-config"
        }
        Assert-Equal 'compiler' $byName['tflite'].Detection 'tflite is resolved by compiler probes'
        Assert-Equal 0 $byName['tflite'].NeedsPc.Count 'tflite must not claim pkg-config modules'
    }

    It 'pins the tflite probe details upstream actually uses' {
        # The header is the PRE-RENAME TensorFlow path while LiteRT ships the
        # post-rename tflite/ layout — the mismatch that kept this plugin out of
        # the image. If upstream ever moves to tflite/, this test is the place
        # that should fail first.
        $tflite = @(Get-RequiredGstPlugin | Where-Object { $_.Name -eq 'tflite' })[0]
        Assert-Equal 'tensorflow/lite/c/c_api.h' $tflite.NeedsHeader 'gst probes the old TensorFlow header path'
        Assert-True ($tflite.NeedsLib -contains 'tensorflowlite_c') 'primary cc.find_library name'
        Assert-True ($tflite.NeedsLib -contains 'tensorflow-lite') 'fallback cc.find_library name'
    }

    It 'does NOT require tensorfilter (an NNStreamer element this repo never builds)' {
        # It appeared in the old probe lists only because the lying healthcheck
        # "found" it. Requiring it would fail every build forever.
        $names = @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
        Assert-False ($names -contains 'tensorfilter') 'tensorfilter is not a GStreamer plugin'
    }

    It 'carries a resolvable dependency spec and a rationale for every entry' {
        foreach ($p in @(Get-RequiredGstPlugin)) {
            Assert-True ([bool]$p.Why) "$($p.Name) must say WHY it is mandatory"
            Assert-True ([bool]$p.Provides) "$($p.Name) must say what it provides"
            # Every entry must be checkable SOMEHOW — either it names pkg-config
            # modules or it names the header/library the compiler probe needs.
            # An entry with neither would sail through the pre-flight unchecked.
            $checkable = ($p.NeedsPc.Count -gt 0) -or ([bool]$p.NeedsHeader -and $p.NeedsLib.Count -gt 0)
            Assert-True $checkable "$($p.Name) must declare either pkg-config modules or a header+library probe"
        }
    }

    It 'is arch-aware and, since #115, demands the SAME four entries on both lanes' {
        # The ONLY arch-conditional logic this module carries had ZERO test
        # coverage until 2026-08-24. The mechanism (UnavailableOn filtering)
        # stays tested even while its current key set is empty: #115 restored
        # tflite on arm64 (plain LiteRT cross-builds; the plugin is enabled
        # presence-driven), so a re-appearing arm64 key -- someone re-dropping
        # the plugin "temporarily" -- must fail HERE first.
        $amd = @(Get-RequiredGstPlugin -Arch 'amd64' | ForEach-Object { $_.Name })
        $arm = @(Get-RequiredGstPlugin -Arch 'arm64' | ForEach-Object { $_.Name })
        Assert-Equal 4 $amd.Count 'amd64 keeps the full contract'
        Assert-Equal 4 $arm.Count 'arm64 demands the full contract again since #115 (tflite restored)'
        foreach ($n in 'libav', 'opencv', 'onnx', 'tflite') {
            Assert-True ($arm -contains $n) "'$n' must be mandatory on arm64"
        }
        # The bare call must equal the amd64 view when WINDOWS_TARGET_ARCH is
        # unset -- the compatibility guarantee the module header promises.
        if (-not $env:WINDOWS_TARGET_ARCH) {
            $bare = @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
            Assert-Equal ($amd -join ',') ($bare -join ',') 'bare call defaults to the amd64 contract'
        }
    }

    It 'explains every UnavailableOn entry and names no arch outside the supported set' {
        $supported = @(Get-SupportedWindowsTargetArches)
        foreach ($p in @(Get-RequiredGstPlugin -Arch 'amd64')) {
            foreach ($k in $p.UnavailableOn.Keys) {
                Assert-True ($supported -contains $k) "$($p.Name): UnavailableOn key '$k' must be a supported arch"
                Assert-True ([bool]$p.UnavailableOn[$k]) "$($p.Name): UnavailableOn['$k'] must carry a reason"
            }
        }
    }

    It 'maps each plugin to the pkg-config name its upstream meson actually looks up' {
        # Verified against gstreamer 1.29.2 sources: gst-plugins-bad resolves
        # dependency('opencv4') and dependency('libonnxruntime'); gst-libav
        # resolves the four libav* modules. A typo here means the pre-flight
        # checks for something nothing needs.
        $byName = @{}
        foreach ($p in @(Get-RequiredGstPlugin)) { $byName[$p.Name] = $p }
        Assert-True ($byName['opencv'].NeedsPc -contains 'opencv4') 'gst-plugins-bad looks up opencv4, not opencv5'
        Assert-True ($byName['onnx'].NeedsPc -contains 'libonnxruntime') 'gst-plugins-bad looks up libonnxruntime'
        foreach ($m in 'libavcodec', 'libavformat', 'libavutil', 'libavfilter') {
            Assert-True ($byName['libav'].NeedsPc -contains $m) "gst-libav needs $m"
        }
    }
}

Describe 'Write-PkgConfigFile' {

    It 'emits a resolvable .pc with forward-slashed paths' {
        Invoke-InTestDir { param($dir)
            $pcDir = Join-Path $dir 'pkgconfig'
            $libDir = Join-Path $dir 'x64\vc18\lib'
            $incDir = Join-Path $dir 'include'
            New-Item -ItemType Directory -Force -Path $libDir, $incDir | Out-Null
            $path = Write-PkgConfigFile -Name 'opencv4' -Version '5.0.0' -Description 'test' `
                -IncludeDir @($incDir) -LibDir $libDir -Library @('opencv_core500', 'opencv_imgproc500') `
                -PkgConfigDir $pcDir
            Assert-Equal (Join-Path $pcDir 'opencv4.pc') $path 'returns the written path'
            $text = Get-Content $path -Raw
            Assert-Match 'Name: opencv4' $text
            Assert-Match 'Version: 5\.0\.0' $text
            Assert-Match '-lopencv_core500' $text
            Assert-Match '-lopencv_imgproc500' $text
            # pkg-config treats a backslash as an escape: a native Windows path
            # produces flags that silently do not work.
            Assert-False ($text -match '\\') 'no backslashes may survive into the .pc'
        }
    }

    It 'creates the pkgconfig directory when it does not exist' {
        Invoke-InTestDir { param($dir)
            $pcDir = Join-Path $dir 'deep\nested\pkgconfig'
            $path = Write-PkgConfigFile -Name 'libonnxruntime' -Version '1.28.0' -Description 'test' `
                -IncludeDir @((Join-Path $dir 'include')) -LibDir (Join-Path $dir 'lib') `
                -Library @('onnxruntime') -PkgConfigDir $pcDir
            Assert-True (Test-Path $path) 'the .pc must exist'
        }
    }

    It 'emits one -I per include directory' {
        Invoke-InTestDir { param($dir)
            $path = Write-PkgConfigFile -Name 'multi' -Version '1.0' -Description 'test' `
                -IncludeDir @("$dir/a", "$dir/b", "$dir/c") -LibDir "$dir/lib" `
                -Library @('x') -PkgConfigDir $dir
            $cflags = (Get-Content $path | Where-Object { $_ -like 'Cflags:*' })
            Assert-Equal 3 ([regex]::Matches($cflags, '-I').Count) 'every include dir must be listed'
        }
    }
}

Describe 'Get-LibraryLinkName' {

    It 'derives -l names from the import libraries actually present' {
        # Hardcoding OpenCV's module list would rot on the next bump; the whole
        # point is to read the install.
        Invoke-InTestDir { param($dir)
            foreach ($n in 'opencv_core500.lib', 'opencv_imgproc500.lib', 'opencv_dnn500.lib') {
                Set-Content -Path (Join-Path $dir $n) -Value 'x' -NoNewline
            }
            $names = @(Get-LibraryLinkName -LibDir $dir)
            Assert-Equal 3 $names.Count 'one link name per .lib'
            Assert-True ($names -contains 'opencv_core500') 'extension stripped'
            Assert-False ($names -contains 'opencv_core500.lib') 'extension must not survive'
        }
    }

    It 'returns an empty set for a missing directory instead of throwing' {
        $names = @(Get-LibraryLinkName -LibDir 'Q:\does\not\exist')
        Assert-Equal 0 $names.Count 'callers decide whether empty is fatal'
    }
}

Describe 'Assert-PkgConfigModule' {

    # pkg-config lives in the CONTAINER image (scoop main/pkg-config), not on a
    # dev host, so which failure fires depends on where the suite runs. Both
    # paths matter and both are asserted; skipping either would leave the gate
    # untested exactly where it runs for real.
    $havePkgConfig = $null -ne (Get-Command pkg-config -ErrorAction SilentlyContinue)

    It 'throws when a required module cannot be resolved' {
        if ($havePkgConfig) {
            # In-image: the message must name the unresolvable module, because
            # that is what tells a human reading a build log which .pc to fix.
            Assert-Throws -MessagePattern 'definitely-not-a-real-module' -Body {
                Assert-PkgConfigModule -Module @('definitely-not-a-real-module-xyz') -Context 'test'
            }
        } else {
            # On a host without the binary: refusing loudly is correct. The gate
            # must never treat "cannot check" as "checked and fine".
            Assert-Throws -MessagePattern 'pkg-config is not on PATH' -Body {
                Assert-PkgConfigModule -Module @('definitely-not-a-real-module-xyz') -Context 'test'
            }
        }
    }

    It 'names the context so the failure says WHAT would have been skipped' {
        Assert-Throws -MessagePattern 'mandatory GStreamer plugins' -Body {
            Assert-PkgConfigModule -Module @('definitely-not-a-real-module-xyz') `
                -Context 'mandatory GStreamer plugins: libav, opencv, onnx'
        }
    }
}

Describe 'Assert-PkgConfigModule version floors' {

    # Presence alone was not enough: FFmpeg shipped seven .pc files whose
    # Version: field was literally '..' because its configure found neither a
    # VERSION file nor git tags. --exists passed on all of them while every
    # consumer constraint failed, so gst-libav was skipped and the pre-flight
    # reported everything fine (measured 2026-08-07).

    $havePkgConfig = $null -ne (Get-Command pkg-config -ErrorAction SilentlyContinue)

    It 'accepts a MinimumVersion table without changing the no-modules contract' {
        # Empty module list stays a no-op regardless of the floors supplied.
        Assert-PkgConfigModule -Module @() -MinimumVersion @{ 'libavcodec' = '58.18.100' }
    }

    It 'names the module, the version found and the version required' {
        # The message has to carry all three or a build log cannot be acted on.
        if ($havePkgConfig) {
            Assert-Throws -MessagePattern 'definitely-not-real' -Body {
                Assert-PkgConfigModule -Module @('definitely-not-real-xyz') `
                    -MinimumVersion @{ 'definitely-not-real-xyz' = '1.0' } -Context 'test'
            }
        } else {
            Assert-Throws -MessagePattern 'pkg-config is not on PATH' -Body {
                Assert-PkgConfigModule -Module @('definitely-not-real-xyz') `
                    -MinimumVersion @{ 'definitely-not-real-xyz' = '1.0' } -Context 'test'
            }
        }
    }

    It 'carries the floors gst actually demands at the call site' {
        # Guards the numbers against drift from upstream's meson.build.
        $script = Get-Content (Join-Path $PSScriptRoot '..\build\build-gstreamer-from-source.ps1') -Raw
        foreach ($pair in @(
                @{ M = 'libavcodec';     V = '58.18.100' },
                @{ M = 'libavformat';    V = '58.12.100' },
                @{ M = 'libavutil';      V = '56.14.100' },
                @{ M = 'libavfilter';    V = '7.16.100' },
                @{ M = 'opencv4';        V = '4.0.0' },
                @{ M = 'libonnxruntime'; V = '1.16.1' })) {
            Assert-True ($script -match [regex]::Escape("'$($pair.M)'") + "\s*=\s*'" + [regex]::Escape($pair.V) + "'") `
                "the pre-flight must demand $($pair.M) >= $($pair.V)"
        }
    }
}

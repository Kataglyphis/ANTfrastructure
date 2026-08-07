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

    It 'names the three integrations the media stack is built around' {
        $names = @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
        Assert-Equal 3 $names.Count 'the required set is libav, opencv, onnx'
        foreach ($expected in 'libav', 'opencv', 'onnx') {
            Assert-True ($names -contains $expected) "'$expected' must be mandatory"
        }
    }

    It 'does NOT require tensorfilter (an NNStreamer element this repo never builds)' {
        # It appeared in the old probe lists only because the lying healthcheck
        # "found" it. Requiring it would fail every build forever.
        $names = @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
        Assert-False ($names -contains 'tensorfilter') 'tensorfilter is not a GStreamer plugin'
    }

    It 'carries the pkg-config modules and a rationale for every entry' {
        foreach ($p in @(Get-RequiredGstPlugin)) {
            Assert-True ($p.NeedsPc.Count -gt 0) "$($p.Name) must declare its pkg-config dependencies"
            Assert-True ([bool]$p.Why) "$($p.Name) must say WHY it is mandatory"
            Assert-True ([bool]$p.Provides) "$($p.Name) must say what it provides"
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

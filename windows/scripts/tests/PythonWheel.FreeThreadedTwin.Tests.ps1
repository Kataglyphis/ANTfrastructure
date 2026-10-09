#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: Invoke-FreeThreadedWheelVenvProof itself, which needs uv and a real free-threaded interpreter (proved in :winamd64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking

Describe 'Get-FreeThreadedTwinTable' {

    It 'names exactly the five twins the owner request lists, and every row a known verdict, pin and evidence' {
        $twins = @(Get-FreeThreadedTwinTable | Where-Object Verdict -ceq 'twin' | ForEach-Object Distribution | Sort-Object)
        Assert-Equal 'apache-tvm-ffi,av,iree-base-compiler,iree-base-runtime,onnxruntime' ($twins -join ',') 'the cp314t store''s exact set'
        foreach ($row in (Get-FreeThreadedTwinTable)) {
            # twin:<KNOB> is a Linux build switch (torch, numpy); this lane builds no twin of such a row.
            Assert-True (($row.Verdict -cin @('twin', 'gil', 'none')) -or ($row.Verdict -cmatch '^twin:[A-Z0-9_]+$')) "$($row.Distribution): verdict '$($row.Verdict)'"
            Assert-Match '^[A-Z0-9_]+=\S+$' $row.Pin "$($row.Distribution): pin"
            Assert-True ($row.Evidence.Length -gt 20) "$($row.Distribution): evidence"
            Assert-Equal $row.Distribution (ConvertTo-PythonDistributionName -Name $row.Distribution) "$($row.Distribution) is PEP 503 normal"
        }
    }

    It 'pins every row at today''s versions.env, so a bump fails here until its evidence is re-read' {
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        foreach ($row in (Get-FreeThreadedTwinTable)) {
            $key, $value = $row.Pin -split '=', 2
            Assert-True $pins.Contains($key) "$($row.Distribution): versions.env has no $key"
            Assert-Equal $value "$($pins[$key])" "$($row.Distribution) was read at $($row.Pin); versions.env moved it, re-read the evidence"
        }
    }

    It 'is the one table file the Linux lane reads, row for row, and the module carries no copy of it (mutation)' {
        $file = [IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) 'linux\scripts\03-media\free-threaded-twins.txt'))
        Assert-Equal $file (& (Get-Module WindowsPythonWheel.Common) { $script:FreeThreadedTwinTable }) 'the checkout resolves the shared file'
        $raw = @(Get-Content -LiteralPath $file | Where-Object { $_ -notmatch '^\s*(#|$)' })
        $parsed = @(Get-FreeThreadedTwinTable | ForEach-Object { "$($_.Distribution)|$($_.Verdict)|$($_.Pin)|$($_.Evidence)" })
        Assert-True ($raw.Count -ge 10) "the file has $($raw.Count) rows"
        Assert-Equal ($raw -join "`n") ($parsed -join "`n") 'every row read whole, in file order'
        $module = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1'))
        Assert-False ($module -match '[a-z0-9-]+\|(twin|twin:[A-Z0-9_]+|gil|none)\|[A-Z0-9_]+=') 'no row literal left in WindowsPythonWheel.Common.psm1'
    }

    It 'reads the copy one level above modules\ in an image, and a missing table throws rather than classifying nothing (mutation)' {
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path "$d\bkmnt\modules"
            Copy-Item (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') "$d\bkmnt\modules\"
            Set-Content -LiteralPath "$d\bkmnt\free-threaded-twins.txt" -Value @('# stand-in', 'pkg|twin|PKG_VERSION=1|stand-in evidence')
            $probe = "Import-Module '$d\bkmnt\modules\WindowsPythonWheel.Common.psm1'; (Get-FreeThreadedTwinTable | ForEach-Object Distribution) -join ','"
            Assert-Equal 'pkg' "$(& pwsh -NoProfile -NonInteractive -Command $probe)".Trim() 'a flat image mount'
            Assert-Throws { Get-FreeThreadedTwinTable -Path "$d\absent.txt" } -MessagePattern 'the twin table .*absent\.txt is missing'
        }
    }

    It 'finds a row by any spelling, ORT and GenAI flavours included; an unknown distribution has none' {
        Assert-Equal 'onnxruntime' (Get-FreeThreadedTwinRow -Distribution 'onnxruntime_directml').Distribution 'an ORT flavour'
        Assert-Equal 'onnxruntime-genai' (Get-FreeThreadedTwinRow -Distribution 'onnxruntime_genai_directml').Distribution 'a GenAI flavour'
        Assert-Equal 'twin' (Get-FreeThreadedTwinRow -Distribution 'Apache_TVM.FFI').Verdict 'case, dots and underscores'
        Assert-Equal 'none' (Get-FreeThreadedTwinRow -Distribution 'apache-tvm').Verdict 'the py3 TVM wheel'
        Assert-Null (Get-FreeThreadedTwinRow -Distribution 'pillow') 'not an image wheel'
    }
}

Describe 'Get-FreeThreadedWheelFinding' {

    It 'passes a cp3XY-cp3XYt wheel whose tagged modules carry its suffix; an untagged .pyd is the proof''s to judge' {
        Invoke-InTestDir { param($d)
            $w = New-TestWheel -Path "$d\pkg-1.0-cp314-cp314t-win_amd64.whl" -Member @{
                'pkg/_core.cp314t-win_amd64.pyd' = 'x'; 'pkg/capi/state.pyd' = 'x'; 'pkg/lib/dep.dll' = 'x'; 'pkg/__init__.py' = ''
            }
            Assert-Equal '' ((Get-FreeThreadedWheelFinding -Path $w -PlatformTag 'win_amd64') -join '|')
        }
    }

    It 'names a GIL or abi3 name, another platform and every GIL or abi3 module inside (mutation)' {
        Invoke-InTestDir { param($d)
            $gil = New-TestWheel -Path "$d\pkg-1.0-cp314-cp314-win_amd64.whl" -Member @{ 'pkg/a.pyd' = 'x' }
            Assert-Match 'tagged cp314-cp314, not a cp3XY-cp3XYt pair' ((Get-FreeThreadedWheelFinding -Path $gil -PlatformTag 'win_amd64') -join '|')
            $abi3 = New-TestWheel -Path "$d\pkg-1.0-cp312-abi3-win_amd64.whl" -Member @{ 'pkg/a.pyd' = 'x' }
            Assert-Match 'tagged cp312-abi3' ((Get-FreeThreadedWheelFinding -Path $abi3 -PlatformTag 'win_amd64') -join '|')
            $plat = New-TestWheel -Path "$d\pkg-1.0-cp314-cp314t-win32.whl" -Member @{ 'pkg/a.pyd' = 'x' }
            Assert-Match 'a win32 wheel, not win_amd64' ((Get-FreeThreadedWheelFinding -Path $plat -PlatformTag 'win_amd64') -join '|')
            $mixed = New-TestWheel -Path "$d\mix\pkg-1.0-cp314-cp314t-win_amd64.whl" -Member @{
                'pkg/ok.cp314t-win_amd64.pyd' = 'x'; 'pkg/gil.cp314-win_amd64.pyd' = 'x'; 'pkg/stable.abi3.pyd' = 'x'; 'pkg/arm.cp314t-win_arm64.pyd' = 'x'
            }
            $f = @(Get-FreeThreadedWheelFinding -Path $mixed -PlatformTag 'win_amd64')
            Assert-Equal 3 $f.Count "three wrong modules: $($f -join ' | ')"
            foreach ($m in 'gil.cp314-win_amd64.pyd', 'stable.abi3.pyd', 'arm.cp314t-win_arm64.pyd') { Assert-Match ([regex]::Escape($m)) ($f -join '|') $m }
            Assert-Match 'not a wheel file name' ((Get-FreeThreadedWheelFinding -Path "$d\pkg.tar.gz" -PlatformTag 'win_amd64') -join '|')
        }
    }
}

Describe 'Get-WheelMemberDifference' {

    It 'is empty for one build''s two wheels, and names a changed, an extra and a missing DLL (mutation)' {
        Invoke-InTestDir { param($d)
            $gil = New-TestWheel -Path "$d\gil\o-1-cp314-cp314-win_amd64.whl" -Member @{ 'o/capi/shared.dll' = 'same'; 'o/capi/state.pyd' = 'gil' }
            $twin = New-TestWheel -Path "$d\ft\o-1-cp314-cp314t-win_amd64.whl" -Member @{ 'o/capi/shared.dll' = 'same'; 'o/capi/state.pyd' = 'ft' }
            Assert-Equal '' ((Get-WheelMemberDifference -Reference $gil -Candidate $twin) -join '|') 'only the .pyd differs'
            $drift = New-TestWheel -Path "$d\drift\o-1-cp314-cp314t-win_amd64.whl" -Member @{ 'o/capi/shared.dll' = 'rebuilt'; 'o/capi/extra.dll' = 'x' }
            $f = @(Get-WheelMemberDifference -Reference $gil -Candidate $drift)
            Assert-Equal 2 $f.Count ($f -join ' | ')
            Assert-Match 'o/capi/shared\.dll differs' ($f -join '|')
            Assert-Match 'o/capi/extra\.dll is not in' ($f -join '|')
            $none = New-TestWheel -Path "$d\none\o-1-cp314-cp314t-win_amd64.whl" -Member @{ 'o/capi/state.pyd' = 'ft' }
            Assert-Match 'has no member matching \*\.dll' ((Get-WheelMemberDifference -Reference $gil -Candidate $none) -join '|') 'nothing compared is no proof'
        }
    }
}

Describe 'the free-threaded helper path' {

    It 'is the checkout''s copy in the repo, and the copy one level above modules\ in an image mount (mutation)' {
        $repoCopy = [IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) 'linux\scripts\02-toolchain\python\free-threaded-wheel.py'))
        Assert-Equal $repoCopy (& (Get-Module WindowsPythonWheel.Common) { $script:FreeThreadedHelper }) 'in the checkout'
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path "$d\bkmnt\modules"
            Copy-Item (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') "$d\bkmnt\modules\"
            Set-Content -LiteralPath "$d\bkmnt\free-threaded-wheel.py" -Value '# stand-in'
            $probe = "Import-Module '$d\bkmnt\modules\WindowsPythonWheel.Common.psm1'; & (Get-Module WindowsPythonWheel.Common) { `$script:FreeThreadedHelper }"
            Assert-Equal "$d\bkmnt\free-threaded-wheel.py" "$(& pwsh -NoProfile -NonInteractive -Command $probe)".Trim() 'a flat image mount'
        }
    }
}

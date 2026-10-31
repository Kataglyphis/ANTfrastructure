#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: Invoke-FreeThreadedWheelVenvProof itself, which needs uv and a real free-threaded interpreter (proved in :winamd64).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking

function script:Get-RepoFullPath {
    param([Parameter(Mandatory)][string]$Relative)
    return [IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) $Relative))
}

# Copies the module into a flat image mount beside a stand-in file, then returns what the expression prints in a fresh pwsh.
function script:Invoke-FlatMountProbe {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$Value, [Parameter(Mandatory)][string]$Expression)
    $null = New-Item -ItemType Directory -Force -Path "$Dir\bkmnt\modules"
    Copy-Item (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') "$Dir\bkmnt\modules\"
    Set-Content -LiteralPath "$Dir\bkmnt\$File" -Value $Value
    $probe = "Import-Module '$Dir\bkmnt\modules\WindowsPythonWheel.Common.psm1'; $Expression"
    return "$(& pwsh -NoProfile -NonInteractive -Command $probe)".Trim()
}

function script:Get-WheelFindingText {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FreeThreadedWheelFinding -Path $Path -PlatformTag 'win_amd64') -join '|'
}

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
        $file = Get-RepoFullPath 'linux\scripts\03-media\free-threaded-twins.txt'
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
            $listed = Invoke-FlatMountProbe -Dir $d -File 'free-threaded-twins.txt' -Value '# stand-in', 'pkg|twin|PKG_VERSION=1|stand-in evidence' `
                -Expression "(Get-FreeThreadedTwinTable | ForEach-Object Distribution) -join ','"
            Assert-Equal 'pkg' $listed 'a flat image mount'
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

Describe 'Set-FreeThreadedWheelDllSearchPath' {

    It 'writes the explicit and wheel-owned DLL paths with the caller path policy' {
        Invoke-InTestDir { param($d)
            $site = New-Item -ItemType Directory -Path (Join-Path $d 'site')
            $native = New-Item -ItemType Directory -Path (Join-Path $site.FullName 'pkg\native')
            Set-Content -LiteralPath (Join-Path $native.FullName 'dep.dll') -Value 'dll'
            $external = New-Item -ItemType Directory -Path (Join-Path $d 'external')
            $filePath = Join-Path $d 'not-a-directory'
            Set-Content -LiteralPath $filePath -Value 'file'
            $missing = Join-Path $d 'missing'
            [string[]]$extra = @($external.FullName, $missing, $filePath)
            $module = Get-Module WindowsPythonWheel.Common
            $policies = @(
                @{ Kind = 'Container'; Include = @($external.FullName, $native.FullName); Omit = @($missing, $filePath) }
                @{ Kind = 'Existing'; Include = @($external.FullName, $native.FullName, $filePath); Omit = @($missing) }
            )
            foreach ($policy in $policies) {
                & $module {
                    param($sitePath, $additional, $pathKind)
                    Set-FreeThreadedWheelDllSearchPath -SitePackages $sitePath -DllDirectory $additional -PathKind $pathKind
                } $site.FullName $extra $policy.Kind
                $shim = Get-Content -LiteralPath (Join-Path $site.FullName 'sitecustomize.py') -Raw
                foreach ($path in $policy.Include) { Assert-Match ([regex]::Escape($path)) $shim "$($policy.Kind) path" }
                foreach ($path in $policy.Omit) { Assert-False ($shim.Contains($path)) "$($policy.Kind) omits $path" }
            }
        }
    }
}

Describe 'Get-FreeThreadedWheelFinding' {

    It 'passes a cp3XY-cp3XYt wheel whose tagged modules carry its suffix; an untagged .pyd is the proof''s to judge' {
        Invoke-InTestDir { param($d)
            $w = New-TestWheel -Path "$d\pkg-1.0-cp314-cp314t-win_amd64.whl" -Member @{
                'pkg/_core.cp314t-win_amd64.pyd' = 'x'; 'pkg/capi/state.pyd' = 'x'; 'pkg/lib/dep.dll' = 'x'; 'pkg/__init__.py' = ''
            }
            Assert-Equal '' (Get-WheelFindingText $w)
        }
    }

    It 'names a GIL or abi3 name, another platform and every GIL or abi3 module inside (mutation)' {
        Invoke-InTestDir { param($d)
            foreach ($named in @(
                    @{ Wheel = 'pkg-1.0-cp314-cp314-win_amd64.whl'; Want = 'tagged cp314-cp314, not a cp3XY-cp3XYt pair' }
                    @{ Wheel = 'pkg-1.0-cp312-abi3-win_amd64.whl'; Want = 'tagged cp312-abi3' }
                    @{ Wheel = 'pkg-1.0-cp314-cp314t-win32.whl'; Want = 'a win32 wheel, not win_amd64' }
                )) {
                Assert-Match $named.Want (Get-WheelFindingText (New-TestWheel -Path "$d\$($named.Wheel)" -Member @{ 'pkg/a.pyd' = 'x' }))
            }
            $mixed = New-TestWheel -Path "$d\mix\pkg-1.0-cp314-cp314t-win_amd64.whl" -Member @{
                'pkg/ok.cp314t-win_amd64.pyd' = 'x'; 'pkg/gil.cp314-win_amd64.pyd' = 'x'; 'pkg/stable.abi3.pyd' = 'x'; 'pkg/arm.cp314t-win_arm64.pyd' = 'x'
            }
            $f = @(Get-FreeThreadedWheelFinding -Path $mixed -PlatformTag 'win_amd64')
            Assert-Equal 3 $f.Count "three wrong modules: $($f -join ' | ')"
            foreach ($m in 'gil.cp314-win_amd64.pyd', 'stable.abi3.pyd', 'arm.cp314t-win_arm64.pyd') { Assert-Match ([regex]::Escape($m)) ($f -join '|') $m }
            Assert-Match 'not a wheel file name' (Get-WheelFindingText "$d\pkg.tar.gz")
        }
    }
}

Describe 'Get-WheelMemberDifference' {

    It 'is empty for one build''s two wheels, and names a changed, an extra and a missing DLL (mutation)' {
        Invoke-InTestDir { param($d)
            $wheel = { param($dir, $abi, $member) New-TestWheel -Path "$d\$dir\o-1-cp314-$abi-win_amd64.whl" -Member $member }
            $gil = & $wheel gil cp314 @{ 'o/capi/shared.dll' = 'same'; 'o/capi/state.pyd' = 'gil' }
            $twin = & $wheel ft cp314t @{ 'o/capi/shared.dll' = 'same'; 'o/capi/state.pyd' = 'ft' }
            Assert-Equal '' ((Get-WheelMemberDifference -Reference $gil -Candidate $twin) -join '|') 'only the .pyd differs'
            $drift = & $wheel drift cp314t @{ 'o/capi/shared.dll' = 'rebuilt'; 'o/capi/extra.dll' = 'x' }
            $f = @(Get-WheelMemberDifference -Reference $gil -Candidate $drift)
            Assert-Equal 2 $f.Count ($f -join ' | ')
            Assert-Match 'o/capi/shared\.dll differs' ($f -join '|')
            Assert-Match 'o/capi/extra\.dll is not in' ($f -join '|')
            $none = & $wheel none cp314t @{ 'o/capi/state.pyd' = 'ft' }
            Assert-Match 'has no member matching \*\.dll' ((Get-WheelMemberDifference -Reference $gil -Candidate $none) -join '|') 'nothing compared is no proof'
        }
    }
}

Describe 'the free-threaded helper path' {

    It 'is the checkout''s copy in the repo, and the copy one level above modules\ in an image mount (mutation)' {
        $repoCopy = Get-RepoFullPath 'linux\scripts\02-toolchain\python\free-threaded-wheel.py'
        Assert-Equal $repoCopy (& (Get-Module WindowsPythonWheel.Common) { $script:FreeThreadedHelper }) 'in the checkout'
        Invoke-InTestDir { param($d)
            $helper = Invoke-FlatMountProbe -Dir $d -File 'free-threaded-wheel.py' -Value '# stand-in' -Expression '& (Get-Module WindowsPythonWheel.Common) { $script:FreeThreadedHelper }'
            Assert-Equal "$d\bkmnt\free-threaded-wheel.py" $helper 'a flat image mount'
        }
    }
}

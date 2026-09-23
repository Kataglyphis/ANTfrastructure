#requires -Version 7.0
# IREE + TVM on the rocm lane (Build-IreeFromSource.ps1, Build-TvmFromSource.ps1, rocm-checks\IREE.ps1
# and TVM.ps1): lane gating with cpu/nvidia unchanged, the carried source patches against excerpts of
# the pinned upstream files (IREE v3.11.0, TVM 994e0216), the device-bitcode pin, the feature marker
# contract, and the smoke-check verdicts. NOT covered: the builds, the downloads, a real compile.

$script:IreeScript = 'windows\scripts\build\Build-IreeFromSource.ps1'
$script:TvmScript = 'windows\scripts\build\Build-TvmFromSource.ps1'
$script:IreeCheck = 'windows\scripts\build\rocm-checks\IREE.ps1'
$script:TvmCheck = 'windows\scripts\build\rocm-checks\TVM.ps1'
$script:CpuEnv = @{ GpuType = 'cpu'; HasCuda = $false; HasRocm = $false; RocmRoot = $null }
$script:NvidiaEnv = @{ GpuType = 'nvidia'; HasCuda = $true; HasRocm = $false; RocmRoot = $null }
$script:RocmEnv = @{ GpuType = 'rocm'; HasCuda = $false; HasRocm = $true; RocmRoot = 'C:\TheRock\build' }
$script:DeviceBcSha = '336362416c68fdd8bb80328f65ca7ebaa0c119ea19c95df6df30c832a4df39b9'
# C:\llvm-patched is first on PATH on every amd64 lane (AArch64;X86, Build-LlvmFromSource.ps1).
$script:PatchedLlvm = 'C:\llvm-patched\bin\llvm-config.exe'
$script:NeverAsked = { param($c) throw "llvm-config --targets-built of $c was queried off the ROCm spike" }
# tvm.target.codegen.llvm_get_targets() against LLVM 23.1.1 (X86;AArch64;NVPTX;AMDGPU): Triple::getArchTypeName.
$script:Llvm23Arches = @('aarch64', 'aarch64_32', 'aarch64_be', 'amdgpu', 'i386', 'nvptx', 'nvptx64', 'r600', 'x86_64')

# Excerpts of the pinned upstream files, verbatim (LF); the suite also runs them as CRLF.
$script:IreeDynamicSymbols = @'
static const char* iree_hal_hip_dylib_names[] = {
#if defined(IREE_PLATFORM_WINDOWS)
    "amdhip64.dll",
#else
    "libamdhip64.so",
#endif  // IREE_PLATFORM_WINDOWS
};

    for (iree_host_size_t i = 0; i < hip_lib_search_path_count && !loaded_one;
         ++i) {
      iree_string_view_t path_entry = hip_lib_search_paths[i];
      iree_string_view_t file_prefix = iree_string_view_literal("file:");
      iree_string_builder_reset(&path_builder);
      if (iree_string_view_consume_prefix(&path_entry, file_prefix)) {
        // Load verbatim.
        status = iree_string_builder_append_string(&path_builder, path_entry);
      } else {
        // Try each variant of a platform specific library name.
        for (iree_host_size_t j = 0;
             j < IREE_ARRAYSIZE(iree_hal_hip_dylib_names) && !loaded_one; ++j) {
          // Join the directory with a system specific library name.
          iree_string_view_t sep = iree_string_view_literal("/");
          status = iree_string_builder_append_string(&path_builder, path_entry);
'@
$script:IreeRocmCMake = @'
set(_amd_device_bc_sha256 "336362416c68fdd8bb80328f65ca7ebaa0c119ea19c95df6df30c832a4df39b9")
set(_amd_device_bc_stamp "${_amd_device_bc_url} : ${_amd_device_bc_sha256}")
    file(DOWNLOAD "${_amd_device_bc_url}" "${_platform_lib_archive}"
      EXPECTED_HASH SHA256=${_amd_device_bc_sha256})
'@
$script:TvmDeviceApi = @'
#include <hip/hip_runtime_api.h>
#include <hsa/hsa.h>
#include <tvm/ffi/extra/c_env_api.h>

      case kExist: {
        if (hsa_init() == HSA_STATUS_SUCCESS) {
          int dev;
          ROCM_CALL(hipGetDeviceCount(&dev));
          value = dev > device.device_id ? 1 : 0;
          hsa_shut_down();
        } else {
          value = 0;
        }
        break;
      }
'@
$script:TvmRocmPy = @'
import os
import re
import subprocess
from os.path import exists, join

    lld_list += ["ld.lld"]
    lld_list += [f"/opt/rocm/llvm/bin/{x}" for x in lld_list]
    valid_list = [utils.which(x) for x in lld_list]
    valid_list = [x for x in valid_list if x]

    if rocdl_dir is None:
        rocm_path = find_rocm_path()
        amdgcn_path = f"{rocm_path}/amdgcn/bitcode/"

        elif "isa_version" not in n and n not in {"irif"}:
            raise RuntimeError("could not find bitcode " + n)

    except subprocess.CalledProcessError:
        print(
'@

function ConvertTo-TestCrlf([string]$Text) { return ($Text -replace '\r?\n', "`r`n") }
function Format-TvmLlvmChoice($c) { return '{0}|{1}|{2}' -f $c.BuildMinimal, $c.LlvmConfig, $c.Targets }

# A 64-byte ELF header: class, e_type, e_machine and the e_flags low byte (EF_AMDGPU_MACH) set.
function New-TestElfHeader {
    param([int]$Class = 2, [int]$Type = 3, [int]$Machine = 224, [int]$Mach = 0x4E)
    $h = [byte[]]::new(64)
    $h[0] = 0x7F; $h[1] = 0x45; $h[2] = 0x4C; $h[3] = 0x46; $h[4] = $Class; $h[5] = 1; $h[6] = 1
    [BitConverter]::GetBytes([uint16]$Type).CopyTo($h, 16)
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($h, 18)
    [BitConverter]::GetBytes([uint32]$Mach).CopyTo($h, 48)
    return , $h
}

# A vmfb stand-in: flatbuffer-ish noise with the code object embedded, as IREE lays it out.
function New-TestVmfb {
    param([byte[]]$Elf)
    $noise = [System.Text.Encoding]::ASCII.GetBytes('IREE vmfb hal.executable rocm gfx1201 ')
    return , [byte[]]($noise + $Elf + $noise)
}

Describe 'Build-IreeFromSource: rocm-lane configure args' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:IreeScript -FunctionName 'Get-IreeRocmCmakeArgs')

    It 'adds nothing on cpu, nvidia or a cross build, so their configure line is unchanged' {
        $base = @('-DIREE_HAL_DRIVER_VULKAN=ON', '-DIREE_HAL_DRIVER_CUDA=OFF', '-DIREE_TARGET_BACKEND_CUDA=OFF')
        foreach ($case in @(@{ N = 'cpu'; E = $script:CpuEnv; X = $false }, @{ N = 'nvidia'; E = $script:NvidiaEnv; X = $false },
                @{ N = 'rocm cross'; E = $script:RocmEnv; X = $true })) {
            $extra = @($base)
            $extra += @(Get-IreeRocmCmakeArgs -GpuEnv $case.E -Cross $case.X)
            Assert-Equal ($base -join '|') ($extra -join '|') "$($case.N): configure args"
            Assert-Equal $base.Count $extra.Count "$($case.N): no null element appended"
        }
    }

    It 'enables the hip driver, skips the rocminfo probe and adds the rocm target on the rocm lane' {
        $got = @(Get-IreeRocmCmakeArgs -GpuEnv $script:RocmEnv -Cross $false)
        Assert-Equal '-DIREE_HAL_DRIVER_HIP=ON|-DIREE_ROCM_TEST_TARGET_CHIP=|-DIREE_TARGET_BACKEND_ROCM=ON' ($got -join '|') 'rocm args'
    }

    It 'appends the rocm args last and only through that function' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) $script:IreeScript)
        Assert-Match '(?m)^\$ireeRocmArgs = @\(Get-IreeRocmCmakeArgs -GpuEnv \$gpuEnv -Cross \$ireeCross\)' $src 'derived from the lane'
        Assert-Match '(?s)\$cmakeExtra \+= \$ireeRocmArgs\s+# Phase B' $src 'appended right before the target configure'
        Assert-Equal 1 ([regex]::Matches($src, 'IREE_HAL_DRIVER_HIP').Count) 'the hip flag has one spelling site'
    }
}

Describe 'Build-IreeFromSource: HIP dylib-name patch (IREE v3.11.0 dynamic_symbols.c)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:IreeScript -FunctionName 'Invoke-IreeHipDylibNamePatch')

    It 'tries amdhip64_7.dll, then _6, then the legacy name, on Windows only, one --hip_dylib_path candidate each (LF and CRLF)' {
        foreach ($text in @($script:IreeDynamicSymbols, (ConvertTo-TestCrlf $script:IreeDynamicSymbols))) {
            Invoke-InTestDir {
                param($d)
                $f = Join-Path $d 'dynamic_symbols.c'
                [System.IO.File]::WriteAllText($f, $text)
                Invoke-IreeHipDylibNamePatch -Path $f
                Invoke-IreeHipDylibNamePatch -Path $f
                $out = [System.IO.File]::ReadAllText($f)
                Assert-Match '(?s)IREE_PLATFORM_WINDOWS\)\r?\n    "amdhip64_7\.dll",\r?\n    "amdhip64_6\.dll",\r?\n    "amdhip64\.dll",\r?\n#else' $out 'windows name order'
                Assert-Match '(?m)^    "libamdhip64\.so",' $out 'linux name untouched'
                # Without the reset, names 2 and 3 are appended to the previous candidate's path.
                Assert-Match '(?s)!loaded_one; \+\+j\) \{\r?\n          iree_string_builder_reset\(&path_builder\);\r?\n          // Join the directory with a system specific library name\.\r?\n          iree_string_view_t sep' $out 'reset opens the j-loop body'
                Assert-Equal '1|2' ('{0}|{1}' -f [regex]::Matches($out, 'amdhip64_7\.dll').Count, [regex]::Matches($out, 'iree_string_builder_reset\(&path_builder\);').Count) "idempotent (upstream's per-entry reset + ours)"
                Assert-Equal $text.Contains("`r") $out.Contains("`r") 'no CR introduced into an LF file'
                Assert-Equal $text.Contains("`r") ([regex]::Matches($out, '(?<!\r)\n').Count -eq 0) 'no bare LF in a CRLF file'
            }
        }
    }

    It 'throws when the name list or the search-path loop moved (a silent miss leaves hip unusable on Windows)' {
        Invoke-InTestDir {
            param($d)
            $f = Join-Path $d 'dynamic_symbols.c'
            # A moved loop matters as much as a moved list: three names with no per-name reset try concatenated paths.
            foreach ($moved in @{ Anchor = '"amdhip64\.dll",'; Into = 'kAmdHipDll,'; Says = 'name list not patched' },
                @{ Anchor = '// Join the directory with a system specific library name\.'; Into = '// Join dir + name.'; Says = 'search-path loop not patched' }) {
                [System.IO.File]::WriteAllText($f, ($script:IreeDynamicSymbols -replace $moved.Anchor, $moved.Into))
                Assert-Throws { Invoke-IreeHipDylibNamePatch -Path $f } $moved.Says -MessagePattern $moved.Says
            }
            Assert-Throws { Invoke-IreeHipDylibNamePatch -Path (Join-Path $d 'absent.c') } 'missing file' -MessagePattern 'not found'
        }
    }
}

Describe 'Build-IreeFromSource: device-bitcode pin' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:IreeScript -FunctionName 'Assert-IreeRocmDeviceBitcodePin')

    It 'accepts upstream''s hash-pinned fetch when it equals the versions.env pin' {
        Invoke-InTestDir {
            param($d)
            $f = Join-Path $d 'CMakeLists.txt'
            [System.IO.File]::WriteAllText($f, $script:IreeRocmCMake)
            Assert-IreeRocmDeviceBitcodePin -CMakeListsPath $f -ExpectedSha256 $script:DeviceBcSha
            Assert-True $true 'no throw'
        }
    }

    It 'refuses a moved pin, a dropped EXPECTED_HASH and an empty versions.env pin' {
        Invoke-InTestDir {
            param($d)
            $f = Join-Path $d 'CMakeLists.txt'
            [System.IO.File]::WriteAllText($f, $script:IreeRocmCMake)
            Assert-Throws { Assert-IreeRocmDeviceBitcodePin -CMakeListsPath $f -ExpectedSha256 ('0' * 64) } 'moved' -MessagePattern 'an IREE bump moved it'
            Assert-Throws { Assert-IreeRocmDeviceBitcodePin -CMakeListsPath $f -ExpectedSha256 '' } 'empty pin' -MessagePattern 'IREE_ROCM_DEVICE_BC_SHA256'
            [System.IO.File]::WriteAllText($f, ($script:IreeRocmCMake -replace '\s+EXPECTED_HASH SHA256=\$\{_amd_device_bc_sha256\}', ''))
            Assert-Throws { Assert-IreeRocmDeviceBitcodePin -CMakeListsPath $f -ExpectedSha256 $script:DeviceBcSha } 'unpinned fetch' -MessagePattern 'unverified fetch'
        }
    }

    It 'pins the same hash in versions.env, the media-tvm ARG and the driver map, and never in the merge' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        Assert-Match '^[0-9a-f]{64}$' $v['IREE_ROCM_DEVICE_BC_SHA256'] 'versions.env pin'
        if ($v['IREE_VERSION'] -eq 'v3.11.0') { Assert-Equal $script:DeviceBcSha $v['IREE_ROCM_DEVICE_BC_SHA256'] 'the v3.11.0 CMake pin' }
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder')
        $envStage = [regex]::Match($df, '(?s)FROM common AS media-tvm-env\r?\n(.+?)\r?\nFROM ').Groups[1].Value
        Assert-Match "(?m)^ARG IREE_ROCM_DEVICE_BC_SHA256=$($v['IREE_ROCM_DEVICE_BC_SHA256'])\s*$" $envStage 'ARG in media-tvm-env'
        Assert-Match 'IREE_ROCM_DEVICE_BC_SHA256="\$\{IREE_ROCM_DEVICE_BC_SHA256\}"' $envStage 'ENV mirror'
        $tvm = Get-MediaBranchVersionArg -Branch 'media-tvm' -VersionTable $v
        Assert-Equal $v['IREE_ROCM_DEVICE_BC_SHA256'] $tvm['IREE_ROCM_DEVICE_BC_SHA256'] 'forwarded to media-tvm'
        Assert-False ((Get-MediaMergeVersionArg -VersionTable $v).Contains('IREE_ROCM_DEVICE_BC_SHA256')) 'not a merge arg'
        $lines = [System.IO.File]::ReadAllLines((Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'))
        $at = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l.StartsWith('IREE_ROCM_DEVICE_BC_SHA256=') })
        Assert-Match 'bump:hold' $lines[$at - 1] 'bump:hold sits directly above the key (it is slaved to IREE_VERSION)'
    }
}

Describe 'Build-TvmFromSource: rocm-lane plan and configure args' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmPlan', 'Get-TvmLlvmTargetList', 'Get-TvmRocmCmakeArgs', 'Test-TvmLlvmHasAmdgpu', 'Get-TvmLlvmChoice')

    It 'changes nothing on cpu and nvidia: same LLVM and targets, no appended args, ROCM_PATH left alone' {
        foreach ($case in @(@{ N = 'cpu'; E = $script:CpuEnv }, @{ N = 'nvidia'; E = $script:NvidiaEnv })) {
            foreach ($flag in @($null, '', '0', '1')) {
                $plan = Get-TvmRocmPlan -GpuEnv $case.E -Cross $false -SpikeFlag $flag
                Assert-False $plan.OnLane "$($case.N)/TVM_ROCM=$flag on lane"
                Assert-False $plan.HideRocmPath "$($case.N)/TVM_ROCM=$flag hides ROCM_PATH"
                Assert-Equal 0 @(Get-TvmRocmCmakeArgs -Plan $plan).Count "$($case.N)/TVM_ROCM=$flag args"
                # PATH's llvm-config is linked unasked; without one (-StockLlvm) the historic list and log line.
                $onPath = Get-TvmLlvmChoice -PathLlvmConfig $script:PatchedLlvm -Rocm $plan.Rocm -Cross $false -GetTargetsBuilt $script:NeverAsked
                Assert-Equal "False|$($script:PatchedLlvm)|" (Format-TvmLlvmChoice $onPath) "$($case.N)/TVM_ROCM=$flag PATH llvm-config"
                $stock = Get-TvmLlvmChoice -PathLlvmConfig $null -Rocm $plan.Rocm -Cross $false -GetTargetsBuilt $script:NeverAsked
                Assert-Equal 'True||X86;AArch64;NVPTX|llvm-config.exe not on PATH (scoop LLVM never ships it)' "$(Format-TvmLlvmChoice $stock)|$($stock.Why)" "$($case.N)/TVM_ROCM=$flag -StockLlvm"
            }
        }
    }

    It 'turns on the OpenCL runtime alone on the rocm lane without the spike, and hides ROCM_PATH' {
        foreach ($flag in @($null, '', '0', 'yes')) {
            $plan = Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $false -SpikeFlag $flag
            Assert-True ($plan.OnLane -and -not $plan.Rocm -and $plan.HideRocmPath) "TVM_ROCM=$flag"
            Assert-Equal '-DUSE_OPENCL=ON' (@(Get-TvmRocmCmakeArgs -Plan $plan) -join '|') "TVM_ROCM=$flag args"
            Assert-Equal 'X86;AArch64;NVPTX' (Get-TvmLlvmTargetList -Rocm $plan.Rocm) "TVM_ROCM=$flag LLVM targets"
        }
    }

    It 'adds AMDGPU, USE_ROCM and the pre-seeded HIP import lib with TVM_ROCM=1' {
        $plan = Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $false -SpikeFlag '1'
        Assert-True ($plan.Rocm -and -not $plan.HideRocmPath) 'spike on, ROCM_PATH visible'
        Assert-Equal 'X86;AArch64;NVPTX;AMDGPU' (Get-TvmLlvmTargetList -Rocm $plan.Rocm) 'LLVM targets'
        Assert-Equal '-DUSE_OPENCL=ON|-DUSE_ROCM=C:/TheRock/build|-DROCM_HIPHCC_LIBRARY=C:/TheRock/build/lib/amdhip64.lib' `
            (@(Get-TvmRocmCmakeArgs -Plan $plan) -join '|') 'spike args, forward slashes'
    }

    It 'never enables anything on a cross build' {
        $plan = Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $true -SpikeFlag '1'
        Assert-False ($plan.OnLane -or $plan.Rocm -or $plan.HideRocmPath) 'cross'
    }

    It 'keeps the shared list byte-identical and routes the rocm args and LLVM targets through the helpers' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) $script:TvmScript)
        Assert-Match "(?m)^\s+'-DUSE_OPENCL=OFF'\s*$" $src 'shared list keeps USE_OPENCL=OFF'
        Assert-Match '"-DLLVM_TARGETS_TO_BUILD=\$\(\$tvmLlvm\.Targets\)"' $src 'minimal LLVM takes the chosen list'
        Assert-Match '(?m)^\$cmakeExtra \+= @\(Get-TvmRocmCmakeArgs -Plan \$tvmRocmPlan\)\r?\nInvoke-CmakeConfigure -SourceDir \$SourceDir' $src 'appended last'
        Assert-Match '(?m)^if \(\$tvmRocmPlan\.HideRocmPath -and \$env:ROCM_PATH\)' $src 'ROCM_PATH hidden only by the plan'
        Assert-Match '(?m)^if \(\$tvmRocmPlan\.HideRocmPath -and \$null -ne \$savedRocmPath\) \{ \$env:ROCM_PATH = \$savedRocmPath \}' $src 'and restored'
    }
}

Describe 'Build-TvmFromSource: which LLVM TVM links (the toolchain LLVM has no AMDGPU)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmPlan', 'Get-TvmLlvmTargetList', 'Test-TvmLlvmHasAmdgpu', 'Assert-TvmLlvmHasAmdgpu', 'Get-TvmLlvmTargetsBuilt', 'Get-TvmLlvmChoice')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmCheck -FunctionName 'Get-TvmRocmMarkerFinding')

    # The toolchain LLVM's target list, from the script that builds it (cpu/nvidia: the plan Describe above).
    $script:ToolchainTargetLists = @([regex]::Matches((Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LlvmFromSource.ps1')), '-DLLVM_TARGETS_TO_BUILD=([A-Za-z0-9_;]+)'))
    function New-TargetsBuiltProbe([string]$Printed) { return { param($c) $Printed }.GetNewClosure() }

    It 'asks PATH''s llvm-config on the spike only, and builds a minimal LLVM with AMDGPU when it has none' {
        $minimal = 'True||X86;AArch64;NVPTX;AMDGPU'
        $onPath = "False|$($script:PatchedLlvm)|"
        foreach ($c in @(
                @{ Flag = '0'; Path = $script:PatchedLlvm; Printed = $null; Want = $onPath }
                @{ Flag = '1'; Path = $script:PatchedLlvm; Printed = "AArch64 X86`r`n"; Want = $minimal }
                @{ Flag = '1'; Path = $script:PatchedLlvm; Printed = 'AArch64 NVPTX X86'; Want = $minimal }
                @{ Flag = '1'; Path = $script:PatchedLlvm; Printed = ''; Want = $minimal }
                @{ Flag = '1'; Path = $script:PatchedLlvm; Printed = 'AArch64 AMDGPU X86'; Want = $onPath }
                @{ Flag = '1'; Path = $null; Printed = $null; Want = $minimal })) {
            $plan = Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $false -SpikeFlag $c.Flag
            $ask = if ($null -eq $c.Printed) { $script:NeverAsked } else { New-TargetsBuiltProbe $c.Printed }
            $got = Get-TvmLlvmChoice -PathLlvmConfig $c.Path -Rocm $plan.Rocm -Cross $false -GetTargetsBuilt $ask
            $printed = "$($c.Printed)".Trim()
            Assert-Equal $c.Want (Format-TvmLlvmChoice $got) "TVM_ROCM=$($c.Flag), PATH '$($c.Path)' prints '$printed'"
            if ($c.Path -and $got.BuildMinimal) { Assert-Match "llvm-patched\\bin\\llvm-config\.exe has no AMDGPU target \(targets-built: '$([regex]::Escape($printed))'\)" $got.Why "reason for '$printed'" }
        }
        Assert-Equal 'False||' (Format-TvmLlvmChoice (Get-TvmLlvmChoice -PathLlvmConfig $null -Rocm $true -Cross $true -GetTargetsBuilt $script:NeverAsked)) 'cross'
    }

    It 'ends the spike on an LLVM with AMDGPU against the real toolchain''s target list' {
        Assert-Equal 1 $script:ToolchainTargetLists.Count 'Build-LlvmFromSource.ps1 has one LLVM_TARGETS_TO_BUILD'
        $printed = ($script:ToolchainTargetLists[0].Groups[1].Value -split ';') -join ' '
        $c = Get-TvmLlvmChoice -PathLlvmConfig $script:PatchedLlvm -Rocm $true -Cross $false -GetTargetsBuilt (New-TargetsBuiltProbe $printed)
        $linked = if ($c.BuildMinimal) { $c.Targets } else { $printed }
        Assert-True (Test-TvmLlvmHasAmdgpu -TargetsBuilt $linked) "toolchain prints '$printed'; TVM links '$linked'"
        Assert-TvmLlvmHasAmdgpu -TargetsBuilt $linked -LlvmConfig 'the chosen llvm-config'
    }

    It 'asks a real llvm-config through the script''s own query (cmd, quoting, trim)' {
        Invoke-InTestDir {
            param($d)
            $cfg = Join-Path $d 'llvm config.cmd'
            [System.IO.File]::WriteAllText($cfg, "@echo off`r`nif ""%~1""==""--targets-built"" (echo AArch64 X86) else (exit /b 2)`r`n")
            Assert-Equal 'AArch64 X86' (Get-TvmLlvmTargetsBuilt -LlvmConfig $cfg) 'targets-built line'
            $c = Get-TvmLlvmChoice -PathLlvmConfig $cfg -Rocm $true -Cross $false -GetTargetsBuilt ${function:Get-TvmLlvmTargetsBuilt}
            Assert-Equal 'True||X86;AArch64;NVPTX;AMDGPU' (Format-TvmLlvmChoice $c) 'spike routes to the minimal build'
        }
    }

    It 'refuses the pre-fix outcome in the build and flags it in the image' {
        Assert-Throws { Assert-TvmLlvmHasAmdgpu -TargetsBuilt 'AArch64;X86' -LlvmConfig $script:PatchedLlvm } 'spike on the toolchain LLVM' -MessagePattern 'no AMDGPU target'
        Assert-Match 'TVM_ROCM=1 but LLVM_TARGETS=AArch64;X86 has no AMDGPU' "$(Get-TvmRocmMarkerFinding -Features @{ TVM_ROCM = '1'; LLVM_TARGETS = 'AArch64;X86' })" 'marker'
    }
}

Describe 'Build-TvmFromSource: ROCm spike source patches (TVM 994e0216)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmPatchSpec', 'Invoke-TvmRocmSourcePatch')

    function New-TvmFixtureTree([string]$Root, [bool]$Crlf) {
        $api = Join-Path $Root 'src\backend\rocm\runtime\rocm_device_api.cc'
        $py = Join-Path $Root 'python\tvm\support\rocm.py'
        New-Item -ItemType Directory -Force -Path (Split-Path $api), (Split-Path $py) | Out-Null
        [System.IO.File]::WriteAllText($api, $(if ($Crlf) { ConvertTo-TestCrlf $script:TvmDeviceApi } else { $script:TvmDeviceApi }))
        [System.IO.File]::WriteAllText($py, $(if ($Crlf) { ConvertTo-TestCrlf $script:TvmRocmPy } else { $script:TvmRocmPy }))
        return @{ Api = $api; Py = $py }
    }

    It 'drops HSA, asks HIP for kExist and fixes rocm.py for Windows (LF and CRLF, idempotent)' {
        foreach ($crlf in $false, $true) {
            Invoke-InTestDir {
                param($d)
                $t = New-TvmFixtureTree $d $crlf
                Invoke-TvmRocmSourcePatch -SourceDir $d
                Invoke-TvmRocmSourcePatch -SourceDir $d
                $api = [System.IO.File]::ReadAllText($t.Api)
                Assert-False ($api -match 'hsa') "crlf=$crlf no HSA left"
                Assert-Match 'value = \(hipGetDeviceCount\(&dev\) == hipSuccess && dev > device\.device_id\) \? 1 : 0;' $api "crlf=$crlf kExist"
                $py = [System.IO.File]::ReadAllText($t.Py)
                Assert-Match '(?m)^import shutil\r?\nimport subprocess' $py "crlf=$crlf import"
                Assert-Match '(?m)^    lld_list \+= \[os\.path\.join\(os\.environ\["ROCM_PATH"\], "lib", "llvm", "bin", "ld\.lld"\)\] if os\.environ\.get\("ROCM_PATH"\) else \[\]\r?\n    valid_list = \[utils\.which\(x\) or shutil\.which\(x\) for x in lld_list\]' $py "crlf=$crlf ld.lld"
                Assert-Match '(?m)^    if rocdl_dir is None and os\.path\.isdir\(os\.environ\.get\("HIP_DEVICE_LIB_PATH", ""\)\):\r?\n        rocdl_dir = os\.environ\["HIP_DEVICE_LIB_PATH"\]\r?\n    if rocdl_dir is None:\r?\n        rocm_path = find_rocm_path\(\)' $py "crlf=$crlf bitcode dir"
                Assert-Match '"oclc_daz_opt_on", "oclc_daz_opt_off", "oclc_correctly_rounded_sqrt_on", "oclc_correctly_rounded_sqrt_off"\}' $py "crlf=$crlf optional bitcode"
                Assert-Match 'except \(subprocess\.CalledProcessError, OSError\):' $py "crlf=$crlf rocminfo"
                Assert-Equal 1 ([regex]::Matches($py, '(?m)^import shutil').Count) "crlf=$crlf idempotent"
                Assert-Equal ($crlf) ($py.Contains("`r`n")) "crlf=$crlf line endings kept"
            }
        }
    }

    It 'throws when an anchor moved instead of shipping a half-patched spike' {
        Invoke-InTestDir {
            param($d)
            $t = New-TvmFixtureTree $d $false
            [System.IO.File]::WriteAllText($t.Py, ($script:TvmRocmPy -replace 'valid_list = \[utils\.which\(x\) for x in lld_list\]', 'valid_list = list(map(utils.which, lld_list))'))
            Assert-Throws { Invoke-TvmRocmSourcePatch -SourceDir $d } 'moved ld.lld lookup' -MessagePattern 'did not land'
        }
        Invoke-InTestDir {
            param($d)
            $t = New-TvmFixtureTree $d $false
            [System.IO.File]::WriteAllText($t.Api, ($script:TvmDeviceApi -replace 'if \(hsa_init\(\)', 'if (hsa_init(nullptr)'))
            Assert-Throws { Invoke-TvmRocmSourcePatch -SourceDir $d } 'changed kExist' -MessagePattern 'upstream layout changed'
        }
    }
}

Describe 'Build-TvmFromSource: guards and the feature marker' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmPlan', 'Assert-TvmLlvmConfigNotRocm', 'Test-TvmLlvmHasAmdgpu', 'Assert-TvmLlvmHasAmdgpu', 'ConvertTo-TvmLlvmTargetString', 'Get-TvmRocmFeatureMarker')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmCheck -FunctionName 'Read-TvmRocmFeatureMarker')

    It 'refuses an llvm-config that resolves into the ROCm tree, and nothing else' {
        Assert-Throws { Assert-TvmLlvmConfigNotRocm -LlvmConfig 'C:\TheRock\build\lib\llvm\bin\llvm-config.exe' -RocmRoot 'C:\TheRock\build' } 'AMD LLVM' -MessagePattern 'ROCm tree'
        Assert-TvmLlvmConfigNotRocm -LlvmConfig 'C:\temp\llvm-dev\install\bin\llvm-config.exe' -RocmRoot 'C:\TheRock\build'
        Assert-TvmLlvmConfigNotRocm -LlvmConfig 'C:\TheRock\buildx\llvm-config.exe' -RocmRoot 'C:\TheRock\build\'
        Assert-TvmLlvmConfigNotRocm -LlvmConfig $null -RocmRoot 'C:\TheRock\build'
        Assert-True $true 'only the ROCm-tree path threw'
    }

    It 'needs AMDGPU in llvm-config --targets-built for the spike' {
        Assert-TvmLlvmHasAmdgpu -TargetsBuilt "AArch64 AMDGPU NVPTX X86`r`n" -LlvmConfig 'llvm-config'
        Assert-TvmLlvmHasAmdgpu -TargetsBuilt 'X86;AMDGPU' -LlvmConfig 'llvm-config'
        foreach ($no in 'AArch64 NVPTX X86', 'AMDGPUX86', 'amdgpu', '') {
            Assert-Throws { Assert-TvmLlvmHasAmdgpu -TargetsBuilt $no -LlvmConfig 'llvm-config' } "no AMDGPU in '$no'" -MessagePattern 'no AMDGPU target'
        }
    }

    It 'turns a --targets-built line into the marker list' {
        Assert-Equal 'AArch64;X86' (ConvertTo-TvmLlvmTargetString -TargetsBuilt " AArch64  X86`r`n") 'spaces and CRLF'
        Assert-Equal 'X86;AMDGPU' (ConvertTo-TvmLlvmTargetString -TargetsBuilt 'X86;AMDGPU') 'already a list'
        Assert-Equal '' (ConvertTo-TvmLlvmTargetString -TargetsBuilt '') 'empty'
    }

    It 'writes the read-back targets into a marker the smoke check reads and accepts (spike on and off)' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmCheck -FunctionName 'Get-TvmRocmMarkerFinding', 'Get-TvmRocmLlvmTargetFinding')
        foreach ($case in @(
                @{ Flag = '1'; Printed = "X86 AArch64 NVPTX AMDGPU`r`n"; Want = '1|ON|C:/TheRock/build|X86;AArch64;NVPTX;AMDGPU'; Archs = $script:Llvm23Arches }
                @{ Flag = '0'; Printed = 'AArch64 X86'; Want = '0|ON|OFF|AArch64;X86'; Archs = @($script:Llvm23Arches -notmatch '^(amdgpu|r600|nvptx)') })) {
            Invoke-InTestDir {
                param($d)
                $plan = Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $false -SpikeFlag $case.Flag
                $f = Join-Path $d 'ROCM-FEATURES.txt'
                Set-Content -Path $f -Encoding ascii -Value (Get-TvmRocmFeatureMarker -Plan $plan -LlvmTargets (ConvertTo-TvmLlvmTargetString -TargetsBuilt $case.Printed))
                $read = Read-TvmRocmFeatureMarker -Path $f
                Assert-Equal $case.Want ('{0}|{1}|{2}|{3}' -f $read['TVM_ROCM'], $read['USE_OPENCL'], $read['USE_ROCM'], $read['LLVM_TARGETS']) "TVM_ROCM=$($case.Flag) round trip"
                $findings = @(Get-TvmRocmMarkerFinding -Features $read) + @(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = $case.Archs } -Features $read)
                Assert-Equal '' ($findings -join ' / ') "TVM_ROCM=$($case.Flag) accepted by the smoke check"
                Assert-Null (Read-TvmRocmFeatureMarker -Path (Join-Path $d 'absent.txt')) 'absent marker'
            }
        }
    }
}

Describe 'Build-IreeFromSource + Build-TvmFromSource: rocm-only steps sit behind the lane decision' {
    $script:RocmStepTree = @{}
    foreach ($rel in $script:IreeScript, $script:TvmScript) {
        $text = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $rel))
        $script:RocmStepTree[$rel] = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
    }

    # Script-level sites of a command or string literal. Guards = the if-conditions whose body encloses
    # the site, innermost first; 'else' / 'condition' mark a site that no condition of ours protects.
    function Get-RocmStepSite([string]$RelPath, [string]$Command, [string]$Literal) {
        $hits = $script:RocmStepTree[$RelPath].FindAll({ param($n)
                if ($Command) { return $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Command }
                return $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq $Literal }, $true)
        foreach ($hit in $hits) {
            $guards = [System.Collections.Generic.List[string]]::new()
            $inFunction = $false
            for ($below = $hit; $below.Parent; $below = $below.Parent) {
                $up = $below.Parent
                if ($up -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true }
                if ($up -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
                $body = @($up.Clauses | Where-Object { [object]::ReferenceEquals($_.Item2, $below) })
                $guards.Add($(if ($body) { $body[0].Item1.Extent.Text } elseif ([object]::ReferenceEquals($up.ElseClause, $below)) { 'else' } else { 'condition' }))
            }
            if (-not $inFunction) { [pscustomobject]@{ Line = $hit.Extent.StartLineNumber; Guards = $guards.ToArray(); Text = $hit.Extent.Text } }
        }
    }

    It 'derives the lane, the LLVM TVM links and the targets it records from the helpers the tests cover' {
        foreach ($c in @(
                @{ S = $script:IreeScript; V = '$ireeRocmArgs'; R = '@(Get-IreeRocmCmakeArgs -GpuEnv $gpuEnv -Cross $ireeCross)' }
                @{ S = $script:IreeScript; V = '$ireeRocm'; R = '$ireeRocmArgs.Count -gt 0' }
                @{ S = $script:TvmScript; V = '$tvmRocmPlan'; R = 'Get-TvmRocmPlan -GpuEnv $gpuEnv -Cross $tvmCross -SpikeFlag $env:TVM_ROCM' }
                @{ S = $script:TvmScript; V = '$tvmLlvm'; R = 'Get-TvmLlvmChoice -PathLlvmConfig $pathLlvmConfig -Rocm $tvmRocmPlan.Rocm -Cross $tvmCross -GetTargetsBuilt ${function:Get-TvmLlvmTargetsBuilt}' }
                @{ S = $script:TvmScript; V = '$llvmConfig'; R = '$tvmLlvm.LlvmConfig|Join-Path $llvmInstall ''bin\llvm-config.exe''' }
                @{ S = $script:TvmScript; V = '$tvmLlvmTargetsBuilt'; R = 'ConvertTo-TvmLlvmTargetString -TargetsBuilt (Get-TvmLlvmTargetsBuilt -LlvmConfig $llvmConfig)' })) {
            $sets = $script:RocmStepTree[$c.S].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $c.V }, $true)
            Assert-Equal $c.R (@($sets | ForEach-Object { $_.Right.Extent.Text }) -join '|') "$($c.V): every assignment, in order"
        }
    }

    It 'patches TVM sources, checks LLVM and writes the marker only under the rocm plan, and builds LLVM only when chosen' {
        # rocm.py ships in every lane's tvm wheel: an unguarded source patch would change cpu/nvidia bytes.
        foreach ($c in @(
                @{ Command = 'Invoke-TvmRocmSourcePatch'; Want = '$tvmRocmPlan.Rocm' }
                @{ Command = 'Assert-TvmLlvmHasAmdgpu'; Want = '$tvmRocmPlan.Rocm'; Call = 'Assert-TvmLlvmHasAmdgpu -TargetsBuilt $tvmLlvmTargetsBuilt -LlvmConfig $llvmConfig' }
                @{ Command = 'Assert-TvmLlvmConfigNotRocm'; Want = '$tvmRocmPlan.OnLane' }
                @{ Command = 'Get-TvmLlvmTargetsBuilt'; Want = '$tvmRocmPlan.OnLane' }
                @{ Command = 'Get-TvmRocmFeatureMarker'; Want = '$tvmRocmPlan.OnLane'; Call = 'Get-TvmRocmFeatureMarker -Plan $tvmRocmPlan -LlvmTargets $tvmLlvmTargetsBuilt' }
                @{ Command = 'Get-LlvmSourceTarball'; Want = '$tvmLlvm.BuildMinimal' }
                @{ Literal = 'ROCM-FEATURES.txt'; Want = '$tvmRocmPlan.OnLane' })) {
            $what = "$($c['Command'])$($c['Literal'])"
            $sites = @(Get-RocmStepSite -RelPath $script:TvmScript -Command $c['Command'] -Literal $c['Literal'])
            Assert-Equal 1 $sites.Count "$what has one script-level site"
            Assert-Equal $c.Want "$($sites[0].Guards | Select-Object -First 1)" "$what innermost guard (line $($sites[0].Line))"
            Assert-Equal 0 @($sites[0].Guards -match '^(else|condition)$').Count "$what is not in an else body or a condition"
            # The gate and the marker take the list read back from the llvm-config TVM links.
            if ($c['Call']) { Assert-Equal $c['Call'] $sites[0].Text "$what arguments" }
        }
    }

    It 'patches IREE sources and checks the bitcode pin only on the rocm lane' {
        foreach ($name in 'Invoke-IreeHipDylibNamePatch', 'Assert-IreeRocmDeviceBitcodePin') {
            $sites = @(Get-RocmStepSite -RelPath $script:IreeScript -Command $name)
            Assert-Equal 1 $sites.Count "$name has one script-level site"
            Assert-Equal '$ireeRocm' "$($sites[0].Guards | Select-Object -First 1)" "$name innermost guard (line $($sites[0].Line))"
            Assert-Equal 0 @($sites[0].Guards -match '^(else|condition)$').Count "$name is not in an else body or a condition"
        }
    }
}

Describe 'Dockerfile.media-builder: the TVM_ROCM switch' {
    It 'declares ARG TVM_ROCM=0 in media-tvm-built only, with no ENV mirror' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder')
        $built = [regex]::Match($df, '(?s)FROM media-tvm-env AS media-tvm-built\r?\n(.+?)(\r?\nFROM |\z)').Groups[1].Value
        Assert-Match '(?m)^ARG TVM_ROCM=0\s*$' $built 'declared where the RUN reads it'
        Assert-False ($df -match '(?m)^\s*(ENV\s+)?TVM_ROCM="\$\{TVM_ROCM\}"') 'no ENV mirror: nothing downstream reads it'
        Assert-Equal 1 ([regex]::Matches($df, '(?m)^ARG TVM_ROCM=').Count) 'one declaration'
    }
}

Describe 'rocm-checks\IREE.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:IreeCheck -FunctionName 'Get-ElfHeaderRecord', 'Get-AmdgpuCodeObjectFinding', 'Get-IreeHipSearchPathFinding', 'Get-IreeRocmGateMlir', 'Get-IreeRocmPythonProbe', 'Get-IreeRocmFinding')

    # The search probe models dynamic_symbols.c: -Search concat is upstream's loop without the reset, legacy its
    # one-name list, and a --hip_dylib_path after --list_devices=hip is ignored (measured on the 3.11.0 CLI).
    function New-FakeIreeInvoke {
        param([string]$ListOutput, [byte[]]$Vmfb, [string]$Report, [int]$CompileExit = 0, [string]$Search = 'reset')
        $SearchNames = if ($Search -eq 'legacy') { , 'amdhip64.dll' } else { 'amdhip64_7.dll', 'amdhip64_6.dll', 'amdhip64.dll' }
        return {
            param([string]$Exe, [string[]]$ArgList)
            switch (Split-Path $Exe -Leaf) {
                'iree-run-module.exe' {
                    if ($ArgList -contains '--list_drivers') { return @{ Exit = 0; Output = $ListOutput } }
                    $dir = if (($ArgList -join "`n") -match '(?m)^--hip_dylib_path=(.+)$[\s\S]*^--list_devices=hip$') { $Matches[1] } else { '' }
                    $path = ''
                    $tried = foreach ($name in $SearchNames) {
                        if (-not $dir) { $name } else {
                            if ($Search -ne 'concat') { $path = '' }
                            $path = "$path$dir/$name" -replace '[\\/]+', '\'
                            $path
                        }
                    }
                    $detail = ($tried | ForEach-Object { "  Tried: $_`n    dynamic_library_win32.c:231: NOT_FOUND; dynamic library not found on any search path" }) -join "`n"
                    return @{ Exit = 1; Output = "dynamic_symbols.c:155: UNAVAILABLE; HIP runtime library 'amdhip64.dll'/'libamdhip64.so' not available: `n$detail`n" }
                }
                'iree-compile.exe' {
                    if ($CompileExit -eq 0) { [System.IO.File]::WriteAllBytes($ArgList[-1], $Vmfb) }
                    return @{ Exit = $CompileExit; Output = '' }
                }
                default {
                    [System.IO.File]::WriteAllBytes($ArgList[2], $Vmfb)
                    return @{ Exit = 0; Output = "iree warming up`n$Report`n" }
                }
            }
        }.GetNewClosure()
    }
    function New-FakeIreeInstall([string]$Root, [bool]$Patched = $true, [string[]]$BitcodeNames = @('ocml.bc', 'ockl.bc')) {
        $bin = Join-Path $Root 'iree\bin'
        New-Item -ItemType Directory -Force -Path (Join-Path $bin 'iree_platform_libs\rocm') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bin 'iree-compile.exe'), 'MZ compile')
        [System.IO.File]::WriteAllText((Join-Path $bin 'iree-run-module.exe'), "MZ run $(if ($Patched) { 'amdhip64_7.dll' }) amdhip64.dll")
        foreach ($bc in $BitcodeNames) { [System.IO.File]::WriteAllText((Join-Path $bin "iree_platform_libs\rocm\$bc"), 'BC') }
        $scratch = Join-Path $Root 'scratch'
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        return @{ Bin = $bin; Scratch = $scratch }
    }
    $script:GoodList = "# Available HAL drivers`n            cuda: CUDA HAL driver (via dylib)`n             hip: HIP HAL driver (via dylib)`n      local-task: Local execution`n"
    $script:GoodReport = '{"drivers": ["cuda", "hip", "local-sync", "local-task", "vulkan"], "pyds": 1, "pyd_patched": true}'

    It 'reads ELF headers out of a blob and ignores a truncated tail' {
        $blob = New-TestVmfb (New-TestElfHeader)
        $recs = @(Get-ElfHeaderRecord -Bytes $blob)
        Assert-Equal 1 $recs.Count 'one object'
        Assert-Equal '2|3|224|78' ('{0}|{1}|{2}|{3}' -f $recs[0].Class, $recs[0].Type, $recs[0].Machine, $recs[0].Mach) 'fields'
        Assert-Equal 0 @(Get-ElfHeaderRecord -Bytes ([byte[]](0x7F, 0x45, 0x4C, 0x46, 2))).Count 'truncated header'
        Assert-Equal 0 @(Get-ElfHeaderRecord -Bytes ([byte[]]@())).Count 'empty blob'
    }

    It 'accepts only a linked ELF64 AMDGPU object for gfx1201' {
        Assert-Equal 0 @(Get-AmdgpuCodeObjectFinding -Bytes (New-TestVmfb (New-TestElfHeader)) -What 'x').Count 'good'
        foreach ($bad in @(
                @{ N = 'gfx1200'; E = (New-TestElfHeader -Mach 0x48); P = 'mach 0x4E' },
                @{ N = 'relocatable'; E = (New-TestElfHeader -Type 1); P = 'no linked ELF64' },
                @{ N = 'ELF32'; E = (New-TestElfHeader -Class 1); P = 'no linked ELF64' },
                @{ N = 'x86-64'; E = (New-TestElfHeader -Machine 62); P = 'no AMDGPU' })) {
            Assert-Match $bad.P "$(Get-AmdgpuCodeObjectFinding -Bytes (New-TestVmfb $bad.E) -What 'x')" $bad.N
        }
        Assert-Match 'no AMDGPU' "$(Get-AmdgpuCodeObjectFinding -Bytes ([byte[]]@()) -What 'x')" 'empty'
    }

    It 'wants exactly one clean <dir>\<name> candidate per Windows name from --hip_dylib_path' {
        $dir = 'C:\scratch\no-hip-runtime'
        $clean = "  Tried: $dir\amdhip64_7.dll`r`n    NOT_FOUND`r`n  Tried: $dir\amdhip64_6.dll`r`n    NOT_FOUND`r`n  Tried: $dir\amdhip64.dll`r`n    NOT_FOUND`r`n"
        Assert-Equal 0 @(Get-IreeHipSearchPathFinding -Output $clean -Dir $dir).Count 'patched names + reset'
        Assert-Equal 0 @(Get-IreeHipSearchPathFinding -Output $clean -Dir 'C:/scratch//no-hip-runtime').Count 'dir canonicalized like IREE does'
        # Verbatim shape of the unpatched 3.11.0 CLI: one name only.
        $upstream = "dynamic_symbols.c:155: UNAVAILABLE; HIP runtime library 'amdhip64.dll'/'libamdhip64.so' not available: please ensure installed and in dynamic library search path: `n  Tried: $dir\amdhip64.dll`n    dynamic_library_win32.c:231: NOT_FOUND; dynamic library not found on any search path`n"
        Assert-Match "tried \[C:\\scratch\\no-hip-runtime\\amdhip64\.dll\], expected" "$(Get-IreeHipSearchPathFinding -Output $upstream -Dir $dir)" 'upstream names'
        $concat = "  Tried: $dir\amdhip64_7.dll`n  Tried: $dir\amdhip64_7.dll$dir\amdhip64_6.dll`n  Tried: $dir\amdhip64_7.dll$dir\amdhip64_6.dll$dir\amdhip64.dll`n"
        Assert-Match 'explicit-path HIP lookup is broken' "$(Get-IreeHipSearchPathFinding -Output $concat -Dir $dir)" 'no per-name reset'
        Assert-Match 'tried \[\], expected' "$(Get-IreeHipSearchPathFinding -Output '' -Dir $dir)" 'no candidates listed'
        Assert-Equal 1 @(Get-IreeHipSearchPathFinding -Output ($clean -replace 'amdhip64_7', 'AMDHIP64_7') -Dir $dir).Count 'case-sensitive'
    }

    It 'passes a complete install and names each gap on its own' {
        $vmfb = New-TestVmfb (New-TestElfHeader)
        Invoke-InTestDir {
            param($d)
            $i = New-FakeIreeInstall $d
            $good = New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report $script:GoodReport
            Assert-Equal '' (@(Get-IreeRocmFinding -IreeBin $i.Bin -ScratchDir $i.Scratch -Invoke $good) -join ' / ') 'healthy image'
            $cases = @(
                @{ N = 'no hip driver'; Inv = (New-FakeIreeInvoke -ListOutput ($script:GoodList -replace '(?m)^\s+hip:.*$', '') -Vmfb $vmfb -Report $script:GoodReport); P = 'does not list the hip HAL driver' }
                @{ N = 'search loop without reset'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report $script:GoodReport -Search 'concat'); P = 'tried \[[^\]]*amdhip64_7\.dll[A-Za-z]:\\[^\]]*\].+explicit-path HIP lookup is broken' }
                @{ N = 'compile fails'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report $script:GoodReport -CompileExit 1); P = 'iree-compile .+ failed \(exit 1\)' }
                # Both compile paths (CLI and python) get the gfx1200 object here, so both report.
                @{ N = 'wrong arch'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb (New-TestVmfb (New-TestElfHeader -Mach 0x48)) -Report $script:GoodReport); P = 'iree-compile gfx1201 vmfb .+mach 0x4E'; Findings = 2 }
                @{ N = 'python lacks hip'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report ($script:GoodReport -replace '"hip", ', '')); P = 'iree.runtime lists no hip' }
                @{ N = 'pyd unpatched'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report ($script:GoodReport -replace 'true', 'false')); P = 'extension .+ does not look for amdhip64_7' }
                @{ N = 'python compile error'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report ($script:GoodReport -replace '\}$', ', "compile_error": "RuntimeError: boom"}')); P = 'iree.compiler rocm compile failed: RuntimeError: boom' }
                @{ N = 'python no report'; Inv = (New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report 'Traceback'); P = 'python probe exited 0 without a report' }
            )
            foreach ($c in $cases) {
                $got = @(Get-IreeRocmFinding -IreeBin $i.Bin -ScratchDir $i.Scratch -Invoke $c.Inv)
                Assert-Equal $(if ($c.Contains('Findings')) { $c['Findings'] } else { 1 }) $got.Count "$($c.N): finding count ($($got -join ' / '))"
                Assert-Match $c.P $got[0] $c.N
            }
        }
    }

    It 'flags an unpatched runtime, a missing device library and missing tools' {
        $vmfb = New-TestVmfb (New-TestElfHeader)
        $good = New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report $script:GoodReport
        $unpatched = New-FakeIreeInvoke -ListOutput $script:GoodList -Vmfb $vmfb -Report $script:GoodReport -Search 'legacy'
        Invoke-InTestDir {
            param($d)
            $i = New-FakeIreeInstall $d -Patched $false -BitcodeNames @('ocml.bc')
            $got = @(Get-IreeRocmFinding -IreeBin $i.Bin -ScratchDir $i.Scratch -Invoke $unpatched)
            Assert-Equal 3 $got.Count "three findings ($($got -join ' / '))"
            Assert-Match 'iree-run-module\.exe does not look for amdhip64_7\.dll' $got[0] 'dylib name'
            Assert-Match 'tried \[[^,\]]*\\amdhip64\.dll\], expected' $got[1] 'search path tries the legacy name only'
            Assert-Match 'ockl\.bc' $got[2] 'device library'
            $d2 = Join-Path $d 'second'
            $j = New-FakeIreeInstall $d2
            [System.IO.File]::Move((Join-Path $j.Bin 'iree-compile.exe'), (Join-Path $d2 'moved-away.exe'))
            $got = @(Get-IreeRocmFinding -IreeBin $j.Bin -ScratchDir $j.Scratch -Invoke $good)
            Assert-Equal 1 $got.Count 'missing tool stops the check'
            Assert-Match 'iree-compile\.exe missing' $got[0] 'missing tool'
        }
    }

    It 'probes the python wheels with the rocm backend and the patched name' {
        $probe = Get-IreeRocmPythonProbe
        Assert-Match 'target_backends=\["rocm"\], extra_args=\["--iree-rocm-target=" \+ sys\.argv\[1\]\]' $probe 'rocm compile'
        Assert-Match 'b"amdhip64_7\.dll"' $probe 'patched name'
        Assert-Match ([regex]::Escape((Get-IreeRocmGateMlir))) $probe 'same MLIR as the CLI check'
    }
}

Describe 'rocm-checks\TVM.ps1' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmCheck -FunctionName 'Get-TvmRocmSidecarFinding', 'Get-TvmRocmRuntimeFinding', 'Get-TvmRocmCodegenFinding', 'Get-TvmRocmCodegenProbe', 'ConvertFrom-TvmRocmProbeOutput', 'Get-TvmRocmRuntimeProbe', 'Get-TvmRocmMarkerFinding', 'Get-TvmRocmLlvmTargetFinding')

    It 'reads the last JSON report of a probe and names a probe that gave none' {
        $r = ConvertFrom-TvmRocmProbeOutput -Probe 'runtime' -ExitCode 0 -Lines @('Unable to detect ROCm version', '{"opencl": false}', '{"opencl": true, "rocm": true}')
        Assert-True ($r -is [hashtable] -and $r['opencl'] -and $r['rocm']) 'last report wins'
        Assert-Match 'the codegen probe exited 1 without a report: .*Traceback' (ConvertFrom-TvmRocmProbeOutput -Probe 'codegen' -ExitCode 1 -Lines @('{"size": 0}', 'Traceback')) 'non-zero exit'
        Assert-Match 'the runtime probe exited 0 without a report' (ConvertFrom-TvmRocmProbeOutput -Probe 'runtime' -ExitCode 0 -Lines @()) 'no report'
    }

    function New-FakeTvmLib([string]$Root, [string[]]$Dlls = @('tvm_runtime_opencl.dll', 'tvm_runtime_rocm.dll')) {
        $lib = Join-Path $Root 'lib'
        New-Item -ItemType Directory -Force -Path $lib | Out-Null
        foreach ($dll in $Dlls) { [System.IO.File]::WriteAllText((Join-Path $lib $dll), 'MZ') }
        return $lib
    }
    function New-FakeImports([string[]]$OpenCl = @('tvm_runtime.dll', 'KERNEL32.dll'), [string[]]$Rocm = @('tvm_runtime.dll', 'amdhip64_7.dll', 'KERNEL32.dll')) {
        return { param($p) if ((Split-Path $p -Leaf) -eq 'tvm_runtime_rocm.dll') { $Rocm } else { $OpenCl } }.GetNewClosure()
    }

    It 'passes the sidecars of a spike build and of an OpenCL-only build' {
        Invoke-InTestDir {
            param($d)
            $spike = New-FakeTvmLib (Join-Path $d 'spike')
            Assert-Equal '' (@(Get-TvmRocmSidecarFinding -LibDir $spike -Features @{ TVM_ROCM = '1' } -GetImports (New-FakeImports)) -join ' / ') 'spike'
            $openclOnly = New-FakeTvmLib (Join-Path $d 'opencl') @('tvm_runtime_opencl.dll')
            Assert-Equal '' (@(Get-TvmRocmSidecarFinding -LibDir $openclOnly -Features @{ TVM_ROCM = '0' } -GetImports (New-FakeImports)) -join ' / ') 'opencl only'
        }
    }

    It 'names each sidecar defect' {
        Invoke-InTestDir {
            param($d)
            $lib = New-FakeTvmLib $d
            $cases = @(
                @{ N = 'static OpenCL'; F = '1'; I = (New-FakeImports -OpenCl @('OpenCL.dll')); P = 'links OpenCL\.dll at load time' }
                @{ N = 'no HIP import'; F = '1'; I = (New-FakeImports -Rocm @('tvm_runtime.dll')); P = 'does not import amdhip64_7\.dll' }
                @{ N = 'HSA import'; F = '1'; I = (New-FakeImports -Rocm @('amdhip64_7.dll', 'hsa-runtime64.dll')); P = 'imports an HSA runtime' }
                @{ N = 'stale rocm sidecar'; F = '0'; I = (New-FakeImports); P = 'exists although the marker says TVM_ROCM=0' }
            )
            foreach ($c in $cases) {
                $got = @(Get-TvmRocmSidecarFinding -LibDir $lib -Features @{ TVM_ROCM = $c.F } -GetImports $c.I)
                Assert-Equal 1 $got.Count "$($c.N): one finding ($($got -join ' / '))"
                Assert-Match $c.P $got[0] $c.N
            }
            $empty = New-FakeTvmLib (Join-Path $d 'empty') @()
            $got = @(Get-TvmRocmSidecarFinding -LibDir $empty -Features @{ TVM_ROCM = '1' } -GetImports (New-FakeImports))
            Assert-Equal 2 $got.Count 'both sidecars missing'
        }
    }

    It 'expects the runtime flags the marker promises' {
        Assert-Equal 0 @(Get-TvmRocmRuntimeFinding -Report @{ opencl = $true; rocm = $true } -Features @{ TVM_ROCM = '1' }).Count 'spike'
        Assert-Equal 0 @(Get-TvmRocmRuntimeFinding -Report @{ opencl = $true; rocm = $false } -Features @{ TVM_ROCM = '0' }).Count 'opencl only'
        Assert-Match 'opencl"\) is False' "$(Get-TvmRocmRuntimeFinding -Report @{ opencl = $false; rocm = $false } -Features @{ TVM_ROCM = '0' })" 'opencl missing'
        Assert-Match 'rocm"\) is False but the marker says TVM_ROCM=1' "$(Get-TvmRocmRuntimeFinding -Report @{ opencl = $true; rocm = $false } -Features @{ TVM_ROCM = '1' })" 'rocm missing'
        Assert-Match 'rocm"\) is True but the marker says TVM_ROCM=0' "$(Get-TvmRocmRuntimeFinding -Report @{ opencl = $true; rocm = $true } -Features @{ TVM_ROCM = '0' })" 'rocm unexpected'
    }

    It 'wants AMDGPU in the marker''s LLVM_TARGETS for a spike build, and some targets always' {
        Assert-Equal 0 @(Get-TvmRocmMarkerFinding -Features @{ TVM_ROCM = '1'; LLVM_TARGETS = 'X86;AArch64;NVPTX;AMDGPU' }).Count 'spike'
        Assert-Equal 0 @(Get-TvmRocmMarkerFinding -Features @{ TVM_ROCM = '0'; LLVM_TARGETS = 'AArch64;X86' }).Count 'opencl only'
        Assert-Match 'TVM_ROCM=1 but LLVM_TARGETS=X86;amdgpu has no AMDGPU' "$(Get-TvmRocmMarkerFinding -Features @{ TVM_ROCM = '1'; LLVM_TARGETS = 'X86;amdgpu' })" 'case-sensitive'
        Assert-Match 'records no LLVM_TARGETS' "$(Get-TvmRocmMarkerFinding -Features @{ TVM_ROCM = '0' })" 'absent key'
    }

    It 'compares the marker with the LLVM arches tvm_compiler links, by LLVM 23''s names and the legacy amdgcn' {
        $spike = @{ TVM_ROCM = '1'; LLVM_TARGETS = 'X86;AArch64;NVPTX;AMDGPU' }
        Assert-Equal 0 @(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = $script:Llvm23Arches } -Features $spike).Count 'agree at LLVM 23.1.1'
        Assert-Equal 0 @(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = @($script:Llvm23Arches -replace '^amdgpu$', 'amdgcn') } -Features $spike).Count 'agree before the rename'
        $got = @(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = @('aarch64', 'x86_64') } -Features $spike)
        Assert-Equal 2 $got.Count "marker overstates NVPTX and AMDGPU ($($got -join ' / '))"
        Assert-Match "lists AMDGPU, but tvm_compiler has no amdgpu\|amdgcn target \(llvm_get_targets: aarch64, x86_64\)" $got[1] 'AMDGPU missing'
        Assert-Match 'omits NVPTX, but tvm_compiler links the nvptx64 target' "$(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = $script:Llvm23Arches } -Features @{ LLVM_TARGETS = 'X86;AArch64;AMDGPU' })" 'understated'
        Assert-Match 'registers no target\.llvm_get_targets' "$(Get-TvmRocmLlvmTargetFinding -Report @{ llvm_targets = $null } -Features $spike)" 'no LLVM'
        Assert-Match 'did not report llvm_targets' "$(Get-TvmRocmLlvmTargetFinding -Report @{ opencl = $true } -Features $spike)" 'old probe'
        Assert-Match 'get_global_func\("target\.llvm_get_targets", allow_missing=True\)' (Get-TvmRocmRuntimeProbe) 'the runtime probe asks the compiler'
    }

    It 'runs the marker and linked-target checks end to end, python answering each probe from <probe>.json' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:TvmScript -FunctionName 'Get-TvmRocmPlan', 'Get-TvmRocmFeatureMarker')
        $hsaco = '{"size": 4096, "magic": true, "elf_class": 2, "type": 3, "machine": 224, "mach": 78}'
        $noSidecars = @('tvm_runtime_opencl\.dll missing', 'tvm_runtime_rocm\.dll missing although')
        foreach ($case in @(
                @{ N = 'healthy'; Targets = 'X86;AArch64;NVPTX;AMDGPU'; Linked = $script:Llvm23Arches; Marker = @(); Link = @() }
                @{ N = 'requested list'; Targets = 'X86;AArch64;NVPTX;AMDGPU'; Linked = @('aarch64', 'x86_64'); Marker = @(); Link = @('lists NVPTX, but', 'lists AMDGPU, but') }
                @{ N = 'no AMDGPU'; Targets = 'AArch64;X86'; Linked = @('aarch64', 'x86_64'); Marker = @('LLVM_TARGETS=AArch64;X86 has no AMDGPU'); Link = @() })) {
            Invoke-InTestDir {
                param($d)
                Set-Content -Path (Join-Path $d 'ROCM-FEATURES.txt') -Encoding ascii -Value (Get-TvmRocmFeatureMarker -Plan (Get-TvmRocmPlan -GpuEnv $script:RocmEnv -Cross $false -SpikeFlag '1') -LlvmTargets $case.Targets)
                [System.IO.File]::WriteAllText((Join-Path $d 'python.cmd'), "@type ""%~dp0%~n1.json""`r`n")
                [System.IO.File]::WriteAllText((Join-Path $d 'tvm_rocm_runtime.json'), (@{ opencl = $true; rocm = $true; llvm_targets = $case.Linked } | ConvertTo-Json -Compress))
                [System.IO.File]::WriteAllText((Join-Path $d 'tvm_rocm_codegen.json'), $hsaco)
                $out = @(Invoke-WithEnv @{ PATH = $d; TVM_ROOT = $d; TVM_LIBRARY_PATH = $null; HIP_PATH = $null } { & (Join-Path (Get-RepoRoot) $script:TvmCheck) 6>$null })
                # One line per finding, in the check's order: the marker, the sidecars, the linked targets.
                $want = '^' + ((@($case.Marker) + $noSidecars + @($case.Link) | ForEach-Object { "TVM: [^\n]*$_[^\n]*" }) -join '\n') + '$'
                Assert-Match $want ($out -join "`n") $case.N
            }
        }
    }

    It 'accepts only a linked ELF64 AMDGPU hsaco for gfx1201' {
        $good = @{ size = 4096; magic = $true; elf_class = 2; type = 3; machine = 224; mach = 78 }
        Assert-Equal 0 @(Get-TvmRocmCodegenFinding -Report $good).Count 'good'
        foreach ($bad in @(@{ K = 'mach'; V = 72 }, @{ K = 'type'; V = 1 }, @{ K = 'machine'; V = 62 }, @{ K = 'elf_class'; V = 1 }, @{ K = 'magic'; V = $false })) {
            $r = $good.Clone(); $r[$bad.K] = $bad.V
            Assert-Match 'not a linked ELF64 AMDGPU object for mach 0x4E' "$(Get-TvmRocmCodegenFinding -Report $r)" $bad.K
        }
        Assert-Match 'produced no hsaco' "$(Get-TvmRocmCodegenFinding -Report @{ size = 0 })" 'no link'
        Assert-Match 'compile failed: ValueError: x' "$(Get-TvmRocmCodegenFinding -Report @{ error = 'ValueError: x'; size = 0 })" 'error'
    }

    It 'compiles for an explicit mcpu (no rocminfo on Windows) and captures the real link' {
        $probe = Get-TvmRocmCodegenProbe
        Assert-Match '"kind": "rocm", "mcpu": sys\.argv\[1\]' $probe 'explicit mcpu'
        Assert-Match 'get_global_func\("tvm_callback_rocm_link"\)' $probe 'wraps the registered link'
        Assert-Match 'from tvm\.script import tirx as T' $probe 'TVMScript of the pinned commit'
    }
}

Describe 'rocm-checks: IREE.ps1 and TVM.ps1 follow the check contract' {
    It 'declare pwsh 7 and take no parameters' {
        foreach ($rel in $script:IreeCheck, $script:TvmCheck) {
            $path = Join-Path (Get-RepoRoot) $rel
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            Assert-Match '(?m)^#requires -Version 7\.0' (Get-Content -Raw $path) "$rel requires"
            Assert-Null $ast.ParamBlock "$rel has no param block"
        }
    }
}

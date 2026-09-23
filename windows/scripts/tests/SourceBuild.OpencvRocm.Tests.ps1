#requires -Version 7.0
# OpenCV rocm lane: the CMake delta (empty on cpu/nvidia), the configure gate, their wiring, rocm-checks/OpenCV.ps1.
# NOT covered: a real configure/build, the real cv2, any GPU, a ROCm path in neither the configure log nor CMakeCache.txt.

$script:OcvScript = 'windows\scripts\build\Build-OpencvFromSource.ps1'
$script:OcvCheck = 'windows\scripts\build\rocm-checks\OpenCV.ps1'

# The OpenCL/Vulkan part of a real 5.0.0 summary (rebuild-push-amd64-20260922), in getBuildInformation() form.
$script:OcvBuildInfo = @'
General configuration for OpenCV 5.0.0 =====================================
  Version control:               5.0.0-dirty

  Vulkan:                        YES
    Include path:                C:/temp/opencv-src/opencv/3rdparty/include
    Link libraries:              Dynamic load

  OpenCL:                        YES (SVM NVD3D11)
    Include path:                C:/temp/opencv-src/opencv/3rdparty/include/opencl/1.2
    Link libraries:              Dynamic load

  ONNX Runtime:                  YES (ver 1.25.1)
    Include path:                C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/include
    Link libraries:              C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/lib/onnxruntime.lib

  Install to:                    C:/runtime/lib/opencv5
-----------------------------------------------------------------
'@
# The same summary as opencv-configure.log carries it: '-- ' prefixed, then the trailing 'True'.
$script:OcvConfigureLog = ((($script:OcvBuildInfo -split '\r?\n') | ForEach-Object { "-- $_" }) -join "`n") +
    "`n-- Configuring done (76.4s)`n-- Generating done (0.6s)`nTrue"
# Mutations of the summary: the T-API off, and OpenCL's own Link libraries line dropped.
$script:OcvBuildInfoOff = $script:OcvBuildInfo -replace 'OpenCL:(\s+)YES \(SVM NVD3D11\)', 'OpenCL:$1NO'
$script:OcvBuildInfoNoLink = $script:OcvBuildInfo -replace '(?m)(opencl/1\.2)\r?\n\s+Link libraries:\s+Dynamic load', '$1'
$script:RocmRoot = 'C:\TheRock\build'
# A healthy rocm-lane CMakeCache.txt excerpt; its only ROCm path is Invoke-CmakeConfigure's isolation arg.
$script:OcvCMakeCache = @'
# This is the CMakeCache file.
# For build in directory: c:/temp/opencv-src/build
########################
# EXTERNAL cache entries
########################

//Path to a program.
CMAKE_AR:FILEPATH=C:/llvm/bin/llvm-lib.exe
//No help, variable specified on the command line.
CMAKE_IGNORE_PREFIX_PATH:UNINITIALIZED=C:/TheRock/build
//The directory containing a CMake configuration file for Eigen3.
Eigen3_DIR:PATH=Eigen3_DIR-NOTFOUND
//OpenCL include directory
OPENCL_INCLUDE_DIR:PATH=C:/temp/opencv-src/opencv/3rdparty/include/opencl/1.2
//OpenCL library
OPENCL_LIBRARY:STRING=
//Include AMD OpenCL BLAS library support
WITH_OPENCLAMDBLAS:BOOL=OFF
'@
# A leak in the shape getBuildInformation() really prints (CMakeLists.txt: "YES (${LAPACK_IMPL} ${LAPACK_LIBRARIES})").
$script:OcvLapackLeak = '    Lapack:                      YES (OpenBLAS C:/TheRock/build/lib/host-math/lib/openblas.lib)'

Describe 'OpenCV rocm lane: CMake delta' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OcvScript -FunctionName 'Get-OpencvRocmCmakeArgs')

    It 'adds nothing on the cpu and nvidia lanes, native or cross' {
        foreach ($gpu in @(
                @{ GpuType = 'cpu'; HasCuda = $false; HasRocm = $false; RocmRoot = $null }
                @{ GpuType = 'nvidia'; HasCuda = $true; HasRocm = $false; CudaRoot = 'C:\cuda' })) {
            foreach ($cross in $false, $true) {
                Assert-Equal 0 @(Get-OpencvRocmCmakeArgs -GpuEnv $gpu -Cross $cross).Count "$($gpu.GpuType) cross=$cross"
            }
        }
    }

    It 'adds nothing for a GPU hashtable that predates HasRocm' {
        Assert-Equal 0 @(Get-OpencvRocmCmakeArgs -GpuEnv @{ GpuType = 'cpu'; HasCuda = $false } -Cross $false).Count 'legacy shape'
    }

    $rocmGpu = @{ GpuType = 'rocm'; HasCuda = $false; HasRocm = $true; RocmRoot = $script:RocmRoot }

    It 'pins exactly the dormant clBLAS/clFFT probes OFF on the rocm lane' {
        Assert-Equal '-DWITH_OPENCLAMDFFT=OFF|-DWITH_OPENCLAMDBLAS=OFF' (@(Get-OpencvRocmCmakeArgs -GpuEnv $rocmGpu -Cross $false) -join '|')
    }

    It 'refuses a rocm cross build instead of silently building the CPU flags' {
        Assert-Throws { Get-OpencvRocmCmakeArgs -GpuEnv $rocmGpu -Cross $true } 'rocm + cross' -MessagePattern 'amd64-only'
    }

    It 'follows the real Get-GpuEnvironment: empty without GPU_TYPE, the pin with a ROCm tree' {
        Invoke-WithEnv @{ GPU_TYPE = $null; HIP_PATH = $null; ROCM_PATH = $null } {
            Assert-Equal 0 @(Get-OpencvRocmCmakeArgs -GpuEnv (Get-GpuEnvironment) -Cross $false).Count 'no GPU_TYPE'
        }
        Invoke-InTestDir { param($tree)
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($tree, 'lib', 'cmake', 'hip'))
            Invoke-WithEnv @{ ROCM_PATH = $tree; HIP_PATH = $tree; GPU_TYPE = 'rocm' } {
                $gpu = Get-GpuEnvironment
                Assert-True $gpu.HasRocm 'Get-GpuEnvironment reports rocm'
                Assert-Equal 2 @(Get-OpencvRocmCmakeArgs -GpuEnv $gpu -Cross $false).Count 'rocm pin'
            }
        }
    }
}

Describe 'OpenCV rocm lane: configure gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OcvScript -FunctionName 'Get-OpencvRocmConfigureFinding')
    $gateOf = { param([string]$Log, [string]$Cache = $script:OcvCMakeCache, [string]$Root = $script:RocmRoot)
        @(Get-OpencvRocmConfigureFinding -ConfigureLog $Log -CMakeCache $Cache -RocmRoot $Root) }

    It 'passes the real summary shape and a cache whose only ROCm path is the isolation arg' {
        Assert-Equal 0 @(& $gateOf $script:OcvConfigureLog).Count
    }

    It 'passes a BuildKit-interleaved OpenCL line' {
        Assert-Equal 0 @(& $gateOf ($script:OcvConfigureLog -replace '--   OpenCL:', '-- --   OpenCL:')).Count
    }

    It 'fails when the T-API is off or the summary is missing' {
        $off = $script:OcvConfigureLog -replace 'OpenCL:(\s+)YES \(SVM NVD3D11\)', 'OpenCL:$1NO'
        Assert-Match 'OpenCL: YES' (@(& $gateOf $off) -join ';')
        Assert-Match 'OpenCL: YES' (@(& $gateOf '') -join ';')
    }

    It 'fails on any printed line that resolves into the ROCm tree, in either slash form and any case' {
        foreach ($leak in @('--     Include path:                C:/TheRock/build/include',
                '-- Found ZLIB: c:\therock\BUILD\lib\rocm_sysdeps\lib\zlib.lib',
                'CMake Warning at C:/TheRock/build/lib/cmake/flatbuffers/flatbuffers-config.cmake:1')) {
            $found = @(& $gateOf "$script:OcvConfigureLog`n$leak")
            Assert-Equal 1 $found.Count "leak '$leak'"
            Assert-Match 'configure line resolves into the ROCm tree' $found[0]
        }
    }

    It 'fails on a silent cache hit into the ROCm tree, exempting only CMAKE_IGNORE_PREFIX_PATH' {
        # QUIET find_package/find_path results print nothing; the cache is where they land.
        foreach ($leak in @('flatbuffers_DIR:PATH=C:/TheRock/build/lib/cmake/flatbuffers',
                'FFMPEG_STATIC_LIBRARY_DIRS:INTERNAL=c:\therock\BUILD\lib',
                'CMAKE_AR:FILEPATH=C:/TheRock/build/lib/llvm/bin/llvm-lib.exe')) {
            $found = @(& $gateOf $script:OcvConfigureLog "$script:OcvCMakeCache`n$leak")
            Assert-Equal 1 $found.Count "cache leak '$leak'"
            Assert-Match 'cache entry resolves into the ROCm tree' $found[0]
        }
    }

    It 'fails closed on a missing or entry-less CMakeCache.txt' {
        foreach ($cache in '', "# This is the CMakeCache file.`n//Path to a program.`n") {
            Assert-Match 'CMakeCache\.txt is missing' (@(& $gateOf $script:OcvConfigureLog $cache) -join ';') "cache of $($cache.Length) chars"
        }
    }

    It 'accepts a root with a trailing separator' {
        $log = "$script:OcvConfigureLog`n--     Link libraries:              C:/TheRock/build/lib/amdocl64.lib"
        Assert-Equal 1 @(& $gateOf $log $script:OcvCMakeCache 'C:\TheRock\build\').Count
    }
}

Describe 'OpenCV rocm lane: wiring in Build-OpencvFromSource.ps1' {
    $L = 'System.Management.Automation.Language'
    $tree = [System.Management.Automation.Language.Parser]::ParseInput([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:OcvScript)), [ref]$null, [ref]$null)
    $all = @($tree.FindAll({ $true }, $true))
    $cmakeEdits = @($all | Where-Object { $_ -is [type]"$L.AssignmentStatementAst" -and $_.Left.Extent.Text -eq '$cmakeExtra' })
    $callsTo = { param([string]$Name) @($all | Where-Object { $_ -is [type]"$L.CommandAst" -and $_.GetCommandName() -eq $Name }) }
    # The nearest enclosing if/elseif whose condition matches $Pattern, else $null.
    $enclosingIf = {
        param($node, [string]$Pattern)
        $up = $node.Parent
        while ($up -and -not ($up -is [type]"$L.IfStatementAst" -and ($up.Clauses.Item1.Extent.Text -match $Pattern))) { $up = $up.Parent }
        $up
    }
    $guardedBy = { param($node, [string]$Pattern) $null -ne (& $enclosingIf $node $Pattern) }
    $ifsOn = { param([string]$Condition) @($all | Where-Object { $_ -is [type]"$L.IfStatementAst" -and $_.Clauses[0].Item1.Extent.Text -eq $Condition }) }
    # Asserts $Var is assigned exactly once, from a value that contains $Node; returns that assignment.
    $assertHolds = {
        param([string]$Var, $Node)
        $assign = @($all | Where-Object { $_ -is [type]"$L.AssignmentStatementAst" -and $_.Left.Extent.Text -eq $Var })
        Assert-Equal 1 $assign.Count "one $Var assignment"
        $right = $assign[0].Right.Extent
        Assert-True ($Node.Extent.StartOffset -ge $right.StartOffset -and $Node.Extent.EndOffset -le $right.EndOffset) "$Var holds $($Node.Extent.Text)"
        $assign[0]
    }
    # Parameter name -> argument source text, through PowerShell's own binder.
    $argsOf = {
        param($cmd)
        $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($cmd, $false).BoundParameters
        $map = @{}
        foreach ($name in $bound.Keys) { $map[$name] = $bound[$name].Value.Extent.Text }
        $map
    }

    It 'keeps WITH_OPENCL/WITH_OPENCL_SVM ON in the every-lane array (the rocm lane relies on it)' {
        $init = @($cmakeEdits | Where-Object { $_.Operator -eq 'Equals' })
        Assert-Equal 1 $init.Count 'one $cmakeExtra initializer'
        Assert-Match "'-DWITH_OPENCL=ON'" $init[0].Right.Extent.Text
        Assert-Match "'-DWITH_OPENCL_SVM=ON'" $init[0].Right.Extent.Text
    }

    It 'appends no CMake arg under a HasRocm condition (the delta goes through the tested function)' {
        $gated = @($cmakeEdits | Where-Object { & $guardedBy $_ 'HasRocm' })
        Assert-Equal 0 $gated.Count "rocm-gated `$cmakeExtra edits: $(($gated | ForEach-Object { $_.Extent.Text }) -join '; ')"
        Assert-Equal 1 @(& $callsTo 'Get-OpencvRocmCmakeArgs').Count 'one call site'
    }

    It 'feeds the delta the lane''s own Get-GpuEnvironment and cross flag, and appends its result' {
        $gpuAssign = & $assertHolds '$gpuEnv' @(& $callsTo 'Get-GpuEnvironment')[0]
        Assert-Equal 'Get-GpuEnvironment' $gpuAssign.Right.Extent.Text '$gpuEnv is the bare probe'
        $call = @(& $callsTo 'Get-OpencvRocmCmakeArgs')[0]
        $bound = & $argsOf $call
        Assert-Equal '$gpuEnv' $bound['GpuEnv'] '-GpuEnv binding'
        Assert-Equal '$ocvCross' $bound['Cross'] '-Cross binding'
        $null = & $assertHolds '$ocvRocmArgs' $call
        Assert-Equal 1 @($cmakeEdits | Where-Object { $_.Operator -eq 'PlusEquals' -and $_.Right.Extent.Text -eq '$ocvRocmArgs' }).Count '$cmakeExtra += $ocvRocmArgs'
    }

    It 'still gives the CPU arm exactly -DWITH_CUDA=OFF' {
        $cudaIf = @(& $ifsOn '$ocvCudaUsable')
        Assert-Equal 1 $cudaIf.Count 'the CUDA if'
        $else = $cudaIf[0].ElseClause.Extent
        $inElse = @($cmakeEdits | Where-Object { $_.Extent.StartOffset -ge $else.StartOffset -and $_.Extent.EndOffset -le $else.EndOffset })
        Assert-Equal "'-DWITH_CUDA=OFF'" (($inElse | ForEach-Object { $_.Right.Extent.Text }) -join ',')
    }

    It 'runs the configure gate only on the rocm lane, after configure' {
        $gate = @(& $callsTo 'Get-OpencvRocmConfigureFinding')
        Assert-Equal 1 $gate.Count 'one gate call'
        Assert-True (& $guardedBy $gate[0] '^\$gpuEnv\.HasRocm$') 'gate sits under if ($gpuEnv.HasRocm)'
        Assert-True ($gate[0].Extent.StartOffset -gt @(& $callsTo 'Invoke-CmakeConfigure')[0].Extent.StartOffset) 'gate reads the log configure wrote'
        $bound = & $argsOf $gate[0]
        Assert-Equal '$gpuEnv.RocmRoot' $bound['RocmRoot'] '-RocmRoot binding'
        Assert-Match '^"\$\(Get-Content -LiteralPath \$cfgLog -Raw\)"$' $bound['ConfigureLog'] '-ConfigureLog reads the teed log'
        Assert-Match 'Join-Path \$buildDir ''CMakeCache\.txt''' $bound['CMakeCache'] '-CMakeCache reads the build tree''s cache'
    }

    It 'throws on any gate finding (fails closed, never only logs)' {
        $gate = @(& $callsTo 'Get-OpencvRocmConfigureFinding')[0]
        $null = & $assertHolds '$ocvRocmCfg' $gate
        $rocmIf = & $enclosingIf $gate '^\$gpuEnv\.HasRocm$'
        Assert-True ($null -ne $rocmIf) 'the enclosing if ($gpuEnv.HasRocm)'
        $check = @(& $ifsOn '$ocvRocmCfg.Count -gt 0')
        Assert-Equal 1 $check.Count 'one if ($ocvRocmCfg.Count -gt 0)'
        Assert-True ([object]::ReferenceEquals($check[0].Parent, $rocmIf.Clauses[0].Item2)) 'it sits directly in the rocm block'
        Assert-Equal 1 $check[0].Clauses.Count 'no elseif arm'
        Assert-Null $check[0].ElseClause 'no else arm'
        Assert-Equal 1 @($check[0].Clauses[0].Item2.Statements | Where-Object { $_ -is [type]"$L.ThrowStatementAst" }).Count 'a direct throw'
    }
}

Describe 'rocm-checks/OpenCV.ps1: build information' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OcvCheck -FunctionName 'Get-OcvRocmBuildInfoFinding')
    $findingsOf = { param([string]$Text, [string]$Root = '') @(Get-OcvRocmBuildInfoFinding -BuildInformation $Text -RocmRoot $Root) }

    It 'passes the real shape' {
        Assert-Equal 0 @(& $findingsOf $script:OcvBuildInfo $script:RocmRoot).Count
    }

    It 'fails when OpenCL is NO or absent' {
        foreach ($text in $script:OcvBuildInfoOff, '') { Assert-Match 'OpenCL: YES' (@(& $findingsOf $text) -join ';') "text '$($text.Length) chars'" }
    }

    It 'fails an OpenCL import library, and flags its ROCm path too' {
        $bound = $script:OcvBuildInfo -replace '(?m)(opencl/1\.2\r?\n\s+Link libraries:\s+)Dynamic load', '$1C:/TheRock/build/lib/amdocl64.lib'
        $found = @(& $findingsOf $bound $script:RocmRoot)
        Assert-Equal 2 $found.Count ($found -join ';')
        Assert-Match "instead of 'Dynamic load'" $found[0]
        Assert-Match 'points into the ROCm tree' $found[1]
    }

    It 'reads Link libraries from the OpenCL block only, never a neighbouring block' {
        # Vulkan's Dynamic load sits above OpenCL; the second text adds one below it.
        $below = "$script:OcvBuildInfoNoLink`n  Later:                         YES`n    Link libraries:              Dynamic load"
        foreach ($text in $script:OcvBuildInfoNoLink, $below) { Assert-Match "instead of 'Dynamic load'" (@(& $findingsOf $text) -join ';') }
    }

    It 'scans for the ROCm tree only when a root is known' {
        $leak = "$script:OcvBuildInfo`n$script:OcvLapackLeak"
        Assert-Equal 1 @(& $findingsOf $leak $script:RocmRoot).Count 'root known'
        Assert-Equal 0 @(& $findingsOf $leak).Count 'no root'
    }
}

Describe 'rocm-checks/OpenCV.ps1: OpenCL loader probe' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OcvCheck -FunctionName 'Get-OcvRocmOpenClLoaderFinding')

    It 'passes a loaded 1.1+ loader' {
        Assert-Null (Get-OcvRocmOpenClLoaderFinding -ExitCode 0 -Output 'opencl-loader|C:\TheRock\build\bin\OpenCL.dll|True')
    }

    It 'fails a load error, naming the tail of the output' {
        $f = Get-OcvRocmOpenClLoaderFinding -ExitCode 1 -Output "Traceback (most recent call last):`nOSError: [WinError 126] The specified module could not be found"
        Assert-Match 'no OpenCL.dll loads.*WinError 126' $f
        Assert-Match 'exit -1073741819' (Get-OcvRocmOpenClLoaderFinding -ExitCode -1073741819 -Output 'opencl-loader|C:\x\OpenCL.dll|True') 'crash after the load'
    }

    It 'fails a clean exit with no marker, and a pre-1.1 loader' {
        Assert-Match 'no OpenCL.dll loads' (Get-OcvRocmOpenClLoaderFinding -ExitCode 0 -Output '')
        Assert-Match 'lacks clEnqueueReadBufferRect' (Get-OcvRocmOpenClLoaderFinding -ExitCode 0 -Output 'opencl-loader|C:\x\OpenCL.dll|False')
        Assert-Match 'lacks clEnqueueReadBufferRect' (Get-OcvRocmOpenClLoaderFinding -ExitCode 0 -Output 'opencl-loader|')
    }
}

Describe 'rocm-checks/OpenCV.ps1: end to end against a fake python' {
    $checkPath = Join-Path (Get-RepoRoot) $script:OcvCheck
    $pwshExe = (Get-Process -Id $PID).Path
    # The fake answers each of the check's three python calls from files beside it.
    $newFakePython = {
        param([string]$Dir, [string]$BuildInfo, [int]$BuildExit, [string]$Loader, [int]$LoaderExit)
        Set-Content -LiteralPath (Join-Path $Dir 'python.cmd') -Encoding ASCII -Value @(
            '@echo off', "`"$pwshExe`" -NoProfile -File `"%~dp0fake.ps1`" %*", 'exit /b %ERRORLEVEL%')
        Set-Content -LiteralPath (Join-Path $Dir 'fake.ps1') -Encoding UTF8 -Value @'
$kind = switch -Regex ("$($args[1])") { 'getBuildInformation' { 'build'; break } 'OpenCL\.dll' { 'loader'; break } default { 'ocl' } }
if ($kind -eq 'ocl') { 'ocl|False|no platform'; exit 0 }
Get-Content -LiteralPath (Join-Path $PSScriptRoot "$kind.txt")
exit [int](Get-Content -LiteralPath (Join-Path $PSScriptRoot "$kind.exit"))
'@
        @{ 'build.txt' = $BuildInfo; 'build.exit' = $BuildExit; 'loader.txt' = $Loader; 'loader.exit' = $LoaderExit }.GetEnumerator() |
            ForEach-Object { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Dir, $_.Key), "$($_.Value)") }
    }

    It 'emits exactly one string per defect, and nothing on a healthy image' {
        $healthy = 'opencl-loader|C:\TheRock\build\bin\OpenCL.dll|True'
        $broken = "$script:OcvBuildInfoOff`n$script:OcvLapackLeak"
        $cases = @(
            @{ Name = 'healthy'; Info = $script:OcvBuildInfo; InfoExit = 0; Loader = $healthy; LoaderExit = 0; Expect = @() }
            @{ Name = 'three defects'; Info = $broken; InfoExit = 0; Loader = 'OSError: [WinError 126] module not found'; LoaderExit = 1
                Expect = @('OpenCL: YES', 'points into the ROCm tree', 'WinError 126') }
            @{ Name = 'cv2 import fails'; Info = 'ImportError: DLL load failed while importing cv2'; InfoExit = 1; Loader = $healthy; LoaderExit = 0
                Expect = @('import cv2 failed \(exit 1\).*DLL load failed') }
        )
        foreach ($case in $cases) {
            Invoke-InTestDir { param($dir)
                & $newFakePython $dir $case.Info $case.InfoExit $case.Loader $case.LoaderExit
                $out = @(Invoke-WithEnv @{ PATH = $dir; ROCM_PATH = $script:RocmRoot; HIP_PATH = $null } { & $checkPath 6>$null })
                Assert-Equal $case.Expect.Count $out.Count "$($case.Name): $($out -join ' / ')"
                $next = 0
                foreach ($finding in $out) {
                    Assert-True ($finding -is [string]) "$($case.Name): a finding that is not a string"
                    Assert-Match $case.Expect[$next++] $finding $case.Name
                }
            }
        }
    }

    It 'reports a missing python instead of passing' {
        Invoke-InTestDir { param($dir)
            $out = @(Invoke-WithEnv @{ PATH = $dir } { & $checkPath 6>$null })
            Assert-Equal 'OpenCV: python is not on PATH - cv2 cannot be checked' ($out -join ' / ')
        }
    }
}

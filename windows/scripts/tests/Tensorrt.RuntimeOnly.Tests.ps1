#requires -Version 7.0
# Owner 2026-10-21: the Windows image ships only TensorRT's runtime DLLs; the SDK serves the ORT build through a mount.

Import-Module (Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'modules\WindowsSmokeTest.Common.psm1') -Force

# A TensorRT 11 zip tree after Set-TensorrtTree.ps1, one file per kind the SDK carries; -Drop leaves one out.
$script:trtTree = @(
    'bin\nvinfer_11.dll', 'bin\nvinfer_plugin_11.dll', 'bin\nvonnxparser_11.dll', 'bin\nvinfer_builder_resource_sm75_11.dll',
    'bin\nvinfer_builder_resource_sm120_11.dll', 'bin\nvinfer_lean_11.dll', 'bin\nvinfer_dispatch_11.dll', 'bin\nvinfer_vc_plugin_11.dll',
    'bin\trtexec.exe', 'lib\nvinfer_11.lib', 'lib\nvonnxparser_11.lib', 'include\NvInfer.h', 'include\NvOnnxParser.h',
    'python\tensorrt-11.4.0.106-cp315-none-win_amd64.whl', 'samples\sampleOnnxMNIST\sampleOnnxMNIST.cpp',
    'doc\TensorRT-SLA.pdf', 'doc\Acknowledgements.txt', 'doc\TensorRT-Release-Notes.pdf')

# <work dir> [-Drop <relative path>]: stages the tree under sdk\current, runs Copy-TensorrtRuntime.ps1 into rt\.
function Invoke-TrtRuntimeCopy {
    param([Parameter(Mandatory)][string]$Work, [string]$Drop = '', [switch]$Empty)
    $sdk = Join-Path $Work 'sdk'
    $null = New-Item -ItemType Directory -Force -Path $sdk
    if (-not $Empty) {
        $script:trtTree | Where-Object { $_ -ne $Drop } |
            ForEach-Object { $null = New-Item -ItemType File -Force -Path (Join-Path $sdk "current\$_") -Value $_ }
    }
    $copy = Join-Path (Get-RepoRoot) 'windows\scripts\build\Copy-TensorrtRuntime.ps1'
    & $copy -SdkRoot $sdk -Destination (Join-Path $Work 'rt') | Out-Null
}

# <dir>: the file names under it, sorted and comma-joined.
function Get-TrtNameList([string]$Dir) {
    return (@(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object) -join ',')
}

Describe 'Copy-TensorrtRuntime.ps1' {

    It 'ships the four DLL kinds ORT''s TensorRT EP loads and the licence texts, nothing else' {
        Invoke-InTestDir { param($dir)
            Invoke-TrtRuntimeCopy -Work $dir
            Assert-Equal 'nvinfer_11.dll,nvinfer_builder_resource_sm120_11.dll,nvinfer_builder_resource_sm75_11.dll,nvinfer_plugin_11.dll,nvonnxparser_11.dll' `
                (Get-TrtNameList (Join-Path $dir 'rt\current\bin')) 'no lean, dispatch, vc_plugin or trtexec'
            Assert-Equal 'Acknowledgements.txt,TensorRT-SLA.pdf' (Get-TrtNameList (Join-Path $dir 'rt\current\licenses')) 'the notices, not the release notes'
            Assert-Equal 0 @(Get-TensorRtShipViolation -Root (Join-Path $dir 'rt')).Count 'the subset passes the smoke gate'
        }
    }

    It 'writes an empty destination for a zip-less lane, and refuses a tree without a DLL the EP loads' {
        Invoke-InTestDir { param($dir)
            Invoke-TrtRuntimeCopy -Work $dir -Empty
            Assert-True (Test-Path -LiteralPath (Join-Path $dir 'rt')) 'the COPY source exists'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $dir 'rt') -Recurse -Force).Count 'and stays empty'
        }
        Invoke-InTestDir { param($dir)
            Assert-Throws { Invoke-TrtRuntimeCopy -Work $dir -Drop 'bin\nvinfer_plugin_11.dll' } 'nvinfer_plugin is LoadLibrary()d by the EP' -MessagePattern 'nvinfer_plugin_11'
        }
    }
}

Describe 'Get-TensorRtShipViolation' {

    It 'names every SDK file under the shipped root: header, import lib, trtexec, wheel, sample' {
        Invoke-InTestDir { param($dir)
            Invoke-TrtRuntimeCopy -Work $dir
            $bad = @(Get-TensorRtShipViolation -Root (Join-Path $dir 'sdk'))
            foreach ($f in 'include\NvInfer.h', 'lib\nvinfer_11.lib', 'bin\trtexec.exe', 'python\tensorrt-11.4.0.106-cp315-none-win_amd64.whl',
                'samples\sampleOnnxMNIST\sampleOnnxMNIST.cpp') {
                Assert-True ($bad -contains "current\$f") "$f is reported"
            }
            Assert-False ($bad -contains 'current\bin\nvinfer_11.dll') 'a runtime DLL is not'
        }
    }

    It 'passes an unset, missing or empty root (the CPU and zip-less images)' {
        Invoke-WithEnv @{ TENSORRT_ROOT = '' } { Assert-Equal 0 @(Get-TensorRtShipViolation).Count 'unset' }
        Assert-Equal 0 @(Get-TensorRtShipViolation -Root (Join-Path $env:TEMP 'no-such-trt-root-xyzzy')).Count 'missing'
        Invoke-InTestDir { param($dir) Assert-Equal 0 @(Get-TensorRtShipViolation -Root $dir).Count 'empty' }
    }
}

Describe 'Get-TensorRtEpGap' {

    It 'is empty for the subset, and names an import, the LoadLibrary()d plugin and the builder resources when missing' {
        Invoke-InTestDir { param($dir)
            Invoke-TrtRuntimeCopy -Work $dir
            $bin = Join-Path $dir 'rt\current\bin'
            Assert-Equal 0 @(Get-TensorRtEpGap -EpImports @('KERNEL32.dll', 'nvinfer_11.dll', 'nvonnxparser_11.dll', 'cudart64_13.dll') -BinDir $bin).Count 'complete'
            $lib = Join-Path $dir 'sdk\current\lib'
            Assert-Equal 'nvinfer_11.dll,nvonnxparser_11.dll,nvinfer_plugin_11.dll,nvinfer_builder_resource*_11.dll' `
                (@(Get-TensorRtEpGap -EpImports @('nvinfer_11.dll', 'nvonnxparser_11.dll') -BinDir $lib) -join ',') 'import libraries are no runtime'
            Assert-Equal 1 @(Get-TensorRtEpGap -EpImports @('KERNEL32.dll') -BinDir $bin).Count 'an EP without an nvinfer import is a gap too'
        }
    }
}

Describe 'TensorRT SDK stays in the build stages' {

    It 'the sdk image takes the subset, the ORT build mounts the tagged SDK, and the smoke gates both' {
        $read = { param($rel) [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $rel)) }
        $nvidia = & $read 'windows\Dockerfile.nvidia'
        Assert-Match '(?m)^COPY --from=trt-extract C:\\tensorrt-runtime C:\\tensorrt\r?$' $nvidia 'the subset'
        Assert-False ($nvidia -match '(?m)^COPY --from=trt-extract C:\\tensorrt C:\\tensorrt') 'never the extracted SDK'
        Assert-Match '-SdkRoot .C:\\tensorrt. -Destination .C:\\tensorrt-runtime.' $nvidia 'built in trt-extract'
        Assert-Match 'from=trt-sdk,source=/tensorrt,target=C:\\tensorrt-sdk[\s\S]+TENSORRT_SDK_ROOT = .C:\\tensorrt-sdk.' (& $read 'windows\Dockerfile.media-builder') 'the ORT RUN mounts it'
        Assert-Match "trt-extract' -Tag \(Get-BkTag 'windows-tensorrt-sdk'\)[\s\S]+TENSORRT_SDK_IMAGE = Get-BkTag 'windows-tensorrt-sdk'" (& $read 'windows\Build-Buildkit.ps1') 'tagged and handed over'
        Assert-Match 'Get-TensorRtShipViolation\)[\s\S]+Get-TensorRtEpGap -EpImports @\(Get-PeImportNames' (& $read 'windows\scripts\build\Test-Container.ps1') 'the smoke gates both'
    }
}

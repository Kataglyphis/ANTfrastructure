#requires -Version 7.0
# Local trees cover staging and patch-set execution; they do not compile upstream projects or exercise network acquisition.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.PatchFixture.psm1') -ErrorAction Stop
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking

Describe 'Shared source file-set operations' {
    It 'executes both installed-tree callers with their original filters and destination roots' {
        Invoke-InTestDir -Files @{ 'tflite/root.h' = 'root'; 'tflite/nested/api.h' = 'api'; 'tflite/source.cc' = 'exclude'; 'clone/support/a.cc' = 'impl'; 'clone/support/nested/b.h' = 'declaration'; 'clone/support/a_test.cc' = 'test'; 'clone/support/testdata/hidden.h' = 'testdata'; 'clone/support/BUILD' = 'metadata' } -Body { param($dir)
            $tfliteSrc = Join-Path $dir tflite
            $includeRoot = Join-Path $dir headers
            $supportClone = Join-Path $dir clone
            $dstSupport = Join-Path $dir graft
            $cases = @(
                @{ Script = 'Build-LitertFromSource.ps1'; Root = $includeRoot; Expected = 'nested\api.h|root.h' }
                @{ Script = 'Export-LitertLmBridge.ps1'; Root = $dstSupport; Expected = 'a.cc|nested\b.h' }
            )
            foreach ($case in $cases) {
                $copy = Get-TestScriptCommandBlock -ScriptPath "windows/scripts/build/$($case.Script)" -Name Copy-SourceBuildFileTree
                Assert-Equal 2 (& $copy)
                $installed = @(Get-ChildItem $case.Root -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($case.Root, $_.FullName) } | Sort-Object)
                Assert-Equal $case.Expected ($installed -join '|') 'caller selections survive the shared tree copy'
            }
            Assert-Equal root ([IO.File]::ReadAllText((Join-Path $tfliteSrc root.h))) 'header staging leaves the source intact'
            Assert-Equal impl ([IO.File]::ReadAllText((Join-Path $supportClone support/a.cc))) 'grafting leaves its clone intact until caller cleanup'
        }
    }

    It 'runs the real LiteRT proto sweep without consuming target names for unrelated files' {
        Invoke-InTestDir -Files @{ 'tflite/a/proto/CMakeLists.txt' = 'protobuf_generate()'; 'tflite/b/proto/CMakeLists.txt' = 'keep'; 'tflite/c/proto/CMakeLists.txt' = 'protoc'; 'tflite/CMakeLists.txt' = 'protobuf_generate()' } -Body { param($dir)
            $tfliteSrc = Join-Path $dir tflite
            $apply = Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-LitertFromSource.ps1' -Name Invoke-SourceFilePatchSet
            Assert-Equal 2 (& $apply)
            Assert-TestScriptContains -ScriptPath (Join-Path $tfliteSrc 'a/proto/CMakeLists.txt') -Literal 'project(proto_stub_1)'
            Assert-TestScriptContains -ScriptPath (Join-Path $tfliteSrc 'c/proto/CMakeLists.txt') -Literal 'add_library(proto_stub_2 INTERFACE)'
            Assert-Equal keep ([IO.File]::ReadAllText((Join-Path $tfliteSrc 'b/proto/CMakeLists.txt')))
            Assert-Equal 'protobuf_generate()' ([IO.File]::ReadAllText((Join-Path $tfliteSrc CMakeLists.txt)))
            Assert-Equal 0 (& $apply)
        }
    }

    It 'runs both real GStreamer sweeps with required inputs and caller-owned changed diagnostics' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -FunctionName ConvertTo-GstOpenCv5Text)
        Invoke-InTestDir -Files @{ 'gst/meson.build' = 'cpp_std=c++11'; 'gst/child/meson.build' = 'cpp_std=c++17'; 'gst/subprojects/gst-plugins-bad/ext/opencv/port.cpp' = "#include <opencv2/core.hpp>`ncontourArea();"; 'gst/subprojects/gst-plugins-bad/ext/opencv/current.h' = 'unrelated' } -Body { param($dir)
            $gstSrcDir = Join-Path $dir gst
            $ocvExtDir = Join-Path $gstSrcDir 'subprojects/gst-plugins-bad/ext/opencv'
            $calls = @(Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -Name Invoke-SourceFilePatchSet -ExpectedCount 2)
            $messages = [Collections.Generic.List[string]]::new()
            Invoke-WithTestFunction -Name log -FixtureState $messages -Definition { param($message) $State.Add($message) } -Body { param($messages)
                $cpp, $port = $calls
                Assert-Equal 1 (& $cpp)
                Assert-Equal 'cpp_std=c++17' ([IO.File]::ReadAllText((Join-Path $gstSrcDir meson.build)))
                Assert-Equal 0 (& $cpp)
                Assert-Equal 1 (& $port)
                Assert-Equal 'OpenCV5 port -> port.cpp' ($messages -join '|')
                Assert-Match 'opencv2/geometry.hpp' ([IO.File]::ReadAllText((Join-Path $ocvExtDir port.cpp)))
                Assert-Equal 0 (& $port)
                Assert-Equal 1 $messages.Count 'no changed notification for an idempotent sweep'
            }
        }
    }

    It 'retains the OpenCV already-applied probe count and fatal minimum of two' {
        $files = @{
            'cmake/checks/cpu_one.cpp' = '#if (defined __GNUC__ && (defined __arm__ || defined __aarch64__)) /* || (defined _MSC_VER && (defined _M_ARM64 || defined _M_ARM64EC)) */'
            'cmake/checks/cpu_two.cpp' = '__clang__ && (defined _M_ARM64'
            'cmake/checks/unselected.cpp' = 'untouched'
            'modules/core/src/softfloat.cpp' = "typedef softfloat float32_t;`n typedef softdouble float64_t;"
            '3rdparty/mlas/lib/mlasi.h' = '#define vmaxvq_f32(src) neon_fmaxv(src)'
        }
        Invoke-InTestDir -Files $files -Body { param($mainSrc)
            . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-OpencvFromSource.ps1' `
                -FunctionName 'Invoke-OpencvSoftfloatPatch', 'Invoke-OpencvMlasNeonPatch', 'Invoke-OpencvArmIntrinsicsPatches')
            $call = Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-OpencvFromSource.ps1' -Name Invoke-SourceFilePatchSet
            $armBranch = Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.IfStatementAst]) -First
            $apply = & ([scriptblock]::Create($armBranch.Clauses[0].Item2.Extent.Text))
            & $apply
            Assert-TestScriptContains -ScriptPath (Join-Path $mainSrc cmake/checks/cpu_one.cpp) -Literal '__clang__ && (defined _M_ARM64'
            Assert-TestScriptContains -ScriptPath (Join-Path $mainSrc modules/core/src/softfloat.cpp) -Literal '#define float32_t softfloat'
            Assert-TestScriptContains -ScriptPath (Join-Path $mainSrc 3rdparty/mlas/lib/mlasi.h) -Literal '#if !defined(__clang__)'
            Assert-Equal untouched ([IO.File]::ReadAllText((Join-Path $mainSrc cmake/checks/unselected.cpp)))
            & $apply
            Remove-Item (Join-Path $mainSrc cmake/checks/cpu_two.cpp)
            Assert-Throws { & $apply } -MessagePattern 'only 1 probe file'
        }
    }
    It 'keeps the LiteRT-LM setter, quantization and GoogleTensor guard patterns at the real call sites' {
        $path = 'windows/scripts/build/Build-LitertLmFromSource.ps1'
        $edits = @(Get-TestScriptCommands -ScriptPath $path -Name Edit-LitertLmSourceText)
        $cases = @(
            @{ Target = "'runtime\executor\llm_executor_settings_utils.cc'"; Input = "gpu_compilation_options.SetKernelBatchSize(`$bytes); runtime_options.SetDisableDelegateClustering(false);"; Marker = 'litert GpuOptions/RuntimeOptions setter absent on Windows'; Indent = '      '; Guards = 2
                Parts = @('gpu_compilation_options.SetKernelBatchSize($bytes);', 'runtime_options.SetDisableDelegateClustering(false);') }
            @{ Target = "'runtime\executor\llm_litert_npu_compiled_model_executor.cc'"; Input = "if (tensor_expected->HasQuantization()) { q_params.zero_point = pq.zero_point; }`nif (logits_tensor.HasQuantization()) { LOG << "").""; }"; Marker = 'litert::SimpleTensor quantization API absent on Windows (NPU off)'; Indent = ''; Guards = 2
                Parts = @('if (tensor_expected->HasQuantization()) { q_params.zero_point = pq.zero_point; }', 'if (logits_tensor.HasQuantization()) { LOG << ")."; }') }
        )
        foreach ($case in $cases) {
            $call = @($edits | Where-Object { (Get-TestCommandArguments -Command $_).Target -eq $case.Target })
            Assert-Equal 1 $call.Count
            $transform = (Get-TestCommandArguments -Command $call[0] -AsAst).Transform.ScriptBlock.GetScriptBlock()
            $rendered = & $transform $case.Input
            Assert-Equal $case.Guards ([regex]::Matches($rendered, '#if !defined\(_WIN32\)')).Count
            Assert-True $rendered.Contains($case.Marker)
            foreach ($part in $case.Parts) { Assert-True $rendered.Contains(("`n" + $case.Indent + $part + "`n#endif")) 'each entire matched source survives its own guard' }
            Assert-Equal $case.Guards ([regex]::Matches($rendered, '#endif')).Count
        }
        $gtRaw = 'LITERT_ASSIGN_OR_RETURN(auto& google_tensor_options, source); google_tensor_options.SetPerformanceMode(GoogleTensorOptions::PerformanceMode::kBurst);'
        $guards = @(Get-TestScriptCommandBlock -ScriptPath $path -Name Add-SourceRegexGuard -ExpectedCount 3)
        $google = & $guards[2]
        Assert-Equal ("#if !defined(_WIN32)  // [LiteRTLM-winfix google_tensor] GoogleTensorOptions perf-mode API absent on Windows`n      " + $gtRaw + "`n#endif") $google
        $link = $edits | Where-Object { (Get-TestCommandArguments -Command $_).Target -eq "'cmake\packages\litert_lm\CMakeLists.txt'" }
        $linkTransform = (Get-TestCommandArguments -Command $link -AsAst).Transform.ScriptBlock.GetScriptBlock()
        $cmake = 'if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")' + "`n  if(APPLE)`n" + 'elseif(MSVC)  # Windows Linker' + "`n" + 'set(_LITERTLM_LINK_MULTIDEF "/FORCE:MULTIPLE") set(_LITERTLM_LINK_WHOLE_START "/WHOLEARCHIVE")'
        $expected = 'if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU" AND NOT WIN32)  # [LiteRTLM-winfix link-spec] lld-link ignores GNU --whole-archive/--start-group; route Windows to the MSVC branch' + "`n  if(APPLE)`n" + 'elseif(MSVC OR WIN32)  # Windows Linker' + "`n" + 'set(_LITERTLM_LINK_MULTIDEF "-Wl,/FORCE:MULTIPLE") set(_LITERTLM_LINK_WHOLE_START "-Wl,/WHOLEARCHIVE")'
        Assert-Equal $expected (& $linkTransform $cmake) 'link-spec passes retain capture whitespace and literal flag forwarding'
    }

    It 'keeps the TVM core module query recursive, file-only and exactly one' {
        Invoke-InTestDir -Files @{ 'nested/core.cp987-win_arm64.pyd' = 'module'; 'ignore.txt' = 'decoy' } -Body { param($BuildDir)
            $null = New-Item -ItemType Directory -Path (Join-Path $BuildDir core-decoy.pyd)
            $query = Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-TvmFromSource.ps1' -Name Get-UniqueBuildArtifact
            $one = @(& $query)
            Assert-Equal 1 $one.Count
            Assert-Equal 'core.cp987-win_arm64.pyd' $one[0].Name
            [IO.File]::WriteAllText((Join-Path $BuildDir core.pyd), 'second module')
            Assert-Throws { & $query } -MessagePattern 'expected exactly one.*found 2:.*core'
            Remove-Item (Join-Path $BuildDir core.pyd), $one[0].FullName
            Assert-Throws { & $query } -MessagePattern 'expected exactly one.*found 0:'
        }
    }

    It 'keeps every LiteRT-LM static import map on its exact absl, protobuf or generic naming policy' {
        $profiles = @(
            @{ Path = @('cmake/packages/absl/absl_import_static_lib.cmake', 'cmake/packages/absl/absl_target_map.cmake'); Expected = 'absl_A.lib libabsl_skip-hyphen.a /libfoo.a libbare.a'; Description = 'libabsl_*.a -> absl_*.lib' }
            @{ Path = @('cmake/packages/protobuf/protobuf_target_map.cmake'); Expected = 'libabsl_A.a libabsl_skip-hyphen.a /foo.lib libbare.a'; Description = 'protobuf_target_map.cmake : /lib*.a -> /*.lib' }
            @{ Path = @('cmake/packages/litert/litert_target_map.cmake', 'cmake/packages/sentencepiece/sentencepiece_target_map.cmake', 'cmake/packages/sentencepiece/sentencepiece.cmake', 'cmake/packages/tflite/tflite_target_map.cmake', 'cmake/packages/tflite/tflite.cmake', 'cmake/packages/re2/re2_target_map.cmake', 'cmake/packages/re2/re2.cmake', 'cmake/packages/tokenizers/tokenizers.cmake', 'cmake/packages/tokenizers/tokenizers_target_map.cmake', 'cmake/packages/flatbuffers/flatbuffers_target_map.cmake'); Expected = 'absl_A.lib absl_skip-hyphen.lib /foo.lib bare.lib'; Description = 'lib*.a -> *.lib' }
        )
        $calls = @(Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-LitertLmFromSource.ps1' -Name Edit-SourceStaticLibraryReferences -ExpectedCount 3)
        for ($index = 0; $index -lt $profiles.Count; $index++) {
            $mapPolicy = $profiles[$index]
            $files = @{}; $expected = @{}
            foreach ($relative in $mapPolicy.Path) {
                $files[$relative] = 'libabsl_A.a libabsl_skip-hyphen.a /libfoo.a libbare.a'
                $expected[$relative] = $mapPolicy.Expected
            }
            $convert = $calls[$index]
            Assert-SourceFileConversion -Case @{
                Files = $files; Expected = $expected; ChangedCount = $mapPolicy.Path.Count
                DescriptionPattern = [regex]::Escape($mapPolicy.Description)
                Operation = { param($SourceDir) & $convert }
            }
        }
    }

    It 'applies LiteRT-LM literal and regex source replacements once through the shared patch writer' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/build/Build-LitertLmFromSource.ps1' `
            -FunctionName 'Edit-LitertLmSourceText', 'Edit-LitertLmSourceReplacement')
        Invoke-InTestDir -Files @{
            'cmake/pin.cmake' = "GIT_TAG`n  20260107.1"
            'cmake/tool.cmake' = 'set(OLD_TOOL ON)'
        } -Body { param($dir)
            $regexArgs = @{ SourceDir = $dir; Target = 'cmake/pin.cmake'; Marker = '20260817.0'; Regex = $true
                Find = '(GIT_TAG\s*\r?\n\s*)20260107\.1'; Replacement = '${1}20260817.0' }
            Assert-True (Edit-LitertLmSourceReplacement @regexArgs) 'the pinned version changes'
            Assert-Equal "GIT_TAG`n  20260817.0" ([IO.File]::ReadAllText((Join-Path $dir 'cmake/pin.cmake')))
            Assert-False (Edit-LitertLmSourceReplacement @regexArgs) 'the marker prevents a second edit'
            $literalArgs = @{ SourceDir = $dir; Target = 'cmake/tool.cmake'; Marker = 'NEW_TOOL'
                Find = 'set(OLD_TOOL ON)'; Replacement = 'set(NEW_TOOL ON)' }
            Assert-True (Edit-LitertLmSourceReplacement @literalArgs) 'the literal source edit changes'
            Assert-Equal 'set(NEW_TOOL ON)' ([IO.File]::ReadAllText((Join-Path $dir 'cmake/tool.cmake')))
            Assert-False (Edit-LitertLmSourceReplacement @literalArgs) 'the literal edit is idempotent'
        }
    }

}

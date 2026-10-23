#requires -Version 7.0
# Local trees cover staging and patch-set execution; they do not compile upstream projects or exercise network acquisition.

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
}

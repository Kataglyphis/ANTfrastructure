#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# CON91: the ai-edge-litert wheel's bazel options, pins, lock and source rewrites; probes P1-P12 ran the build itself.

$script:WheelScript = 'windows\scripts\build\Build-LitertWheelBazel.ps1'
$script:WheelText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:WheelScript))
$script:PatchDir = Join-Path (Get-RepoRoot) 'windows\scripts\patches\litert'

Describe 'Build-LitertWheelBazel: one option list for analysis, build and aquery' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:WheelScript -FunctionName 'Get-LitertWheelBazelArg')
    $script:Opts = Get-LitertWheelBazelArg -WorkRoot 'C:\lw' -ToolchainFlag @('--compiler=clang-cl', '--platforms=//:p') -PythonTarballSha256 'abc' -PythonMajorMinor '3.15'

    It 'puts --config=windows first, so every later flag beats LiteRT''s .bazelrc' {
        Assert-Equal '--config=windows' $script:Opts[2] 'after -c opt'
        Assert-True ([array]::IndexOf($script:Opts, '--compiler=clang-cl') -gt 2) 'the toolchain flags follow it'
    }

    It 'points bazel at the image''s CPython, the local overrides and the empty OpenVINO dir' {
        foreach ($want in '--repo_env=HERMETIC_PYTHON_VERSION=3.15', '--repo_env=HERMETIC_PYTHON_URL=file:///C:/lw/py/python.tar.gz',
            '--repo_env=HERMETIC_PYTHON_SHA256=abc', '--repo_env=HERMETIC_PYTHON_PREFIX=python',
            '--repo_env=HERMETIC_REQUIREMENTS_LOCK=C:/lw/req/requirements_lock.txt', '--repo_env=OPENVINO_NATIVE_DIR=C:/lw/openvino-absent',
            '--override_repository=litert_prebuilts=C:/lw/prebuilts', '--override_repository=pypi__pip=C:/lw/pip',
            '--python_path=C:/lw/py/python/python.exe', '--linkopt=/DEBUG:NONE') {
            Assert-True ($want -in $script:Opts) $want
        }
    }

    It 'runs analysis, build and aquery with that one list, never a fetch with other options (mutation)' {
        foreach ($cmd in '& \$bazel @startup build @opts --nobuild \$target', '& \$bazel @startup aquery @opts ',
            "-Argument \(@\(\`$startup\) \+ @\('build'\) \+ @\(\`$opts\) \+ @\(\`$buildOnly\) \+ @\(\`$target\)\)") {
            Assert-Match $cmd $script:WheelText $cmd
        }
        Assert-False ($script:WheelText -match '@startup fetch ') 'a bare fetch would key repo rules on other options and wipe the rewrites'
    }
}

Describe 'Build-LitertWheelBazel: the hash-pinned lock' {
    $script:Pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')

    It 'exists for the pinned Python, and every entry equals its PY_* pin and carries a sha256' {
        $mm = ($script:Pins['PYTHON_VERSION'] -split '\.')[0..1] -join '_'
        $lock = Join-Path $script:PatchDir "requirements_lock_$mm.txt"
        Assert-True (Test-Path -LiteralPath $lock) "no lock for Python $mm"
        $text = [IO.File]::ReadAllText($lock)
        $entries = [regex]::Matches($text, '(?m)^([A-Za-z0-9_.-]+)==(\S+) \\\r?\n\s+--hash=sha256:[0-9a-f]{64}')
        Assert-True ($entries.Count -ge 3) 'numpy, setuptools and wheel at least'
        Assert-Equal $entries.Count ([regex]::Matches($text, '(?m)^[A-Za-z0-9_.-]+==')).Count 'every entry is hash-pinned'
        foreach ($e in $entries) {
            $key = 'PY_{0}_VERSION' -f ($e.Groups[1].Value.ToUpperInvariant() -replace '[-.]', '_')
            Assert-Equal $script:Pins[$key] $e.Groups[2].Value "$key"
        }
    }

    It 'pins the LiteRT tag''s commit and the bazel its .bazelversion names' {
        Assert-Match '^[0-9a-f]{40}$' $script:Pins['LITERT_WINDOWS_SOURCE_COMMIT'] 'a full commit'
        Assert-Match '^\d+\.\d+\.\d+$' $script:Pins['LITERT_BAZEL_WINDOWS_VERSION'] 'a release'
        Assert-Match '^[0-9a-f]{64}$' $script:Pins['LITERT_BAZEL_WINDOWS_AMD64_SHA256'] 'a sha256'
    }
}

Describe 'Build-LitertWheelBazel: upstream''s source rewrites are throw-on-miss' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:WheelScript -FunctionName 'Edit-ExternalText', 'Move-HighwayHashAlignas',
        'Invoke-LitertExternalRewrite', 'Get-LitertGetMessageSource')

    It 'rewrites one hit, accepts an already applied file and throws on none or two (mutation)' {
        Invoke-InTestDir { param($d)
            $f = Join-Path $d 'a.h'
            Set-Content -LiteralPath $f -Value "x 2`n" -NoNewline
            Edit-ExternalText $f 'x 2' 'x 0' -Applied 'x 0'
            Assert-Equal "x 0`n" ([IO.File]::ReadAllText($f)) 'rewritten'
            Edit-ExternalText $f 'x 2' 'x 0' -Applied 'x 0'
            Assert-Throws { Edit-ExternalText $f 'y' 'z' } -MessagePattern 'found 0 times'
            Set-Content -LiteralPath $f -Value "y y`n" -NoNewline
            Assert-Throws { Edit-ExternalText $f 'y' 'z' } -MessagePattern 'found 2 times'
            Assert-Throws { Edit-ExternalText (Join-Path $d 'none.h') 'y' 'z' } -MessagePattern 'rewrite target missing'
        }
    }

    It 'moves a trailing HH_ALIGNAS in front of the declaration and leaves macros, comments and leading ones alone' {
        Invoke-InTestDir { param($d)
            $f = Join-Path $d 'state.h'
            [IO.File]::WriteAllLines($f, @('  uint64_t v0[4] HH_ALIGNAS(32);', '#define X HH_ALIGNAS(16)', '  // T y HH_ALIGNAS(8);', '  HH_ALIGNAS(64) T z;'))
            Assert-Equal 1 (Move-HighwayHashAlignas -Directory $d) 'one line moved'
            Assert-Equal '  HH_ALIGNAS(32) uint64_t v0[4];' ([IO.File]::ReadAllLines($f)[0]) 'prefix form'
            Assert-Equal '#define X HH_ALIGNAS(16)' ([IO.File]::ReadAllLines($f)[1]) 'macro untouched'
        }
    }

    It 'applies every rewrite to a tree holding upstream''s anchors, and stops on a missing one' {
        Invoke-InTestDir { param($d)
            $pb = Join-Path $d 'com_google_protobuf\src\google\protobuf'
            $files = [ordered]@{
                'com_google_absl\absl\base\options.h' = "#define ABSL_OPTION_USE_STD_SOURCE_LOCATION 2`n"
                'com_google_protobuf\src\google\protobuf\compiler\java\context.h' = "#include `"google/protobuf/compiler/java/helpers.h`"`n"
                'com_google_protobuf\src\google\protobuf\compiler\java\BUILD.bazel' = "        `"helpers.h`",`n"
                'com_google_protobuf\src\google\protobuf\json\internal\untyped_message.h' = "a, UntypedMessage, b`nstd::vector<UntypedMessage>>;`n  const ResolverPool::Message& desc() const { return *desc_; }`n"
                'com_google_protobuf\src\google\protobuf\json\internal\untyped_message.cc' = "InsertField(*field, std::move(group))`nInsertField(field, std::move(*inner))`ntemplate <typename T>`nabsl::Status UntypedMessage::InsertField(const F& f, T&& value) {`n  old;`n}`n"
                'com_google_protobuf\src\google\protobuf\json\internal\unparser_traits.h' = "return &msg.Get<Msg>(f->proto().number())[idx];`n"
                'com_google_protobuf\src\google\protobuf\compiler\BUILD.bazel' = "        `"//src/google/protobuf/compiler/objectivec`",`n        `"//src/google/protobuf/compiler/rust`",`n"
                'highwayhash\highwayhash\compiler_specific.h' = "#if HH_GCC_VERSION && HH_GCC_VERSION < 408`n#define HH_ALIGNAS(multiple) __attribute__((aligned(multiple)))`n#else`n#define HH_ALIGNAS(multiple) alignas(multiple)  // C++11`n#endif`n"
            }
            $main = @('#include "google/protobuf/compiler/objectivec/generator.h"', '#include "google/protobuf/compiler/rust/generator.h"',
                '  objectivec::ObjectiveCGenerator objc_generator;', '  cli.RegisterGenerator("--objc_out", "--objc_opt", &objc_generator,',
                '                        "Generate Objective-C header and source.");', '  rust::RustGenerator rust_generator;',
                '  cli.RegisterGenerator("--rust_out", "--rust_opt", &rust_generator,', '                        "Generate Rust sources.");')
            $files['com_google_protobuf\src\google\protobuf\compiler\main.cc'] = ($main -join "`n") + "`n"
            foreach ($rel in $files.Keys) {
                $p = Join-Path $d $rel
                New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
                [IO.File]::WriteAllText($p, $files[$rel])
            }
            $insert = Join-Path $script:PatchDir 'untyped_message_insert_field.cc'
            Invoke-LitertExternalRewrite -External $d -InsertFieldFile $insert | Out-Null
            Assert-Match 'SOURCE_LOCATION 0' ([IO.File]::ReadAllText((Join-Path $d 'com_google_absl\absl\base\options.h'))) 'absl'
            Assert-Match 'using stored_type' ([IO.File]::ReadAllText("$pb\json\internal\untyped_message.cc")) 'InsertField replaced'
            Assert-Match 'GetMessage\(int32_t field_number' ([IO.File]::ReadAllText("$pb\json\internal\untyped_message.h")) 'accessor inserted'
            Assert-False ([IO.File]::ReadAllText("$pb\compiler\main.cc").Contains('objc_generator')) 'objc generator gone'
            Assert-Match '__declspec\(align\(multiple\)\)' ([IO.File]::ReadAllText((Join-Path $d 'highwayhash\highwayhash\compiler_specific.h'))) 'HH_MSC_VERSION branch'
            [IO.File]::WriteAllText("$pb\json\internal\unparser_traits.h", "moved upstream`n")
            [IO.File]::WriteAllText("$pb\json\internal\untyped_message.h", "a, UntypedMessage, b`n")
            Assert-Throws { Invoke-LitertExternalRewrite -External $d -InsertFieldFile $insert } -MessagePattern 'found 0 times|rewrite anchor'
        }
    }
}

Describe 'Build-LitertWheelBazel: pins and the wheel contract' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:WheelScript -FunctionName 'Get-LitertWheelPin', 'Assert-LitertWheelContract')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsBazel.Common.psm1' -FunctionName 'Get-BazelPin')

    It 'refuses a missing pin by name' {
        Invoke-WithEnv @{ LITERT_VERSION = 'v2.2.0'; LITERT_WINDOWS_SOURCE_COMMIT = $null } {
            Assert-Throws { Get-LitertWheelPin } -MessagePattern 'LITERT_WINDOWS_SOURCE_COMMIT is unset'
        }
    }

    It 'refuses a wheel named for another version or Python' {
        Invoke-InTestDir { param($d)
            $w = Join-Path $d 'ai_edge_litert-2.2.0-cp314-cp314-win_amd64.whl'
            Set-Content -LiteralPath $w -Value 'x'
            Assert-Throws { Assert-LitertWheelContract -Wheel $w -Version '2.2.0' -AbiTag 'cp315' -AcceleratorSha256 'x' -ExtractDir (Join-Path $d 'x') } `
                -MessagePattern 'not ai_edge_litert-2\.2\.0-cp315-cp315-win_amd64\.whl'
        }
    }

    It 'leaves the layer clean: the tree goes unless -KeepTree, and bazel never runs outside the checkout' {
        Assert-Match "if \(-not \`$KeepTree\) \{ Remove-BazelBuildTree -Path @\(\`$WorkRoot\) -ServerRoot @\(`"\`$WorkRoot\\u`"\) \}" $script:WheelText 'cleanup'
        Assert-Match '(?s)Push-Location \$src\s+try \{.*@startup build @opts --nobuild' $script:WheelText 'from inside the clone (probe P3: outside a workspace the client env overflows the JVM command line)'
    }
}

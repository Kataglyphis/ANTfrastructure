#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Builds and crashes a real x64 MSVC fixture; ARM64 and clang-cl run in the consumer lanes that link the handler.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsNative.Common.psm1') -Force -DisableNameChecking

function script:Invoke-CrashDumpCmake {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & cmake @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cmake $($Arguments -join ' ') failed ($LASTEXITCODE): $($output -join "`n")" }
}

function script:New-CrashDumpFixture {
    param([Parameter(Mandatory)][string]$Root)
    $hub = (Join-Path (Get-RepoRoot) 'cmake').Replace('\', '/')
    $source = Join-Path $Root 'src'
    $null = New-Item -ItemType Directory -Path $source
    # The address comes from argc, so the compiler cannot turn the store into a trap instruction.
    Set-Content -LiteralPath (Join-Path $source 'main.cpp') -Encoding ascii -Value @(
        '#include <cstdint>', '#include <thread>',
        'int main(int argc, char **) {',
        '  std::thread worker([argc] { *reinterpret_cast<volatile int *>(static_cast<std::uintptr_t>(argc - 1)) = 1; });',
        '  worker.join();', '  return 0;', '}')
    # A copy outside the module's source properties, so /W4 /WX reaches the handler's own code.
    Copy-Item -LiteralPath (Join-Path $hub 'crash_dump/kataglyphis_crash_dump.cpp') -Destination (Join-Path $source 'strict.cpp')
    Set-Content -LiteralPath (Join-Path $source 'CMakeLists.txt') -Encoding ascii -Value @(
        'cmake_minimum_required(VERSION 3.20)', 'project(fixture LANGUAGES CXX)', "include(`"$hub/CrashDump.cmake`")",
        'add_executable(crash_fixture main.cpp)', 'kataglyphis_add_crash_dump(crash_fixture)',
        'add_library(strict_handler OBJECT strict.cpp)', 'target_compile_options(strict_handler PRIVATE /W4 /WX)')
    $build = Join-Path $Root 'build'
    Invoke-CrashDumpCmake -Arguments @('-S', $source, '-B', $build, '-A', 'x64')
    Invoke-CrashDumpCmake -Arguments @('--build', $build, '--config', 'Release')
    return Join-Path $build 'Release/crash_fixture.exe'
}

if ($IsWindows) { Describe 'kataglyphis_add_crash_dump on a real crash' {

    It 'records a background-thread access violation, keeps its exit code, and is inert without the variable' {
        Invoke-InTestDir { param($dir)
            $exe = New-CrashDumpFixture -Root $dir
            Assert-True (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($exe, 'pdb'))) 'a Release link must write the PDB that names the frames'
            $dumps = Join-Path $dir 'dumps'
            $crash = Invoke-NativeProbeProcess -FilePath $exe -Environment @{ KATAGLYPHIS_CRASH_DUMP_DIR = $dumps } -PreserveOutput
            Assert-Equal -1073741819 $crash.ExitCode 'the handler must not swallow the access violation'
            Assert-Match 'kataglyphis-crash: exception 0xC0000005 at crash_fixture\.exe\+0x[0-9a-f]+ on thread \d+' $crash.Text
            Assert-Match 'kataglyphis-crash: write of 0x0\r?\n' $crash.Text
            Assert-Match 'kataglyphis-crash:   #00 crash_fixture\.exe\+0x[0-9a-f]+' $crash.Text
            $dump = @(Get-ChildItem -LiteralPath $dumps -Filter 'crash_fixture.exe.*.dmp' -File)
            Assert-Equal 1 $dump.Count 'one minidump per crashed process'
            Assert-Equal 'MDMP' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dump[0].FullName), 0, 4))
            Assert-True ($crash.Text.Contains("kataglyphis-crash: minidump $($dump[0].FullName)")) 'stderr names the dump it wrote'

            $plain = Invoke-WithEnv @{ KATAGLYPHIS_CRASH_DUMP_DIR = $null } { Invoke-NativeProbeProcess -FilePath $exe -PreserveOutput }
            Assert-Equal -1073741819 $plain.ExitCode
            Assert-False ($plain.Text.Contains('kataglyphis-crash')) 'without the variable the handler stays out of the way'
            Assert-Equal 1 @(Get-ChildItem -LiteralPath $dumps -Filter '*.dmp' -File).Count 'no second dump without the variable'
        }
    }
} }

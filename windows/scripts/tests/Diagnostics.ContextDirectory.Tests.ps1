#requires -Version 7.0
# Local directory fixtures do not start BuildKit or exercise CUDA and remote cache access.

Describe 'Diagnostic context directory resolution' {
    It 'creates a context containing spaces and retains its payload when resolved again' {
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../modules/WindowsScripts.Shared.psm1'))
        Invoke-WithFunctionModule -Text $source -FunctionName Resolve-DirectoryPath -Body {
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir 'CUDA context'
                Assert-Equal $path (Resolve-MutDirectoryPath -Path $path)
                $payload = Join-Path $path 'Test-Cache.ps1'
                [IO.File]::WriteAllText($payload, 'fixture payload')
                Assert-Equal $path (Resolve-MutDirectoryPath -Path $path)
                Assert-Equal 'fixture payload' ([IO.File]::ReadAllText($payload))
            }
        }
    }
}

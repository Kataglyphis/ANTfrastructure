#requires -Version 7.0
# Synthetic chain trees cover indexing policies and read failures; they do not identify renamed foreign ORT binaries.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Build.psm1') -Force -DisableNameChecking

function Invoke-OrtDirectoryIndexFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $indexAction = $Body
    Invoke-InTestDir { param($dir)
        $files = @{
            'include\onnxruntime\onnxruntime_c_api.h' = 'api'
            'include\onnxruntime\providers\cpu_provider_factory.h' = 'factory'
            'include\foreign\onnxruntime_foreign.h' = 'foreign'
            'include\onnxruntime\onnxruntime_genai.txt' = 'metadata'
            'lib\onnxruntime.lib' = 'lib-a'; 'lib\nested\onnxruntime.lib' = 'lib-b'
            'bin\onnxruntime.dll' = 'dll-a'; 'bin\nested\onnxruntime.dll' = 'dll-b'
        }
        Write-TestFileTree -Root $dir -Files $files
        & $indexAction $dir
    }.GetNewClosure()
}

function Assert-OrtFlatRuntimeIndex {
    param([string]$Command = 'Get-OrtGateDirectoryIndex')
    Invoke-OrtDirectoryIndexFixture -Body {
        param($dir)
        $index = & $Command -OrtRoot $dir -Consumer Genai
        Assert-Equal 1 $index.Sha['onnxruntime.lib'].Count 'GenAI references only the flat runtime libraries'
        Assert-Equal 1 $index.Sha['onnxruntime.dll'].Count
        Assert-False $index.Sha.ContainsKey('onnxruntime_foreign.h')
        Assert-True $index.Sha.ContainsKey('onnxruntime_genai.txt')
        Assert-True $index.Sha.ContainsKey('cpu_provider_factory.h') 'headers remain recursive'
    }.GetNewClosure()
}

Describe 'ORT chain directory indexing' {
    It 'indexes recursive code files, hidden files and multiple hashes under a case-insensitive name' {
        Invoke-OrtDirectoryIndexFixture -Body {
            param($dir)
            $hidden = Join-Path $dir 'include\onnxruntime\onnxruntime_hidden.h'
            [IO.File]::WriteAllText($hidden, 'hidden')
            [IO.File]::SetAttributes($hidden, [IO.FileAttributes]::Hidden)
            $index = Get-OrtGateDirectoryIndex -OrtRoot $dir
            Assert-Equal 2 $index.Sha['ONNXRUNTIME.LIB'].Count
            Assert-Equal 2 $index.Sha['onnxruntime.dll'].Count
            Assert-True $index.Sha.ContainsKey('onnxruntime_foreign.h')
            Assert-True $index.Sha.ContainsKey('onnxruntime_hidden.h')
            Assert-False $index.Sha.ContainsKey('onnxruntime_genai.txt')
            Assert-True $index.Sha['onnxruntime.dll'].Contains($index.Core)
            Assert-True $index.Sha['onnxruntime_c_api.h'].Contains($index.CApi)
        }
    }

    It 'preserves GenAI''s recursive header subtree, flat runtime and broader name policy' { Assert-OrtFlatRuntimeIndex }

    It 'leaves anchor validation to the full chain index and keeps its required findings' {
        Invoke-InTestDir { param($dir)
            Assert-Equal 0 (Get-OrtGateDirectoryIndex -OrtRoot $dir).Sha.Count
            $index = Get-OrtGateChainIndex -OrtRoot $dir
            Assert-Equal 4 $index.Finding.Count
            foreach ($anchor in 'onnxruntime_c_api.h', 'onnxruntime.lib', 'onnxruntime.dll', 'bin\onnxruntime.dll') {
                Assert-Match ([regex]::Escape($anchor)) ($index.Finding -join '|')
            }
        }
    }

    It 'keeps an unreadable-file sentinel for G2 and throws for GenAI''s stricter reference reads' {
        Invoke-OrtDirectoryIndexFixture -Body {
            param($dir)
            $locked = [IO.File]::Open((Join-Path $dir 'lib\onnxruntime.lib'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $index = Get-OrtGateDirectoryIndex -OrtRoot $dir
                Assert-True $index.Sha['onnxruntime.lib'].Contains('unreadable')
                Assert-Throws { Get-OrtGateDirectoryIndex -OrtRoot $dir -Consumer Genai } -MessagePattern 'onnxruntime\.lib'
            } finally { $locked.Dispose() }
        }
    }

    It 'detects a recursive-runtime mutant with the same policy assertions' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsOrtProvenance.Build.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Get-OrtGateSha, Add-OrtGateSha, Get-OrtGateDirectoryIndex `
            -Find '($sub -eq $include -or -not $genai)' -Replace '$true' -Body {
                Assert-OrtFlatRuntimeIndex
                Assert-Throws { Assert-OrtFlatRuntimeIndex -Command Get-MutOrtGateDirectoryIndex } -MessagePattern 'GenAI references only the flat runtime libraries'
            }
    }
}

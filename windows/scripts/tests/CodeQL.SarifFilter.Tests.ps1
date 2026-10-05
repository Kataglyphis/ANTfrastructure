#requires -Version 7.0
# paths-ignore reaches traced C++ results only through this filter: 39 of 63 cpp results were vendored code (2026-10-05).
Describe 'the code-scanning config filters CodeQL results' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsCodeQL.Common.psm1') -Force
        $script:config = Join-Path $TestDrive 'codeql-config.yml'
        Set-Content -LiteralPath $script:config -Encoding utf8 -Value @'
name: "fixture"
# a comment line
paths-ignore:
  # a comment inside the list
  - build
  - "third_party/Vendored"
  - third_party/Deep/**/generated
  - 'rust_builder/cargokit/'   # trailing comment
queries:
  - uses: security-and-quality
'@

        # A SARIF with one result per uri, in the shape `database analyze` writes.
        function New-Sarif([string[]] $Uris) {
            $results = foreach ($u in $Uris) {
                @{ ruleId = 'r'; message = @{ text = 'm' }; locations = @(@{ physicalLocation = @{ artifactLocation = @{ uri = $u } } }) }
            }
            $path = Join-Path $TestDrive ("{0}.sarif" -f [guid]::NewGuid().ToString('N'))
            @{ version = '2.1.0'; runs = @(@{ tool = @{ driver = @{ name = 'CodeQL' } }; results = @($results) }) } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            $path
        }
        function Get-ResultUris([string] $Path) {
            @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100).runs[0].results |
                ForEach-Object { $_.locations[0].physicalLocation.artifactLocation.uri })
        }
    }

    It 'reads the block list, without comments, quotes or the next key' {
        $paths = Get-CodeScanningPathsIgnore -ConfigPath $script:config
        $paths | Should -Be @('build', 'third_party/Vendored', 'third_party/Deep/**/generated', 'rust_builder/cargokit/')
    }

    It 'matches a plain path, its subtree, and ** at any depth, and nothing that merely shares a prefix' {
        $p = Get-CodeScanningPathsIgnore -ConfigPath $script:config
        Test-CodeScanningPathIgnored -Uri 'build/x/y.cc' -Patterns $p | Should -BeTrue
        Test-CodeScanningPathIgnored -Uri 'third_party/Vendored/fmt/format.h' -Patterns $p | Should -BeTrue
        Test-CodeScanningPathIgnored -Uri 'third_party/Deep/a/b/generated/x.cc' -Patterns $p | Should -BeTrue
        Test-CodeScanningPathIgnored -Uri 'rust_builder/cargokit/build_tool/x.rs' -Patterns $p | Should -BeTrue
        Test-CodeScanningPathIgnored -Uri 'buildtools/x.cc' -Patterns $p | Should -BeFalse
        Test-CodeScanningPathIgnored -Uri 'third_party/VendoredNot/x.cc' -Patterns $p | Should -BeFalse
        Test-CodeScanningPathIgnored -Uri 'Src/onnx_inference_engine.cpp' -Patterns $p | Should -BeFalse
    }

    It 'drops exactly the ignored results and keeps the owned ones' {
        $sarif = New-Sarif @('Src/a.cpp', 'third_party/Vendored/b.h', 'build/c.cc', 'windows/runner/d.cpp')
        Remove-SarifIgnoredResult -SarifPath $sarif -IgnoredPaths (Get-CodeScanningPathsIgnore -ConfigPath $script:config) | Should -Be 2
        Get-ResultUris $sarif | Should -Be @('Src/a.cpp', 'windows/runner/d.cpp')
    }

    It 'leaves the file alone when nothing is ignored, or nothing matches' {
        $sarif = New-Sarif @('Src/a.cpp')
        $before = Get-Content -LiteralPath $sarif -Raw
        Remove-SarifIgnoredResult -SarifPath $sarif -IgnoredPaths @() | Should -Be 0
        Remove-SarifIgnoredResult -SarifPath $sarif -IgnoredPaths @('build') | Should -Be 0
        Get-Content -LiteralPath $sarif -Raw | Should -Be $before
    }
}

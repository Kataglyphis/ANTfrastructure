#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# NOT covered: a cargo build; this smoke pins image ORT env wiring and parser failure order.
using namespace System.Management.Automation.Language

$script:CrateSmoke = Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Container.ps1'
$script:OrtEnvNames = 'ORT_LIB_LOCATION', 'ORT_LIB_PATH', 'ORT_DYLIB_PATH', 'ORT_PREFER_DYNAMIC_LINK', 'ORT_SKIP_DOWNLOAD', 'CARGO_NET_OFFLINE'

# A chain ORT root holding exactly what the env points at: lib\onnxruntime.lib and bin\onnxruntime.dll.
function New-ChainOrtRoot {
    param([Parameter(Mandatory)][string]$Dir, [switch]$NoLib, [switch]$NoDll)
    $root = Join-Path $Dir 'onnxruntime-source'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'lib'), (Join-Path $root 'bin') | Out-Null
    if (-not $NoLib) { Set-Content -LiteralPath (Join-Path $root 'lib\onnxruntime.lib') 'x' -Encoding ASCII }
    if (-not $NoDll) { Set-Content -LiteralPath (Join-Path $root 'bin\onnxruntime.dll') 'x' -Encoding ASCII }
    return $root
}

# The env the Dockerfile bakes for $Root; -Set overrides entries, -Remove drops them.
function New-OrtCrateEnv {
    param([Parameter(Mandatory)][string]$Root, [hashtable]$Set = @{}, [string[]]$Remove = @())
    $baked = [ordered]@{ ORT_LIB_LOCATION = "$Root\lib"; ORT_DYLIB_PATH = "$Root\bin\onnxruntime.dll"; ORT_PREFER_DYNAMIC_LINK = '1'; ORT_SKIP_DOWNLOAD = '1' }
    $out = @{}
    @($baked.GetEnumerator()) + @($Set.GetEnumerator()) | Where-Object { $Remove -notcontains $_.Key } | ForEach-Object { $out[$_.Key] = $_.Value }
    $out
}

Describe 'Smoke §19: ort crate env findings' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:CrateSmoke -FunctionName 'Get-OrtCrateEnvFinding')

    It 'passes the env windows/Dockerfile bakes, whatever case or trailing slash ONNX_ROOT carries' {
        Invoke-InTestDir { param($dir)
            $root = New-ChainOrtRoot -Dir $dir
            Assert-Equal 0 @(Get-OrtCrateEnvFinding -OnnxRoot $root -Environment (New-OrtCrateEnv -Root $root)).Count 'healthy'
            Assert-Equal 0 @(Get-OrtCrateEnvFinding -OnnxRoot "$root\" -Environment (New-OrtCrateEnv -Root $root.ToUpperInvariant())).Count 'case/trailing slash'
            $truthy = New-OrtCrateEnv -Root $root -Set @{ ORT_PREFER_DYNAMIC_LINK = 'True'; ORT_SKIP_DOWNLOAD = 'TRUE'; CARGO_NET_OFFLINE = 'true' }
            Assert-Equal 0 @(Get-OrtCrateEnvFinding -OnnxRoot $root -Environment $truthy).Count 'ort-sys reads true case-insensitively'
        }
    }

    It 'fails every way back to a non-chain or downloaded ORT, one finding each (mutation)' {
        Invoke-InTestDir { param($dir)
            $good = New-ChainOrtRoot -Dir $dir
            $cases = @(
                @{ Remove = @('ORT_LIB_LOCATION'); Want = 'ORT_LIB_LOCATION is '''', not the chain''s .* pyke' }
                @{ Set = @{ ORT_LIB_LOCATION = 'C:\onnxruntime\lib' }; Want = 'ORT_LIB_LOCATION is ''C:\\onnxruntime\\lib''' }
                @{ Set = @{ ORT_LIB_LOCATION = "$good\bin" }; Want = 'ORT_LIB_LOCATION is .*\\bin''' }
                @{ Remove = @('ORT_DYLIB_PATH'); Want = 'System32' }
                @{ Set = @{ ORT_DYLIB_PATH = 'C:\Windows\System32\onnxruntime.dll' }; Want = 'ORT_DYLIB_PATH is ''C:\\Windows\\System32' }
                @{ Remove = @('ORT_PREFER_DYNAMIC_LINK'); Want = 'ORT_PREFER_DYNAMIC_LINK is '''' - ort-sys would try a static ORT' }
                @{ Set = @{ ORT_PREFER_DYNAMIC_LINK = '0' }; Want = 'ORT_PREFER_DYNAMIC_LINK is ''0''' }
                @{ Remove = @('ORT_SKIP_DOWNLOAD'); Want = 'ORT_SKIP_DOWNLOAD is '''' - .*pyke''s CDN' }
                @{ Set = @{ ORT_SKIP_DOWNLOAD = 'yes' }; Want = 'ORT_SKIP_DOWNLOAD is ''yes''' }
                @{ Set = @{ ORT_SKIP_DOWNLOAD = ' 1' }; Want = 'ORT_SKIP_DOWNLOAD is '' 1''' }
                @{ Set = @{ ORT_LIB_PATH = 'C:\pyke' }; Want = 'ORT_LIB_PATH is set .* BEFORE ORT_LIB_LOCATION' }
                @{ Set = @{ ORT_LIB_PATH = '' }; Want = 'ORT_LIB_PATH is set \(''''\)' }
                @{ Set = @{ CARGO_NET_OFFLINE = 'false' }; Want = 'CARGO_NET_OFFLINE is ''false'' .* re-enables the download' }
                @{ Set = @{ CARGO_NET_OFFLINE = '' }; Want = 'CARGO_NET_OFFLINE is '''' .* re-enables the download' }
            )
            foreach ($c in $cases) {
                $edit = @{}
                foreach ($k in 'Set', 'Remove') { if ($c.ContainsKey($k)) { $edit[$k] = $c[$k] } }
                $f = @(Get-OrtCrateEnvFinding -OnnxRoot $good -Environment (New-OrtCrateEnv -Root $good @edit))
                Assert-Equal 1 $f.Count "exactly one finding for /$($c.Want)/"
                Assert-Match $c.Want ($f -join ';') 'names the variable and the consequence'
            }
            foreach ($missing in @(@{ NoLib = $true; Want = 'has no onnxruntime\.lib' }, @{ NoDll = $true; Want = 'onnxruntime\.dll does not exist' })) {
                $sw = @{}
                foreach ($k in 'NoLib', 'NoDll') { if ($missing.ContainsKey($k)) { $sw[$k] = $true } }
                $bare = New-ChainOrtRoot -Dir (Join-Path $dir ([guid]::NewGuid().ToString('N'))) @sw
                Assert-Match $missing.Want (@(Get-OrtCrateEnvFinding -OnnxRoot $bare -Environment (New-OrtCrateEnv -Root $bare)) -join ';') 'a pointer at a file that is not there'
            }
        }
    }

    It 'fails closed on an unset ONNX_ROOT and reads the process env when no -Environment is given' {
        Assert-Match 'ONNX_ROOT is unset' (@(Get-OrtCrateEnvFinding -OnnxRoot '' -Environment @{}) -join ';') 'no root, no verdict'
        Invoke-InTestDir { param($dir)
            $root = New-ChainOrtRoot -Dir $dir
            $vars = @{}
            foreach ($n in $script:OrtEnvNames) { $vars[$n] = $null }
            foreach ($kv in (New-OrtCrateEnv -Root $root).GetEnumerator()) { $vars[$kv.Key] = $kv.Value }
            Invoke-WithEnv -Vars $vars -Body { Assert-Equal 0 @(Get-OrtCrateEnvFinding -OnnxRoot $root).Count 'process env, healthy' }
            $vars['ORT_SKIP_DOWNLOAD'] = $null
            Invoke-WithEnv -Vars $vars -Body { Assert-Match 'ORT_SKIP_DOWNLOAD' (@(Get-OrtCrateEnvFinding -OnnxRoot $root) -join ';') 'process env, unset var' }
        }
    }
}

Describe 'Smoke §19: ort crate env wiring' {
    $ast = Get-TestScriptAst -ScriptPath $script:CrateSmoke
    $src = $ast.Extent.Text
    $check = @(Get-TestAstCommands -Ast $ast -Name 'Assert-Test' | Where-Object { $_.Extent.Text -like 'Assert-Test*$ortCrateFindings*' })
    $sourceCall = @(Get-TestAstCommands -Ast $ast -Name 'Get-OrtCrateEnvFinding')
    $source = @($sourceCall | ForEach-Object { Get-TestAstAncestor -Node $_ -Type ([AssignmentStatementAst]) -First })

    It 'asserts zero findings from the process env, inside section 19, under no lane condition (mutation)' {
        Assert-Equal '1/1' "$($check.Count)/$($source.Count)" 'one ort crate env assertion, fed by one findings assignment'
        Assert-Equal '$ortCrateFindings' (Get-TestCommandArguments -Command $check[0]).Finding 'passes on zero findings only'
        Assert-Match '^@\(Get-OrtCrateEnvFinding -OnnxRoot \$env:ONNX_ROOT\)$' $source[0].Right.Extent.Text 'the image env, not a fixture'
        $guards = @(
            Get-TestAstAncestor -Node $check[0] -Type ([IfStatementAst])
            Get-TestAstAncestor -Node $source[0] -Type ([IfStatementAst])
        )
        Assert-Equal 0 $guards.Count 'every lane: no enclosing if'
        $at = $check[0].Extent.StartOffset
        Assert-True ($src.IndexOf("Write-TestHeader '19.") -lt $at -and $at -lt $src.IndexOf("Write-TestHeader '20.")) 'counted in section 19, whose floors it raised'
    }

    It 'rejects a malformed source mutation before inspecting declarations' {
        Invoke-InTestDir { param($dir)
            $mutatedPath = Join-Path $dir 'Test-Container-malformed.ps1'
            $malformed = [IO.File]::ReadAllText($script:CrateSmoke) + "`nfunction Broken {"
            [IO.File]::WriteAllText($mutatedPath, $malformed)
            Assert-Throws {
                $mutatedAst = Get-TestScriptAst -ScriptPath $mutatedPath -ErrorLabel 'mutated Test-Container.ps1'
                $null = Get-TestAstCommands -Ast $mutatedAst -Name 'Assert-Test'
            } -MessagePattern 'mutated Test-Container\.ps1: parse errors'
        }
    }

    It 'expects exactly the values windows/Dockerfile bakes (mutation)' {
        # file | pattern: the four baked values, then the custody chain ONNX_ROOT -> the chain install dir.
        $pins = @(
            'windows\Dockerfile|(?m)ENV ORT_LIB_LOCATION=\$ONNX_ROOT\\lib `\r?$'
            'windows\Dockerfile|(?m)^\s+ORT_PREFER_DYNAMIC_LINK=1 `\r?$'
            'windows\Dockerfile|(?m)^\s+ORT_SKIP_DOWNLOAD=1 `\r?$'
            'windows\Dockerfile|(?m)^\s+ORT_DYLIB_PATH=\$ONNX_ROOT\\bin\\onnxruntime\.dll\r?$'
            'windows\Dockerfile.media-merge-builder|ONNX_ROOT="C:\\runtime\\lib\\onnxruntime-source"'
            'windows\scripts\build\Build-OnnxFromSource.ps1|\$ortInstallDir = "\$InstallDir\\lib\\onnxruntime-source"'
        )
        foreach ($pin in $pins) {
            $file, $pattern = $pin -split '\|', 2
            Assert-Match $pattern (Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) $file)) "$file pins /$pattern/"
        }
    }
}

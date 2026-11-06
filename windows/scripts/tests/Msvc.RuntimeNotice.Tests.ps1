#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The MSVC runtime ships only with its notice; MSI parsing itself is covered by the package licence suites.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsMsvcRuntimeNotice.Common.psm1') -DisableNameChecking -Force
# Linux runners name the interpreter python3.
$script:noticePython = @(Get-Command python, python3 -CommandType Application -ErrorAction SilentlyContinue)[0].Source

function New-MsvcNoticeFixture {
    param([string]$Dir, [string]$Dll = '')
    $vs = Join-Path $Dir 'vs'
    foreach ($lcid in '1031', '1033') {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $vs "Licenses/$lcid")
        Set-Content -LiteralPath (Join-Path $vs "Licenses/$lcid/Redist.txt") -Value "terms $lcid https://aka.ms/vs/18/redistribution.lic" -NoNewline
    }
    $bundle = Join-Path $Dir 'bundle'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'bin')
    foreach ($name in @('app.exe') + @($Dll | Where-Object { $_ })) { Set-Content -LiteralPath (Join-Path $bundle "bin/$name") -Value $name }
    return [pscustomobject]@{ Vs = $vs; Bundle = $bundle }
}

function New-MsvcNoticeZip {
    param([string]$Source, [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($Source, $Path, [IO.Compression.CompressionLevel]::Fastest, $true)
}

Describe 'Copy-MsvcRuntimeNotice' {
    It 'stages the English Redist.txt and the end-user notice only when the bundle carries the runtime' {
        Invoke-InTestDir { param($d)
            $f = New-MsvcNoticeFixture -Dir $d
            Assert-Equal $null (Copy-MsvcRuntimeNotice -Root $f.Bundle -VsInstallDir $f.Vs 6>$null) 'no runtime, no notice'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Bundle 'licenses')) 'nothing staged without the runtime'
            Set-Content -LiteralPath (Join-Path $f.Bundle 'bin/vcruntime140_1.dll') -Value 'dll'
            $staged = Copy-MsvcRuntimeNotice -Root $f.Bundle -VsInstallDir $f.Vs 6>$null
            Assert-Equal ((Join-Path $f.Bundle 'licenses/msvc-runtime/Redist.txt') -replace '\\', '/') ($staged -replace '\\', '/')
            Assert-Equal 'terms 1033 https://aka.ms/vs/18/redistribution.lic' (Get-Content -Raw -LiteralPath $staged)
            $readme = Get-Content -Raw -LiteralPath (Join-Path $f.Bundle 'licenses/msvc-runtime/README.txt')
            Assert-Match 'DRAFT' $readme
            Assert-Match ([regex]::Escape('https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution')) $readme
        }
    }

    It 'refuses a runtime it cannot ship with its terms' {
        Invoke-InTestDir { param($d)
            $f = New-MsvcNoticeFixture -Dir $d -Dll 'msvcp140.dll'
            Assert-Throws { Copy-MsvcRuntimeNotice -Root $f.Bundle -VsInstallDir (Join-Path $d 'missing') 6>$null } -MessagePattern 'cannot ship with its notice'
        }
    }
}

Describe 'Assert-PackageMsvcRuntimeNotice' {
    It 'fails a ZIP or MSIX that carries the runtime without its notice and passes one with it' {
        Invoke-InTestDir { param($d)
            $f = New-MsvcNoticeFixture -Dir $d -Dll 'vcruntime140.dll'
            foreach ($ext in '.zip', '.msix') {
                $pkg = Join-Path $d "app$ext"
                New-MsvcNoticeZip -Source $f.Bundle -Path $pkg
                Assert-Throws { Assert-PackageMsvcRuntimeNotice -PythonPath $script:noticePython -Path $pkg -RedistText (Join-Path $f.Vs 'Licenses/1033/Redist.txt') } -MessagePattern 'ships only with its notice'
            }
            $staged = Copy-MsvcRuntimeNotice -Root $f.Bundle -VsInstallDir $f.Vs 6>$null
            foreach ($ext in '.zip', '.msix') {
                $pkg = Join-Path $d "app$ext"
                New-MsvcNoticeZip -Source $f.Bundle -Path $pkg
                Assert-PackageMsvcRuntimeNotice -PythonPath $script:noticePython -Path $pkg -RedistText $staged *> $null
                Assert-Throws { Assert-PackageMsvcRuntimeNotice -PythonPath $script:noticePython -Path $pkg -RedistText (Join-Path $f.Vs 'Licenses/1031/Redist.txt') *> $null } -MessagePattern 'verification failed'
                Assert-Throws { Assert-PackageMsvcRuntimeNotice -Path $pkg } -MessagePattern 'no -RedistText'
            }
        }
    }

    It 'asks nothing of a package without the runtime' {
        Invoke-InTestDir { param($d)
            $f = New-MsvcNoticeFixture -Dir $d
            $pkg = Join-Path $d 'app.zip'
            New-MsvcNoticeZip -Source $f.Bundle -Path $pkg
            Assert-PackageMsvcRuntimeNotice -Path $pkg
        }
    }
}

Describe 'Every Windows package path stages and checks the notice' {
    It 'stages the notice in the Python app bundle after its runtime closure' {
        $bundle = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/python/New-PythonAppBundle.ps1')
        Assert-True ($bundle.IndexOf('Copy-PythonAppRuntimeClosure') -lt $bundle.IndexOf('Copy-MsvcRuntimeNotice -Root $bundle')) 'the bundle stages the notice after its runtime closure'
    }

    It 'stages a closure-added runtime and checks each CPack installer in New-PortableBundle' {
        $body = (Get-Command New-PortableBundle -Module WindowsCrossBundle.Common -ErrorAction SilentlyContinue)
        if (-not $body) {
            Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsCrossBundle.Common.psm1') -DisableNameChecking -Force
            $body = Get-Command New-PortableBundle -Module WindowsCrossBundle.Common
        }
        $text = $body.Definition
        Assert-True ($text.IndexOf('Copy-PeImportClosure') -lt $text.IndexOf('Copy-MsvcRuntimeNotice -Root $bundle')) 'stages after the closure'
        Assert-Match '\$PackageCheck = \{ param\(\$Path, \$RedistText\) Assert-PackageMsvcRuntimeNotice -Path \$Path -RedistText \$RedistText \}' $body.ScriptBlock.Ast.Extent.Text
        Assert-Match '& \$PackageCheck \$installer\.FullName \$redist' $text
    }
}

#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: wix build and msiexec (New-PythonAppPackage.ps1 runs both inside :winamd64, installing and uninstalling).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsMsix.Common.psm1') -DisableNameChecking

function script:New-TestApp {
    param([string]$Name = 'Demo')
    return @{ name = $Name; id = 'demo'; publisher = 'Pub & Co'; description = 'A <demo>'; homepage = 'https://example.invalid/demo'
        scripts = @('demo-gui', 'demo-cli'); gui_script = 'demo-gui'; msi_upgrade_code = '{B7345903-A839-44F0-9784-35FA77657D53}' }
}

if ($IsWindows) { Describe 'ConvertTo-PythonAppIcon' {

    It 'wraps the PNG as the one image of an .ico, 256 stored as 0' {
        Invoke-InTestDir { param($d)
            foreach ($size in 1, 256) {
                if ($size -eq 256) { Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'images/logo.png') -Destination "$d\logo.png" }
                else {
                    $onePixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/jPwPAfAAUAAf+mXJtdAAAAAElFTkSuQmCC'
                    [IO.File]::WriteAllBytes("$d\logo.png", [Convert]::FromBase64String($onePixel))
                }
                $png = [IO.File]::ReadAllBytes("$d\logo.png")
                $ico = [IO.File]::ReadAllBytes((ConvertTo-PythonAppIcon -PngPath "$d\logo.png" -Destination "$d\app.ico"))
                Assert-Equal '0,1,1' "$([BitConverter]::ToUInt16($ico, 0)),$([BitConverter]::ToUInt16($ico, 2)),$([BitConverter]::ToUInt16($ico, 4))" "$size`: ICONDIR"
                Assert-Equal ($size % 256) ([int]$ico[6]) "$size`: width byte"
                Assert-Equal "$($png.Length),22" "$([BitConverter]::ToUInt32($ico, 14)),$([BitConverter]::ToUInt32($ico, 18))" "$size`: size and offset"
                Assert-Equal ([Convert]::ToBase64String($png)) ([Convert]::ToBase64String($ico[22..($ico.Length - 1)])) "$size`: the PNG itself"
            }
        }
    }

    It 'refuses a file that is no PNG, and a PNG larger than an .ico entry holds' {
        Invoke-InTestDir { param($d)
            Set-Content -LiteralPath "$d\logo.png" -Value 'not an image at all, just text' -Encoding ASCII
            Assert-Throws { ConvertTo-PythonAppIcon -PngPath "$d\logo.png" -Destination "$d\a.ico" } -MessagePattern 'is not a PNG'
            $png = [IO.File]::ReadAllBytes((Join-Path (Get-RepoRoot) 'images/logo.png'))
            $png[18] = 2; $png[19] = 0; $png[22] = 2; $png[23] = 0
            [IO.File]::WriteAllBytes("$d\big.png", $png)
            Assert-Throws { ConvertTo-PythonAppIcon -PngPath "$d\big.png" -Destination "$d\b.ico" } -MessagePattern '512x512'
        }
    }

    It 'rejects a truncated PNG' {
        Invoke-InTestDir { param($d)
            $bad = Join-Path $d 'truncated.png'
            [IO.File]::WriteAllBytes($bad, [byte[]](0x89,0x50,0x4e,0x47,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1))
            Assert-Throws { ConvertTo-PythonAppIcon -PngPath $bad -Destination "$d\bad.ico" } -MessagePattern 'not a readable image'
        }
    }

    It 'rejects a completely transparent PNG' {
        Invoke-InTestDir { param($d)
            $blank = Join-Path $d 'transparent.png'
            New-TransparentPng -Path $blank -Width 1 -Height 1
            Assert-Throws { ConvertTo-PythonAppIcon -PngPath $blank -Destination "$d\blank.ico" } -MessagePattern 'visible PNG'
        }
    }
} }

Describe 'New-PythonAppWxs' {

    It 'lists every file in its folder, escapes names, and wires the shortcut, PATH and upgrade' {
        Invoke-InTestDir { param($d)
            $bundle = "$d\bundle"
            New-Item -ItemType Directory -Force -Path "$bundle\runtime\Lib", "$bundle\share" | Out-Null
            foreach ($f in 'demo-gui.exe', 'demo-cli.exe', 'runtime\python.exe', 'runtime\Lib\a&b.py', 'share\model.onnx') { Set-Content -LiteralPath "$bundle\$f" 'x' -Encoding ASCII }
            $wxs = New-PythonAppWxs -Bundle $bundle -App (New-TestApp) -Version '0.0.28' -IconPath "$d\app.ico" -Destination "$d\demo.wxs"
            [xml]$xml = Get-Content -LiteralPath $wxs -Raw
            $ns = @{ w = 'http://wixtoolset.org/schemas/v4/wxs' }
            $package = (Select-Xml -Xml $xml -XPath '/w:Wix/w:Package' -Namespace $ns).Node
            Assert-Equal 'Demo|Pub & Co|0.0.28|perMachine' "$($package.Name)|$($package.Manufacturer)|$($package.Version)|$($package.Scope)" 'package'
            $files = @(Select-Xml -Xml $xml -XPath '//w:ComponentGroup[@Id="AppFiles"]/w:Component/w:File' -Namespace $ns | ForEach-Object { $_.Node.Source.Substring($bundle.Length + 1) })
            Assert-Equal 'demo-cli.exe,demo-gui.exe,runtime\Lib\a&b.py,runtime\python.exe,share\model.onnx' (($files | Sort-Object) -join ',') 'every file once'
            $libDir = (Select-Xml -Xml $xml -XPath '//w:Directory[@Id="INSTALLFOLDER"]/w:Directory[@Name="runtime"]/w:Directory[@Name="Lib"]' -Namespace $ns).Node
            $libFile = (Select-Xml -Xml $xml -XPath "//w:Component[@Directory=`"$($libDir.Id)`"]/w:File" -Namespace $ns).Node
            Assert-True ($libFile.Source.EndsWith('runtime\Lib\a&b.py')) 'a file is installed into its own folder'
            $refs = @(Select-Xml -Xml $xml -XPath '//w:Feature[@Id="Main"]/*' -Namespace $ns | ForEach-Object { $_.Node.Id })
            Assert-Equal 'AppFiles,PathEntry,StartMenuShortcut' ($refs -join ',') 'the one feature installs all of it'
            $shortcut = (Select-Xml -Xml $xml -XPath '//w:Shortcut' -Namespace $ns).Node
            Assert-Equal '[INSTALLFOLDER]demo-gui.exe|A <demo>' "$($shortcut.Target)|$($shortcut.Description)" 'gui_script, description escaped'
            $path = (Select-Xml -Xml $xml -XPath '//w:Environment' -Namespace $ns).Node
            Assert-Equal 'PATH|[INSTALLFOLDER]|last|yes|no' "$($path.Name)|$($path.Value)|$($path.Part)|$($path.System)|$($path.Permanent)" 'on PATH until uninstalled'
            Assert-NotNull (Select-Xml -Xml $xml -XPath '//w:MajorUpgrade' -Namespace $ns) 'an older version is replaced'
        }
    }

    It 'refuses what an MSI cannot carry: no upgrade code, a four-part version, a path past MAX_PATH' {
        Invoke-InTestDir { param($d)
            New-Item -ItemType Directory -Force -Path "$d\bundle" | Out-Null
            Set-Content -LiteralPath "$d\bundle\demo-gui.exe" 'x' -Encoding ASCII
            $app = New-TestApp
            $app.Remove('msi_upgrade_code')
            Assert-Throws { New-PythonAppWxs -Bundle "$d\bundle" -App $app -Version '1.0.0' -IconPath 'x' -Destination "$d\a.wxs" } -MessagePattern 'msi_upgrade_code'
            Assert-Throws { New-PythonAppWxs -Bundle "$d\bundle" -App (New-TestApp) -Version '1.0.0.4' -IconPath 'x' -Destination "$d\a.wxs" } -MessagePattern 'major.minor.build'
            Assert-Throws { New-PythonAppWxs -Bundle "$d\bundle" -App (New-TestApp -Name ('N' * 240)) -Version '1.0.0' -IconPath 'x' -Destination "$d\a.wxs" } -MessagePattern 'MSI stops at 259'
        }
    }
}

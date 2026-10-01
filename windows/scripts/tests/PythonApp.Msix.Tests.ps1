#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: makeappx and signtool (New-PythonAppPackage.ps1 runs both inside :winamd64, then verifies against the .cer).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonApp.Common.psm1') -Force -DisableNameChecking

function script:New-TestMsixApp {
    return @{ name = 'Demo App'; id = 'demo'; publisher = 'Pub Lisher'; description = 'A <demo> & more'
        scripts = @('demo-gui', 'demo-cli'); gui_script = 'demo-gui' }
}

Describe 'New-PythonAppAppxManifest' {

    It 'gives every script a console app with its own alias, and lists only gui_script in Start' {
        Invoke-InTestDir { param($d)
            $path = New-PythonAppAppxManifest -App (New-TestMsixApp) -Version '1.2.3' -Publisher 'CN=Pub Lisher' -Destination "$d\AppxManifest.xml"
            [xml]$xml = Get-Content -LiteralPath $path -Raw
            Assert-Equal 'PubLisher.DemoApp|CN=Pub Lisher|1.2.3.0' "$($xml.Package.Identity.Name)|$($xml.Package.Identity.Publisher)|$($xml.Package.Identity.Version)" 'identity'
            $apps = @($xml.Package.Applications.Application)
            Assert-Equal 'demogui,democli' (($apps | ForEach-Object Id) -join ',') 'one app per script'
            Assert-Equal 'demo-gui.exe,demo-cli.exe' (($apps | ForEach-Object { $_.Extensions.Extension.AppExecutionAlias.ExecutionAlias.Alias }) -join ',') 'aliases'
            $desktop4 = 'http://schemas.microsoft.com/appx/manifest/desktop/windows10/4'
            Assert-Equal 'console,console' (($apps | ForEach-Object { $_.GetAttribute('Subsystem', $desktop4) }) -join ',') 'console launchers'
            # makeappx rejects a console subsystem without it (error 80080204, measured in :winamd64).
            Assert-Equal 'true,true' (($apps | ForEach-Object { $_.GetAttribute('SupportsMultipleInstances', $desktop4) }) -join ',') 'multiple instances'
            Assert-Equal '|none' (($apps | ForEach-Object { $_.VisualElements.GetAttribute('AppListEntry') }) -join '|') 'only the GUI script is listed'
            Assert-Equal 'A <demo> & more' $xml.Package.Properties.Description 'escaped and read back'
        }
    }

    It 'refuses what MSIX or the signing certificate cannot carry' {
        Invoke-InTestDir { param($d)
            Assert-Throws { New-PythonAppAppxManifest -App (New-TestMsixApp) -Version '1.2.3.4' -Publisher 'CN=Pub' -Destination "$d\a.xml" } -MessagePattern 'major\.minor\.build'
            Assert-Throws { New-PythonAppAppxManifest -App (New-TestMsixApp) -Version '1.2.3' -Publisher 'CN=Pub, O=Org' -Destination "$d\a.xml" } -MessagePattern 'must be CN='
            $app = New-TestMsixApp
            $app['scripts'] = @('a-b', 'ab')
            Assert-Throws { New-PythonAppAppxManifest -App $app -Version '1.2.3' -Publisher 'CN=Pub' -Destination "$d\a.xml" } -MessagePattern 'not a unique id'
        }
    }
}

Describe 'New-PythonAppSigningCertificate' {

    It 'writes a code-signing .pfx with its key and the matching .cer, without any certificate store' {
        Invoke-InTestDir { param($d)
            $before = @(Get-ChildItem Cert:\CurrentUser\My).Count
            $thumbprint = New-PythonAppSigningCertificate -Subject 'CN=Pub Lisher' -PfxPath "$d\t.pfx" -CerPath "$d\t.cer"
            $pfx = [Security.Cryptography.X509Certificates.X509Certificate2]::new("$d\t.pfx")
            $cer = [Security.Cryptography.X509Certificates.X509Certificate2]::new("$d\t.cer")
            Assert-Equal "CN=Pub Lisher|$thumbprint|$thumbprint" "$($pfx.Subject)|$($pfx.Thumbprint)|$($cer.Thumbprint)" 'subject and one thumbprint'
            Assert-True $pfx.HasPrivateKey 'the .pfx can sign'
            Assert-False $cer.HasPrivateKey 'the .cer cannot'
            Assert-Equal '1.3.6.1.5.5.7.3.3' (@($pfx.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })[0].EnhancedKeyUsages[0].Value) 'code signing'
            Assert-Equal $before @(Get-ChildItem Cert:\CurrentUser\My).Count 'no store touched'
        }
    }
}

#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A local tagged repository stands in for flutter/flutter; the workflow steps and flutter.bat run only in consumer CI.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsFlutterPin.Common.psm1') -Force

function Invoke-FlutterPinFixture {
    param([string]$Version, [string]$Commit, [scriptblock]$Body, [string]$Override)
    $fromEnv = if ($Override) { $Override } else { $null }
    Invoke-WithEnv @{ FLUTTER_VERSION = $fromEnv } {
        Invoke-InTestDir -Prefix 'flutterpin-' -Body { param($dir)
            $repo = Join-Path $dir 'repo'
            $null = New-Item -ItemType Directory -Path $repo
            & git -C $repo init -q
            & git -C $repo -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m r
            & git -C $repo tag 1.2.3
            $head = (& git -C $repo rev-parse HEAD)
            Write-TestFileTree -Root $dir -Files @{
                'core/versions.env'  = "FLUTTER_VERSION=$Version`n"
                'core/tool-pins.env' = "FLUTTER_COMMIT=$($Commit -replace '^HEAD$', $head)`n"
            }
            & $Body (Join-Path $dir 'core') $repo (Join-Path $dir 'sdk') $head
        }
    }
}

function Assert-FlutterInstallRefused {
    param([string]$Version, [string]$Commit, [string]$Message)
    Invoke-FlutterPinFixture $Version $Commit { param($core, $url, $sdk)
        Assert-Throws { Install-PinnedFlutterSdk -Destination $sdk -RepositoryUrl $url -CoreDir $core } -MessagePattern $Message
    }.GetNewClosure()
}

Describe 'Install-PinnedFlutterSdk' {
    It 'clones the tag at its pinned commit and returns the bin directory' {
        Invoke-FlutterPinFixture '1.2.3' 'HEAD' { param($core, $url, $sdk, $head)
            $bin = Install-PinnedFlutterSdk -Destination $sdk -RepositoryUrl $url -CoreDir $core
            Assert-Equal (Join-Path $sdk 'bin') $bin
            Assert-Equal $head (& git -C $sdk rev-parse HEAD)
        }
    }

    It 'refuses a tag that is not the pinned commit' {
        Assert-FlutterInstallRefused '1.2.3' ('0' * 40) 'not the pinned FLUTTER_COMMIT'
    }

    It 'fails on a missing tag' {
        Assert-FlutterInstallRefused '9.9.9' 'HEAD' 'cloning Flutter 9.9.9 failed'
    }
}

Describe 'Resolve-FlutterPin' {
    It 'refuses half a pin and names the key' {
        Invoke-FlutterPinFixture '' 'HEAD' { param($core)
            Assert-Throws { Resolve-FlutterPin -CoreDir $core } -MessagePattern 'FLUTTER_VERSION is not set'
        }
    }

    It 'lets a caller FLUTTER_VERSION win with no commit to check' {
        Invoke-FlutterPinFixture '1.2.3' ('0' * 40) -Override '1.2.3' -Body { param($core, $url, $sdk)
            $pin = Resolve-FlutterPin -CoreDir $core 3>$null
            Assert-Equal '1.2.3' $pin.Version
            Assert-Equal '' $pin.Commit
            $null = Install-PinnedFlutterSdk -Destination $sdk -RepositoryUrl $url -CoreDir $core 3>$null
        }
    }

    It 'pins the real commit in the tool pins beside the version' {
        Assert-Match '^[0-9a-f]{40}$' (Resolve-FlutterPin).Commit
    }
}

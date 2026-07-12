# Tests for the canonical versions.env parser and the shared zip-extract helper
# (ConvertFrom-VersionsEnv / Expand-ArchiveSubdirectory in WindowsScripts.Shared.psm1).

Describe 'ConvertFrom-VersionsEnv' {

    # Helper: write $Lines to a versions.env in $Dir and parse it.
    function ConvertFrom-TestEnvFile {
        param([string]$Dir, [string[]]$Lines)
        $f = Join-Path $Dir 'versions.env'
        Set-Content -Path $f -Value $Lines -Encoding ASCII
        return (ConvertFrom-VersionsEnv -Path $f)
    }

    It 'parses key=value pairs, trimming surrounding whitespace' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('  A = 1 ', 'B=two')
            Assert-Equal '1' $v['A']
            Assert-Equal 'two' $v['B']
        }
    }

    It 'skips comments and blank lines' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('# comment', '', 'A=1', '  # indented comment')
            Assert-Equal 1 $v.Count
        }
    }

    It 'splits on the FIRST = only (values may contain =)' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('FLAGS=-DFOO=1;-DBAR=2')
            Assert-Equal '-DFOO=1;-DBAR=2' $v['FLAGS']
        }
    }

    It 'strips surrounding double and single quotes from values' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('A="quoted"', "B='single'")
            Assert-Equal 'quoted' $v['A']
            Assert-Equal 'single' $v['B']
        }
    }

    It 'preserves file order (ordered-dictionary contract)' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('Z=1', 'A=2', 'M=3')
            Assert-Equal 'Z,A,M' (@($v.Keys) -join ',')
        }
    }

    It 'supports .Contains membership tests (build.ps1 Get-Ver contract)' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('A=1')
            Assert-True ($v.Contains('A')) 'existing key'
            Assert-False ($v.Contains('MISSING')) 'missing key'
        }
    }

    It 'returns an empty dictionary for a comments-only file' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('# only', '# comments')
            Assert-Equal 0 $v.Count
        }
    }
}

Describe 'Expand-ArchiveSubdirectory' {

    # Helper: zip a <Name>\inner.txt payload inside $Dir and return the zip path.
    function New-TestZip {
        param([string]$Dir, [string]$Name)
        $payload = Join-Path $Dir $Name
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        Set-Content -Path (Join-Path $payload 'inner.txt') -Value 'x' -NoNewline
        $zip = Join-Path $Dir "$Name.zip"
        Compress-Archive -Path $payload -DestinationPath $zip
        return $zip
    }

    It 'extracts and returns the matching top-level directory' {
        Invoke-InTestDir { param($dir)
            $zip = New-TestZip -Dir $dir -Name 'vcpkg-2024.07.12'
            $r = Expand-ArchiveSubdirectory -ArchivePath $zip -DestinationPath (Join-Path $dir 'out') -Filter 'vcpkg-*'
            Assert-Equal 'vcpkg-2024.07.12' (Split-Path $r -Leaf)
            Assert-True (Test-Path (Join-Path $r 'inner.txt')) 'payload file extracted'
        }
    }

    It 'creates the destination directory when missing' {
        Invoke-InTestDir { param($dir)
            $zip = New-TestZip -Dir $dir -Name 'TensorRT-10.5'
            $dest = Join-Path $dir 'brand\new\dest'
            $r = Expand-ArchiveSubdirectory -ArchivePath $zip -DestinationPath $dest
            Assert-True (Test-Path $dest) 'destination created'
            Assert-Equal 'TensorRT-10.5' (Split-Path $r -Leaf)
        }
    }

    It 'returns $null for a flat-layout zip (no matching subdir) but still extracts it' {
        Invoke-InTestDir { param($dir)
            $flat = Join-Path $dir 'file.txt'
            Set-Content -Path $flat -Value 'x' -NoNewline
            $zip = Join-Path $dir 'flat.zip'
            Compress-Archive -Path $flat -DestinationPath $zip
            $dest = Join-Path $dir 'out'
            Assert-Null (Expand-ArchiveSubdirectory -ArchivePath $zip -DestinationPath $dest -Filter 'TensorRT-*')
            Assert-True (Test-Path (Join-Path $dest 'file.txt')) 'flat payload still extracted'
        }
    }
}

#requires -Version 7.0
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

Describe 'Save-PythonWheel' {

    It 'returns exactly the staged path for a single wheel (callers MUST @()-wrap: unwrap made [0] the first CHAR -> pip installed PyPI package "c")' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'dist'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            Set-Content -Path (Join-Path $src 'pkg-1.0-py3-none-any.whl') -Value 'x' -NoNewline
            $store = Join-Path $dir 'wheels'
            $r = @(Save-PythonWheel -SourceDir $src -WheelDir $store -Required)
            Assert-Equal 1 $r.Count
            Assert-True (Test-Path $r[0]) 'returned path exists on disk'
            Assert-Equal 'pkg-1.0-py3-none-any.whl' (Split-Path $r[0] -Leaf)
        }
    }

    It 'throws with -Required when no wheel matches' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Save-PythonWheel -SourceDir $dir -WheelDir (Join-Path $dir 'w') -Required }
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

Describe 'Get-MediaBranchVersionArg completeness (versions.env COPY removed 2026-08-07)' {

    # These maps are now the ONLY channel by which current version values reach
    # a branch's build scripts: the media stages no longer COPY versions.env,
    # because that COPY made every pin edit invalidate all six media compiles.
    # A key a script reads but that is missing here silently falls back to the
    # value baked into the base image. The audit that produced these lists found
    # five such gaps; these cases stop them coming back.

    It 'passes every key the media-core scripts consume' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $args_ = Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $v
        foreach ($k in 'ONNXRUNTIME_VERSION', 'ONNXRUNTIME_GENAI_VERSION', 'OPENCV_SOURCE_VERSION',
                       'OPENCV_VERSION', 'FFMPEG_VERSION', 'PYAV_VERSION', 'NV_CODEC_HEADERS_REF',
                       'CUDA_ARCHITECTURES', 'PYTHON_VERSION') {
            Assert-True ($args_.ContainsKey($k)) "media-core must forward $k"
            Assert-True ([bool]$args_[$k]) "$k must not be empty"
        }
    }

    It 'passes the litert keys INCLUDING the protoc/JRE pins' {
        # PROTOC_VERSION must match LiteRT-LM's internal protobuf; a stale value
        # emits gencode the pinned headers #error on.
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $args_ = Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $v
        foreach ($k in 'LITERT_VERSION', 'LITERT_LM_VERSION', 'PROTOC_VERSION', 'JRE_VERSION') {
            Assert-True ($args_.ContainsKey($k)) "media-litert must forward $k"
            Assert-True ([bool]$args_[$k]) "$k must not be empty"
        }
    }

    It 'forwards values that actually match versions.env' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $args_ = Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $v
        Assert-Equal $v['PROTOC_VERSION'] $args_['PROTOC_VERSION'] 'forwarded value must be the canonical one'
    }
}

#requires -Version 7.0
# The canonical versions.env parser and the shared zip-extract helper.

Describe 'ConvertFrom-VersionsEnv' {

    # Helper: write $Lines to a versions.env in $Dir and parse it.
    function ConvertFrom-TestEnvFile {
        param([string]$Dir, [string[]]$Lines)
        $f = Join-Path $Dir 'versions.env'
        Set-Content -Path $f -Value $Lines -Encoding ASCII
        return (ConvertFrom-VersionsEnv -Path $f)
    }

    foreach ($parseCase in @(
        @{ Name = 'parses key=value pairs, trimming surrounding whitespace'; Lines = @('  A = 1 ', 'B=two'); Expected = [ordered]@{ A = '1'; B = 'two' } },
        @{ Name = 'skips comments and blank lines'; Lines = @('# comment', '', 'A=1', '  # indented comment'); Expected = [ordered]@{ A = '1' } },
        @{ Name = 'splits on the FIRST = only (values may contain =)'; Lines = @('FLAGS=-DFOO=1;-DBAR=2'); Expected = [ordered]@{ FLAGS = '-DFOO=1;-DBAR=2' } },
        @{ Name = 'strips surrounding double and single quotes from values'; Lines = @('A="quoted"', "B='single'"); Expected = [ordered]@{ A = 'quoted'; B = 'single' } },
        @{ Name = 'preserves file order (ordered-dictionary contract)'; Lines = @('Z=1', 'A=2', 'M=3'); Expected = [ordered]@{ Z = '1'; A = '2'; M = '3' } },
        @{ Name = 'returns an empty dictionary for a comments-only file'; Lines = @('# only', '# comments'); Expected = [ordered]@{} }
    )) {
        It $parseCase.Name {
            Invoke-InTestDir { param($dir)
                $versions = ConvertFrom-TestEnvFile -Dir $dir -Lines $parseCase.Lines
                Assert-Equal ($parseCase.Expected.Keys -join ',') ($versions.Keys -join ',') 'exact keys and file order'
                foreach ($key in $parseCase.Expected.Keys) { Assert-Equal $parseCase.Expected[$key] $versions[$key] }
            }
        }
    }

    It 'supports .Contains membership tests (driver Get-Ver contract)' {
        Invoke-InTestDir { param($dir)
            $v = ConvertFrom-TestEnvFile -Dir $dir -Lines @('A=1')
            Assert-True ($v.Contains('A')) 'existing key'
            Assert-False ($v.Contains('MISSING')) 'missing key'
        }
    }


}

Describe 'Get-ANTfrastructurePin' {

    foreach ($pinCase in @(
        @{ Name = 'takes the environment first, so an image build-arg beats a stale file'; Lines = 'WBT_TOOL_VERSION=1.0.0'; Environment = '2.0.0'; Expected = '2.0.0'; Error = '' },
        @{ Name = 'falls back to versions.env when the environment does not set it'; Lines = 'WBT_TOOL_VERSION=1.0.0'; Environment = $null; Expected = '1.0.0'; Error = '' },
        @{ Name = 'throws on a key nowhere to be found, rather than letting the newest release win'; Lines = 'OTHER=1'; Environment = $null; Expected = ''; Error = 'WBT_TOOL_VERSION is not set' }
    )) {
        It $pinCase.Name {
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir 'versions.env'
                Set-Content -LiteralPath $path -Value $pinCase.Lines -Encoding ASCII
                Invoke-WithEnv -Vars @{ WBT_TOOL_VERSION = $pinCase.Environment } -Body {
                    $readPin = { Get-ANTfrastructurePin -Name 'WBT_TOOL_VERSION' -VersionsEnvPath $path }
                    if ($pinCase.Error) { Assert-Throws -Body $readPin -MessagePattern $pinCase.Error }
                    else { Assert-Equal $pinCase.Expected (& $readPin) }
                }
            }
        }
    }

    It "defaults to the hub's own versions.env" {
        Invoke-WithEnv -Vars @{ CARGO_AUDIT_VERSION = $null } -Body {
            Assert-True ((Get-ANTfrastructurePin -Name 'CARGO_AUDIT_VERSION') -match '^\d+\.\d+') 'a version from the real file'
        }
    }
}

Describe 'Save-PythonWheel' {

    It 'returns exactly the staged path for a single wheel (callers MUST @()-wrap: unwrap made [0] the first CHAR -> pip installed PyPI package "c")' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'dist'
            Write-TestFileTree -Root $src -Files @{ 'pkg-1.0-py3-none-any.whl' = 'x' }
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
        Write-TestFileTree -Root $payload -Files @{ 'inner.txt' = 'x' }
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

    # These maps are the only channel for versions: a missing key silently falls back to the base image's value.

    $branchPinCases = @(
        @{ Name = 'passes every key the media-core scripts consume'; Branch = 'media-core'; Keys = @(
            'ONNXRUNTIME_VERSION', 'ONNXRUNTIME_GENAI_VERSION', 'OPENCV_SOURCE_VERSION', 'OPENCV_VERSION',
            'FFMPEG_VERSION', 'PYAV_VERSION', 'NV_CODEC_HEADERS_REF', 'AMF_HEADERS_VERSION', 'AMF_HEADERS_SHA256',
            'CUDA_ARCHITECTURES', 'PYTHON_VERSION') },
        @{ Name = 'passes the litert keys INCLUDING the protoc/JRE pins'; Branch = 'media-litert'; Keys = @(
            'LITERT_VERSION', 'LITERT_LM_VERSION', 'PROTOC_VERSION', 'JRE_VERSION') }
    )
    foreach ($pinCase in $branchPinCases) {
        It $pinCase.Name {
            $versions = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
            $forwarded = Get-MediaBranchVersionArg -Branch $pinCase.Branch -VersionTable $versions
            foreach ($key in $pinCase.Keys) {
                Assert-True ($forwarded.ContainsKey($key)) "$($pinCase.Branch) must forward $key"
                Assert-True ([bool]$forwarded[$key]) "$key must not be empty"
            }
        }
    }

    It 'forwards the QNN SDK zip pin to media-core (empty allowed: no zip staged = EP off, #121)' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $args_ = Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $v
        Assert-True ($args_.ContainsKey('QNN_SDK_ZIP_SHA256')) 'media-core must forward QNN_SDK_ZIP_SHA256 (Build-OnnxFromSource.ps1 reads it)'
        Assert-True ($v.Contains('QNN_SDK_ZIP_SHA256')) 'versions.env must declare QNN_SDK_ZIP_SHA256 (may be empty)'
    }

    It 'forwards values that actually match versions.env' {
        $v = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $args_ = Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $v
        Assert-Equal $v['PROTOC_VERSION'] $args_['PROTOC_VERSION'] 'forwarded value must be the canonical one'
    }
}

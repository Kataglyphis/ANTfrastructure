#requires -Version 7.0
# file:// URLs cover Invoke-DownloadWithRetry's retry and non-empty checks without network access.

function Invoke-FileDownloadFixture {
    param([Parameter(Mandatory)][scriptblock]$Body, [byte[]]$Bytes = @(),
        [string]$SourceName = 'src.bin', [string]$DestinationName = 'out.bin', [switch]$Missing)
    $action = $Body
    Invoke-InTestDir -Body { param($dir)
        $source = Join-Path $dir $SourceName
        if (-not $Missing) { [IO.File]::WriteAllBytes($source, $Bytes) }
        & $action ([pscustomobject]@{ Root = $dir; Source = $source; Url = ([Uri]$source).AbsoluteUri; Destination = (Join-Path $dir $DestinationName) })
    }.GetNewClosure()
}

Describe 'Invoke-DownloadWithRetry' {
    It 'downloads a URL to the destination (file:// happy path), creating the parent dir' {
        Invoke-FileDownloadFixture -Bytes ([Text.Encoding]::ASCII.GetBytes("payload-1234$([Environment]::NewLine)")) -DestinationName 'sub\nested\out.bin' -Body { param($file)
            Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0
            Assert-True (Test-Path $file.Destination) 'destination file was created (parent dirs auto-made)'
            Assert-Match 'payload-1234' (Get-Content -LiteralPath $file.Destination -Raw) 'content was downloaded'
        }
    }

    It 'throws after MaxAttempts when the source cannot be fetched, leaving no partial file' {
        Invoke-FileDownloadFixture -SourceName 'does-not-exist.bin' -Missing -Body { param($file)
            Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -MaxAttempts 2 -InitialDelaySeconds 0 } 'an unreachable source must throw after retries'
            Assert-False (Test-Path $file.Destination) 'no partial destination file is left behind'
        }
    }

    It 'rejects a zero-byte download (empty-file guard)' {
        Invoke-FileDownloadFixture -SourceName 'empty.bin' -Body { param($file)
            Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -MaxAttempts 2 -InitialDelaySeconds 0 } 'a zero-byte download must be treated as failure'
            Assert-False (Test-Path $file.Destination) 'the empty partial is cleaned up'
        }
    }

    It 'accepts a download whose magic bytes match -ExpectSignature (MZ)' {
        Invoke-FileDownloadFixture -SourceName 'ok.exe' -DestinationName 'out.exe' -Bytes @(0x4D, 0x5A, 0x90, 0x00) -Body { param($file)
            Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0 -ExpectSignature MZ
            Assert-True (Test-Path $file.Destination) 'a valid MZ file passed the signature guard'
        }
    }

    It 'rejects (and cleans up) an HTML page served in place of an MZ binary' {
        Invoke-FileDownloadFixture -SourceName 'error.html' -DestinationName 'out.exe' -Bytes ([Text.Encoding]::ASCII.GetBytes('<!DOCTYPE html>')) -Body { param($file)
            Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -MaxAttempts 2 -InitialDelaySeconds 0 -ExpectSignature MZ } 'an HTML page served as an .exe must be rejected + retried'
            Assert-False (Test-Path $file.Destination) 'the bad-signature partial is cleaned up'
        }
    }

    It 'accepts a ZIP (PK) signature' {
        Invoke-FileDownloadFixture -SourceName 'ok.zip' -DestinationName 'out.zip' -Bytes @(0x50, 0x4B, 0x03, 0x04) -Body { param($file)
            Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0 -ExpectSignature PK
            Assert-True (Test-Path $file.Destination) 'a valid PK/ZIP file passed the signature guard'
        }
    }

    It 'accepts a download whose SHA256 matches -ExpectedSha256 (case-insensitive)' {
        Invoke-FileDownloadFixture -Bytes ([Text.Encoding]::ASCII.GetBytes("hash-me$([Environment]::NewLine)")) -Body { param($file)
            $sha = (Get-FileHash -Algorithm SHA256 -Path $file.Source).Hash.ToLowerInvariant()
            Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0 -ExpectedSha256 $sha
            Assert-True (Test-Path $file.Destination) 'a matching SHA256 (lowercase pin) passed the hash guard'
        }
    }

    It 'rejects (and cleans up) a download whose SHA256 does not match the pin' {
        Invoke-FileDownloadFixture -Bytes ([Text.Encoding]::ASCII.GetBytes("tampered-content$([Environment]::NewLine)")) -Body { param($file)
            $wrong = 'deadbeef' * 8
            Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -MaxAttempts 2 -InitialDelaySeconds 0 -ExpectedSha256 $wrong } 'a SHA256 mismatch must be rejected after retries'
            Assert-False (Test-Path $file.Destination) 'the mismatching partial is cleaned up'
        }
    }

    It 'applies signature and SHA256 guards together (both must pass)' {
        Invoke-FileDownloadFixture -SourceName 'ok.exe' -DestinationName 'out.exe' -Bytes @(0x4D, 0x5A, 0x90, 0x00) -Body { param($file)
            $sha = (Get-FileHash -Algorithm SHA256 -Path $file.Source).Hash
            Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0 -ExpectSignature MZ -ExpectedSha256 $sha
            Assert-True (Test-Path $file.Destination) 'MZ signature + matching SHA256 passed together'
            $dest2 = Join-Path $file.Root 'out2.exe'
            Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $dest2 -MaxAttempts 1 -InitialDelaySeconds 0 -ExpectSignature MZ -ExpectedSha256 ('ab' * 32) } 'valid signature must not bypass the hash guard'
        }
    }
}

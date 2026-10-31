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
    # A case with a Cleanup message must be rejected; every other case must download.
    foreach ($downloadCase in @(
            @{ Name = 'downloads a URL to the destination (file:// happy path), creating the parent dir'; Fixture = @{ Bytes = ([Text.Encoding]::ASCII.GetBytes("payload-1234$([Environment]::NewLine)")); DestinationName = 'sub\nested\out.bin' }
                Guard = { @{} }; Because = 'destination file was created (parent dirs auto-made)'
                Then = { param($file) Assert-Match 'payload-1234' (Get-Content -LiteralPath $file.Destination -Raw) 'content was downloaded' } },
            @{ Name = 'throws after MaxAttempts when the source cannot be fetched, leaving no partial file'; Fixture = @{ SourceName = 'does-not-exist.bin'; Missing = $true }
                Guard = { @{} }; Because = 'an unreachable source must throw after retries'; Cleanup = 'no partial destination file is left behind' },
            @{ Name = 'rejects a zero-byte download (empty-file guard)'; Fixture = @{ SourceName = 'empty.bin' }
                Guard = { @{} }; Because = 'a zero-byte download must be treated as failure'; Cleanup = 'the empty partial is cleaned up' },
            @{ Name = 'accepts a download whose magic bytes match -ExpectSignature (MZ)'; Fixture = @{ SourceName = 'ok.exe'; DestinationName = 'out.exe'; Bytes = @(0x4D, 0x5A, 0x90, 0x00) }
                Guard = { @{ ExpectSignature = 'MZ' } }; Because = 'a valid MZ file passed the signature guard' },
            @{ Name = 'rejects (and cleans up) an HTML page served in place of an MZ binary'; Fixture = @{ SourceName = 'error.html'; DestinationName = 'out.exe'; Bytes = ([Text.Encoding]::ASCII.GetBytes('<!DOCTYPE html>')) }
                Guard = { @{ ExpectSignature = 'MZ' } }; Because = 'an HTML page served as an .exe must be rejected + retried'; Cleanup = 'the bad-signature partial is cleaned up' },
            @{ Name = 'accepts a ZIP (PK) signature'; Fixture = @{ SourceName = 'ok.zip'; DestinationName = 'out.zip'; Bytes = @(0x50, 0x4B, 0x03, 0x04) }
                Guard = { @{ ExpectSignature = 'PK' } }; Because = 'a valid PK/ZIP file passed the signature guard' },
            @{ Name = 'accepts a download whose SHA256 matches -ExpectedSha256 (case-insensitive)'; Fixture = @{ Bytes = ([Text.Encoding]::ASCII.GetBytes("hash-me$([Environment]::NewLine)")) }
                Guard = { param($file) @{ ExpectedSha256 = (Get-FileHash -Algorithm SHA256 -Path $file.Source).Hash.ToLowerInvariant() } }; Because = 'a matching SHA256 (lowercase pin) passed the hash guard' },
            @{ Name = 'rejects (and cleans up) a download whose SHA256 does not match the pin'; Fixture = @{ Bytes = ([Text.Encoding]::ASCII.GetBytes("tampered-content$([Environment]::NewLine)")) }
                Guard = { @{ ExpectedSha256 = 'deadbeef' * 8 } }; Because = 'a SHA256 mismatch must be rejected after retries'; Cleanup = 'the mismatching partial is cleaned up' },
            @{ Name = 'applies signature and SHA256 guards together (both must pass)'; Fixture = @{ SourceName = 'ok.exe'; DestinationName = 'out.exe'; Bytes = @(0x4D, 0x5A, 0x90, 0x00) }
                Guard = { param($file) @{ ExpectSignature = 'MZ'; ExpectedSha256 = (Get-FileHash -Algorithm SHA256 -Path $file.Source).Hash } }; Because = 'MZ signature + matching SHA256 passed together'
                Then = { param($file)
                    $dest2 = Join-Path $file.Root 'out2.exe'
                    Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $dest2 -MaxAttempts 1 -InitialDelaySeconds 0 -ExpectSignature MZ -ExpectedSha256 ('ab' * 32) } 'valid signature must not bypass the hash guard'
                } }
        )) {
        It $downloadCase.Name {
            $case = $downloadCase
            $fixture = $case.Fixture
            Invoke-FileDownloadFixture @fixture -Body { param($file)
                $guard = & $case.Guard $file
                if ($case.Cleanup) {
                    Assert-Throws { Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -MaxAttempts 2 -InitialDelaySeconds 0 @guard } $case.Because
                    Assert-False (Test-Path $file.Destination) $case.Cleanup
                    return
                }
                Invoke-DownloadWithRetry -Url $file.Url -DestinationPath $file.Destination -InitialDelaySeconds 0 @guard
                Assert-True (Test-Path $file.Destination) $case.Because
                if ($case.Then) { & $case.Then $file }
            }
        }
    }
}

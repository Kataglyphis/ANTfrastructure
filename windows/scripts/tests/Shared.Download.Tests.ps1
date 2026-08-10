#requires -Version 7.0
# Tests for Invoke-DownloadWithRetry — the shared retry/backoff download helper. Exercised
# via file:// URLs (System.Net.WebClient supports them), so the retry + non-empty-verify
# logic is covered with no network access. InitialDelaySeconds 0 keeps the tests instant.

Describe 'Invoke-DownloadWithRetry' {

    It 'downloads a URL to the destination (file:// happy path), creating the parent dir' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src.bin'
            Set-Content -LiteralPath $src -Value 'payload-1234' -Encoding ASCII
            $srcUrl = ([Uri]$src).AbsoluteUri
            $dest = Join-Path $dir 'sub\nested\out.bin'   # parent dirs deliberately absent

            Invoke-DownloadWithRetry -Url $srcUrl -DestinationPath $dest -InitialDelaySeconds 0
            Assert-True (Test-Path $dest) 'destination file was created (parent dirs auto-made)'
            Assert-Match 'payload-1234' (Get-Content -LiteralPath $dest -Raw) 'content was downloaded'
        }
    }

    It 'throws after MaxAttempts when the source cannot be fetched, leaving no partial file' {
        Invoke-InTestDir { param($dir)
            $missing = ([Uri](Join-Path $dir 'does-not-exist.bin')).AbsoluteUri
            $dest = Join-Path $dir 'out.bin'
            Assert-Throws { Invoke-DownloadWithRetry -Url $missing -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 } 'an unreachable source must throw after retries'
            Assert-False (Test-Path $dest) 'no partial destination file is left behind'
        }
    }

    It 'rejects a zero-byte download (empty-file guard)' {
        Invoke-InTestDir { param($dir)
            $empty = Join-Path $dir 'empty.bin'
            New-Item -ItemType File -Path $empty -Force | Out-Null   # 0 bytes
            $emptyUrl = ([Uri]$empty).AbsoluteUri
            $dest = Join-Path $dir 'out.bin'
            Assert-Throws { Invoke-DownloadWithRetry -Url $emptyUrl -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 } 'a zero-byte download must be treated as failure'
            Assert-False (Test-Path $dest) 'the empty partial is cleaned up'
        }
    }

    It 'accepts a download whose magic bytes match -ExpectSignature (MZ)' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'ok.exe'
            [System.IO.File]::WriteAllBytes($src, [byte[]]@(0x4D, 0x5A, 0x90, 0x00))   # "MZ" + filler
            $dest = Join-Path $dir 'out.exe'
            Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -InitialDelaySeconds 0 -ExpectSignature MZ
            Assert-True (Test-Path $dest) 'a valid MZ file passed the signature guard'
        }
    }

    It 'rejects (and cleans up) an HTML page served in place of an MZ binary' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'error.html'
            [System.IO.File]::WriteAllBytes($src, [System.Text.Encoding]::ASCII.GetBytes('<!DOCTYPE html>'))
            $dest = Join-Path $dir 'out.exe'
            Assert-Throws { Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 -ExpectSignature MZ } 'an HTML page served as an .exe must be rejected + retried'
            Assert-False (Test-Path $dest) 'the bad-signature partial is cleaned up'
        }
    }

    It 'accepts a ZIP (PK) signature' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'ok.zip'
            [System.IO.File]::WriteAllBytes($src, [byte[]]@(0x50, 0x4B, 0x03, 0x04))
            $dest = Join-Path $dir 'out.zip'
            Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -InitialDelaySeconds 0 -ExpectSignature PK
            Assert-True (Test-Path $dest) 'a valid PK/ZIP file passed the signature guard'
        }
    }

    It 'accepts a download whose SHA256 matches -ExpectedSha256 (case-insensitive)' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src.bin'
            Set-Content -LiteralPath $src -Value 'hash-me' -Encoding ASCII
            $sha = (Get-FileHash -Algorithm SHA256 -Path $src).Hash.ToLowerInvariant()
            $dest = Join-Path $dir 'out.bin'
            Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -InitialDelaySeconds 0 -ExpectedSha256 $sha
            Assert-True (Test-Path $dest) 'a matching SHA256 (lowercase pin) passed the hash guard'
        }
    }

    It 'rejects (and cleans up) a download whose SHA256 does not match the pin' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src.bin'
            Set-Content -LiteralPath $src -Value 'tampered-content' -Encoding ASCII
            $dest = Join-Path $dir 'out.bin'
            $wrong = 'deadbeef' * 8
            Assert-Throws { Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 -ExpectedSha256 $wrong } 'a SHA256 mismatch must be rejected after retries'
            Assert-False (Test-Path $dest) 'the mismatching partial is cleaned up'
        }
    }

    It 'applies signature and SHA256 guards together (both must pass)' {
        Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'ok.exe'
            [System.IO.File]::WriteAllBytes($src, [byte[]]@(0x4D, 0x5A, 0x90, 0x00))
            $sha = (Get-FileHash -Algorithm SHA256 -Path $src).Hash
            $dest = Join-Path $dir 'out.exe'
            Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest -InitialDelaySeconds 0 -ExpectSignature MZ -ExpectedSha256 $sha
            Assert-True (Test-Path $dest) 'MZ signature + matching SHA256 passed together'
            # Right signature, wrong hash: still rejected.
            $dest2 = Join-Path $dir 'out2.exe'
            Assert-Throws { Invoke-DownloadWithRetry -Url ([Uri]$src).AbsoluteUri -DestinationPath $dest2 -MaxAttempts 1 -InitialDelaySeconds 0 -ExpectSignature MZ -ExpectedSha256 ('ab' * 32) } 'valid signature must not bypass the hash guard'
        }
    }
}

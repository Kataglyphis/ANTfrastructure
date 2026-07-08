# Tests for Invoke-DownloadWithRetry — the shared retry/backoff download helper. Exercised
# via file:// URLs (System.Net.WebClient supports them), so the retry + non-empty-verify
# logic is covered with no network access. InitialDelaySeconds 0 keeps the tests instant.

Describe 'Invoke-DownloadWithRetry' {

    It 'downloads a URL to the destination (file:// happy path), creating the parent dir' {
        $dir = New-TestDir
        $src = Join-Path $dir 'src.bin'
        Set-Content -LiteralPath $src -Value 'payload-1234' -Encoding ASCII
        $srcUrl = ([Uri]$src).AbsoluteUri
        $dest = Join-Path $dir 'sub\nested\out.bin'   # parent dirs deliberately absent

        Invoke-DownloadWithRetry -Url $srcUrl -DestinationPath $dest -InitialDelaySeconds 0
        Assert-True (Test-Path $dest) 'destination file was created (parent dirs auto-made)'
        Assert-Match 'payload-1234' (Get-Content -LiteralPath $dest -Raw) 'content was downloaded'
    }

    It 'throws after MaxAttempts when the source cannot be fetched, leaving no partial file' {
        $dir = New-TestDir
        $missing = ([Uri](Join-Path $dir 'does-not-exist.bin')).AbsoluteUri
        $dest = Join-Path $dir 'out.bin'
        Assert-Throws { Invoke-DownloadWithRetry -Url $missing -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 } 'an unreachable source must throw after retries'
        Assert-False (Test-Path $dest) 'no partial destination file is left behind'
    }

    It 'rejects a zero-byte download (empty-file guard)' {
        $dir = New-TestDir
        $empty = Join-Path $dir 'empty.bin'
        New-Item -ItemType File -Path $empty -Force | Out-Null   # 0 bytes
        $emptyUrl = ([Uri]$empty).AbsoluteUri
        $dest = Join-Path $dir 'out.bin'
        Assert-Throws { Invoke-DownloadWithRetry -Url $emptyUrl -DestinationPath $dest -MaxAttempts 2 -InitialDelaySeconds 0 } 'a zero-byte download must be treated as failure'
        Assert-False (Test-Path $dest) 'the empty partial is cleaned up'
    }
}

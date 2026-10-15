#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The two LiteRT bazel builds keep their actions on the host's dufs, which an uncached build re-ran in full for every variant.

# A loopback port nothing listens on once this returns.
$freePort = { $l = Start-LoopbackListener; $p = $l.LocalEndpoint.Port; $l.Stop(); $p }

Describe 'Get-BazelRemoteCacheArg' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsBazel.Common.psm1' -FunctionName 'Get-BazelRemoteCacheArg')

    It 'adds nothing without an endpoint, so a build without a host cache runs as before' {
        Assert-Equal 0 @(Get-BazelRemoteCacheArg -Endpoint '' 6>$null).Count
    }

    It 'adds nothing, with a warning, when the endpoint does not answer' {
        $r = @(Get-BazelRemoteCacheArg -Endpoint "http://127.0.0.1:$(& $freePort)" -TimeoutSec 2 -WarningVariable w -WarningAction SilentlyContinue 6>$null)
        Assert-Equal 0 $r.Count 'no cache option for a dead endpoint'
        Assert-Match 'does not answer' "$($w[0])"
    }

    It 'points bazel at <endpoint>/bazel and downloads every output when the endpoint answers, even with a 404' {
        $port = & $freePort
        $http = [Net.HttpListener]::new()
        $http.Prefixes.Add("http://localhost:$port/")
        $http.Start()
        try {
            $answer = $http.GetContextAsync()
            $job = Start-ThreadJob { param($t) $c = $t.GetAwaiter().GetResult(); $c.Response.StatusCode = 404; $c.Response.Close(); $c.Request.HttpMethod } -ArgumentList $answer
            $r = @(Get-BazelRemoteCacheArg -Endpoint "http://localhost:$port/ " 6>$null)
            Assert-Equal 'HEAD' (Receive-Job $job -Wait -AutoRemoveJob) 'one HEAD request'
            Assert-Equal "--remote_cache=http://localhost:$port/bazel" $r[0] 'trailing slash and space trimmed'
            Assert-Equal '--remote_download_outputs=all' $r[1] 'the install steps read intermediate outputs'
        } finally { $http.Stop(); $http.Close() }
    }
}

Describe 'the LiteRT bazel builds use the cache, and the S3 seed leaves it out' {

    It 'adds it to the one option list the wheel''s analysis, build and aquery share' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LitertWheelBazel.ps1'))
        Assert-Match '(?s)\$opts = @\(Get-LitertWheelBazelArg [^\r\n]+\) \+\s+@\(Get-BazelRemoteCacheArg\)' $text
    }

    It 'adds it to the LiteRT-LM options its build and aquery share' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LitertLmBazel.ps1'))
        Assert-Match '(?s)\$toolchainOpts = @\(\$toolchain\.Flags\)[^\r\n]+\+\s+@\(Get-BazelRemoteCacheArg\)' $text
        Assert-Match '\$aqueryOpts = [^\r\n]+\$toolchainOpts' $text 'aquery reads the same options'
    }

    It 'keeps bazel/ out of the sccache bucket' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\host\Copy-SccacheCacheToS3.ps1'))
        Assert-Match "'--exclude', 'bazel/\*'" $text
    }
}

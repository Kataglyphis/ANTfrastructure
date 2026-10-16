#requires -Version 7.0
# sccache's two levels: the host's WebDAV first, a shared S3 bucket second, its key only ever an env-sourced BuildKit secret.

Describe 'Get-BkSccacheConfig' {

    $script:keyEnv = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'GKEXAMPLE0000'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'not-a-real-secret' }

    It 'passes the WebDAV endpoint alone when no bucket is configured' {
        $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000'
        Assert-Equal 'SCCACHE_WEBDAV_ENDPOINT' (($c.BuildArgs.Keys | Sort-Object) -join ',')
        Assert-Equal 0 @($c.Secrets).Count
        Assert-Equal '' $c.Note
    }

    It 'chains webdav,s3 with the bucket''s settings as build args and the key as two env-sourced secrets' {
        Invoke-WithEnv $script:keyEnv {
            $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000' -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket 'sccache' -S3Region 'garage'
            Assert-Equal 'webdav,s3' $c.BuildArgs['SCCACHE_MULTILEVEL_CHAIN']
            Assert-Equal 'http://10.0.0.26:3900|sccache|garage|false' ("{0}|{1}|{2}|{3}" -f $c.BuildArgs['SCCACHE_ENDPOINT'], $c.BuildArgs['SCCACHE_BUCKET'],
                $c.BuildArgs['SCCACHE_REGION'], $c.BuildArgs['SCCACHE_S3_USE_SSL'])
            Assert-Equal ('--secret|id=sccache_s3_key_id,env=KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID|--secret|' +
                'id=sccache_s3_secret,env=KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY') ($c.Secrets -join '|')
            Assert-False (($c.BuildArgs.Values + $c.Secrets) -join ' ').Contains('not-a-real-secret') 'the key itself is in no argument'
            Assert-Equal 2 @($c.Levels).Count
        }
    }

    It 'asks for TLS on an https endpoint' {
        Invoke-WithEnv $script:keyEnv {
            Assert-Equal 'true' (Get-BkSccacheConfig -WebdavEndpoint 'http://h:5000' -S3Endpoint 'https://s3.example.com' -S3Bucket 'b').BuildArgs['SCCACHE_S3_USE_SSL']
        }
    }

    It 'uses the bucket alone, without a chain, when there is no WebDAV level' {
        Invoke-WithEnv $script:keyEnv {
            $c = Get-BkSccacheConfig -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket 'sccache'
            Assert-False $c.BuildArgs.ContainsKey('SCCACHE_MULTILEVEL_CHAIN')
            Assert-Equal 'sccache' $c.BuildArgs['SCCACHE_BUCKET']
        }
    }

    foreach ($case in @(
            @{ Why = 'the secret half is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'GKEXAMPLE0000'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = $null }; Bucket = 'sccache'; Pattern = 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY' }
            @{ Why = 'the key id is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = $null; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'x' }; Bucket = 'sccache'; Pattern = 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID' }
            @{ Why = 'the bucket is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'k'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'x' }; Bucket = ''; Pattern = 'the bucket' })) {
        It "leaves the S3 level out, and says why, when $($case.Why)" {
            Invoke-WithEnv $case.Env {
                $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000' -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket $case.Bucket
                Assert-Equal 0 @($c.Secrets).Count 'no secrets without the whole key'
                Assert-False $c.BuildArgs.ContainsKey('SCCACHE_BUCKET')
                Assert-False $c.BuildArgs.ContainsKey('SCCACHE_MULTILEVEL_CHAIN') 'a chain naming a missing level would fail the server'
                Assert-Match $case.Pattern $c.Note
            }
        }
    }
}

Describe 'the sccache stages carry the S3 level' {

    $script:dockerfiles = foreach ($name in 'media-builder', 'media-merge-builder', 'toolchain-builder', 'torch', 'rocm-migraphx', 'rocm-llama') {
        $path = Join-Path (Get-RepoRoot) "windows\Dockerfile.$name"
        @{ Name = $name; Text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n" }
    }

    It 'gives every RUN that mounts the sccache cache both key secrets, as environment variables' {
        $runs = 0
        foreach ($df in $script:dockerfiles) {
            foreach ($m in [regex]::Matches($df.Text, '(?m)^RUN --mount=type=cache,target=C:\\sccache,id=sccache-winamd64-2,sharing=shared `\n(.*)$')) {
                $runs++
                Assert-Match ([regex]::Escape('--mount=type=secret,id=sccache_s3_key_id,env=AWS_ACCESS_KEY_ID')) $m.Groups[1].Value "a RUN in Dockerfile.$($df.Name)"
                Assert-Match ([regex]::Escape('--mount=type=secret,id=sccache_s3_secret,env=AWS_SECRET_ACCESS_KEY')) $m.Groups[1].Value "a RUN in Dockerfile.$($df.Name)"
            }
        }
        Assert-Equal 16 $runs 'every sccache RUN of the chain'
    }

    It 'declares the bucket''s settings as ARGs, never as ENV, wherever the chain is declared' {
        foreach ($df in $script:dockerfiles) {
            $chains = [regex]::Matches($df.Text, '(?m)^ARG SCCACHE_MULTILEVEL_CHAIN$').Count
            foreach ($name in 'SCCACHE_ENDPOINT', 'SCCACHE_BUCKET', 'SCCACHE_REGION', 'SCCACHE_S3_USE_SSL') {
                Assert-Equal $chains ([regex]::Matches($df.Text, "(?m)^ARG $name$").Count) "Dockerfile.$($df.Name): $name"
                Assert-False ($df.Text -match "(?m)^\s*(ENV\s+)?$name=") "Dockerfile.$($df.Name) sets $name"
            }
        }
    }
}

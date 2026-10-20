#requires -Version 7.0
# sccache's two levels: the host's WebDAV first, a shared S3 bucket second, every setting an env-sourced BuildKit secret.

Describe 'Get-BkSccacheConfig' {

    $script:keyEnv = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'GKEXAMPLE0000'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'not-a-real-secret' }
    # The --secret ids a config passes, in order.
    function Get-SecretId { param($Config) @($Config.Secrets | Where-Object { $_ -like 'id=*' } | ForEach-Object { ($_ -split ',')[0] -replace '^id=' }) }

    It 'passes the WebDAV endpoint alone, as a secret, when no bucket is configured' {
        $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000'
        Assert-Equal 'sccache_webdav_endpoint' ((Get-SecretId $c) -join ',')
        Assert-Equal '--secret|id=sccache_webdav_endpoint,env=KATAGLYPHIS_BK_SCCACHE_WEBDAV_ENDPOINT' ($c.Secrets -join '|')
        Assert-Equal 'http://10.0.0.16:5000' $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_WEBDAV_ENDPOINT']
        Assert-Null $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_BUCKET'] 'an unused setting is cleared, so a stale one from an earlier run in the session goes'
        Assert-Equal 'webdav' ($c.Levels -join ',')
        Assert-Equal '' $c.Note
    }

    It 'chains webdav,s3: every setting and both key halves as env-sourced secrets, no value in any argument' {
        Invoke-WithEnv $script:keyEnv {
            $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000' -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket 'sccache' -S3Region 'garage'
            Assert-Equal ('sccache_webdav_endpoint,sccache_multilevel_chain,sccache_endpoint,sccache_bucket,sccache_region,' +
                'sccache_s3_use_ssl,sccache_s3_key_id,sccache_s3_secret') ((Get-SecretId $c) -join ',')
            Assert-Equal 'webdav,s3' $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_MULTILEVEL_CHAIN']
            Assert-Equal 'http://10.0.0.26:3900|sccache|garage|false' ("{0}|{1}|{2}|{3}" -f $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_ENDPOINT'],
                $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_BUCKET'], $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_REGION'], $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_S3_USE_SSL'])
            Assert-Match ([regex]::Escape('id=sccache_s3_key_id,env=KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID')) ($c.Secrets -join '|')
            $arguments = $c.Secrets -join ' '
            foreach ($value in 'http://10.0.0.16:5000', 'http://10.0.0.26:3900', 'garage', 'not-a-real-secret', 'GKEXAMPLE0000') {
                Assert-False $arguments.Contains($value) "a buildctl argument carries $value"
            }
            Assert-Equal 'webdav,s3' ($c.Levels -join ',') 'the levels line names no endpoint or bucket'
        }
    }

    It 'asks for TLS on an https endpoint' {
        Invoke-WithEnv $script:keyEnv {
            Assert-Equal 'true' (Get-BkSccacheConfig -WebdavEndpoint 'http://h:5000' -S3Endpoint 'https://s3.example.com' -S3Bucket 'b').SecretEnv['KATAGLYPHIS_BK_SCCACHE_S3_USE_SSL']
        }
    }

    It 'uses the bucket alone, without a chain, when there is no WebDAV level' {
        Invoke-WithEnv $script:keyEnv {
            $c = Get-BkSccacheConfig -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket 'sccache'
            Assert-False ((Get-SecretId $c) -contains 'sccache_multilevel_chain')
            Assert-False ((Get-SecretId $c) -contains 'sccache_webdav_endpoint')
            Assert-Equal 'sccache' $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_BUCKET']
        }
    }

    It 'passes no secret at all without a level, so every RUN caches on disk alone' {
        $c = Get-BkSccacheConfig
        Assert-Equal 0 @($c.Secrets).Count
        Assert-Equal 'none' $(if ($c.Levels.Count) { $c.Levels -join ',' } else { 'none' })
    }

    foreach ($case in @(
            @{ Why = 'the secret half is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'GKEXAMPLE0000'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = $null }; Bucket = 'sccache'; Pattern = 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY' }
            @{ Why = 'the key id is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = $null; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'x' }; Bucket = 'sccache'; Pattern = 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID' }
            @{ Why = 'the bucket is missing'; Env = @{ KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'k'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'x' }; Bucket = ''; Pattern = 'the bucket' })) {
        It "leaves the S3 level out, and says why, when $($case.Why)" {
            Invoke-WithEnv $case.Env {
                $c = Get-BkSccacheConfig -WebdavEndpoint 'http://10.0.0.16:5000' -S3Endpoint 'http://10.0.0.26:3900' -S3Bucket $case.Bucket
                Assert-Equal 'sccache_webdav_endpoint' ((Get-SecretId $c) -join ',') 'the WebDAV level alone, no key and no chain'
                Assert-Null $c.SecretEnv['KATAGLYPHIS_BK_SCCACHE_BUCKET']
                Assert-Match $case.Pattern $c.Note
            }
        }
    }
}

Describe 'Get-BkHistoryGateValue' {

    It 'refuses both endpoints'' hosts, the bucket and the region' {
        $g = Get-BkHistoryGateValue -Url 'http://10.0.0.16:5000', 'http://cache.lan:3900' -Bucket 'sccache' -Region 'garage'
        Assert-Equal '10.0.0.16,cache.lan' ($g.EndpointHost -join ',')
        Assert-Equal 'sccache|garage' "$($g.Bucket)|$($g.Region)"
    }

    It 'skips what is unset or not a URL' {
        Assert-Equal 0 @((Get-BkHistoryGateValue -Url '', 'not a url').EndpointHost).Count
    }
}

Describe 'the sccache stages carry the levels as secrets' {

    $script:dockerfiles = foreach ($name in 'media-builder', 'media-merge-builder', 'toolchain-builder', 'torch', 'rocm-migraphx', 'rocm-llama') {
        $path = Join-Path (Get-RepoRoot) "windows\Dockerfile.$name"
        @{ Name = $name; Text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n" }
    }
    # A RUN instruction from its first line through the last backtick-continued one.
    $script:runPattern = '(?m)^RUN --mount=type=cache,target=C:\\sccache,id=sccache-winamd64-2,sharing=shared `\n(?:.*`\n)*.*$'

    It 'mounts every secret the driver can pass on each of the 16 sccache RUNs, each as its RUN-side variable' {
        $runs = 0
        foreach ($df in $script:dockerfiles) {
            foreach ($m in [regex]::Matches($df.Text, $script:runPattern)) {
                $runs++
                foreach ($mount in Get-BkSccacheSecretMount) {
                    Assert-Match ([regex]::Escape($mount) + '(?=\s)') $m.Value "a RUN in Dockerfile.$($df.Name) lacks $mount"
                }
            }
        }
        Assert-Equal 16 $runs 'every sccache RUN of the chain'
    }

    It 'declares no endpoint, bucket, region or chain as an ARG and sets none as ENV' {
        foreach ($df in $script:dockerfiles) {
            foreach ($name in 'SCCACHE_WEBDAV_ENDPOINT', 'SCCACHE_MULTILEVEL_CHAIN', 'SCCACHE_ENDPOINT', 'SCCACHE_BUCKET', 'SCCACHE_REGION', 'SCCACHE_S3_USE_SSL') {
                Assert-False ($df.Text -match "(?m)^ARG $name\b") "Dockerfile.$($df.Name) declares ARG $name, whose value BuildKit writes into the history"
                Assert-False ($df.Text -match "(?m)^\s*(ENV\s+)?$name=") "Dockerfile.$($df.Name) sets $name"
            }
        }
    }

    It 'gives the base''s preseed RUN and the litert wheel''s Bazel cache the WebDAV secret, and the base no ARG for it' {
        $base = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\Dockerfile.base'))
        Assert-Match 'RUN --mount=type=secret,id=sccache_webdav_endpoint,env=VULKAN_PRESEED_ENDPOINT `\r?\n\s+& ''C:\\temp\\scripts\\Install-ScoopTools\.ps1''' $base
        Assert-False ($base -match '(?m)^ARG VULKAN_PRESEED_ENDPOINT') 'the base records the endpoint again'
        $media = ($script:dockerfiles | Where-Object { $_.Name -eq 'media-builder' }).Text
        Assert-Match 'id=bazel-litertlm-winamd64,sharing=locked `\n\s+--mount=type=secret,id=sccache_webdav_endpoint,env=SCCACHE_WEBDAV_ENDPOINT `\n(?:.*`\n)*.*Build-LitertWheelBazel\.ps1' $media
    }
}

#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The app builds in a reused container get the shared S3 level per docker exec, by name, so the key reaches no command line.

$s3Repo = Get-RepoRoot
Import-Module (Join-Path $s3Repo 'windows\scripts\modules\WindowsContainerBuild.Reuse.psm1') -Force -DisableNameChecking
$settingsFor = {
    param([string]$Endpoint, [hashtable]$Override = @{})
    $values = @{
        KATAGLYPHIS_SCCACHE_S3_ENDPOINT = $Endpoint; KATAGLYPHIS_SCCACHE_S3_BUCKET = 'sccache'; KATAGLYPHIS_SCCACHE_S3_REGION = 'garage'
        KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID = 'GKEXAMPLE0000'; KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = 'not-a-real-secret'
    }
    foreach ($k in $Override.Keys) { $values[$k] = $Override[$k] }
    { param($name) $values[$name] }.GetNewClosure()
}

Describe 'Get-HostSccacheS3ExecEnv' {

    It 'returns the S3 settings, the chain behind WebDAV and both key halves when the bucket answers' {
        $listener = Start-LoopbackListener
        try {
            $url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
            $s3Env = Get-HostSccacheS3ExecEnv -WebdavEndpoint 'http://192.0.2.1:5000' -Lookup (& $settingsFor $url) 6>$null
            Assert-Equal $url $s3Env['SCCACHE_ENDPOINT']
            Assert-Equal 'sccache' $s3Env['SCCACHE_BUCKET']
            Assert-Equal 'garage' $s3Env['SCCACHE_REGION']
            Assert-Equal 'false' $s3Env['SCCACHE_S3_USE_SSL']
            Assert-Equal 'webdav,s3' $s3Env['SCCACHE_MULTILEVEL_CHAIN']
            Assert-Equal 'GKEXAMPLE0000' $s3Env['AWS_ACCESS_KEY_ID']
            Assert-Equal 'not-a-real-secret' $s3Env['AWS_SECRET_ACCESS_KEY']
        } finally { $listener.Stop() }
    }

    It 'returns nothing when no S3 level is configured' {
        $none = { param($name) '' }
        Assert-Equal 0 (Get-HostSccacheS3ExecEnv -WebdavEndpoint 'http://192.0.2.1:5000' -Lookup $none 6>$null).Count
    }

    It 'returns nothing, with a warning, when the secret half is missing' {
        $lookup = & $settingsFor 'http://127.0.0.1:1' @{ KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY = '' }
        $s3Env = Get-HostSccacheS3ExecEnv -WebdavEndpoint 'http://192.0.2.1:5000' -Lookup $lookup -WarningVariable w -WarningAction SilentlyContinue 6>$null
        Assert-Equal 0 $s3Env.Count
        Assert-Match 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY' "$($w[0])"
    }

    It 'returns nothing, with a warning, when the bucket does not answer, since a failed S3 check stops the whole server' {
        $listener = Start-LoopbackListener
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $s3Env = Get-HostSccacheS3ExecEnv -WebdavEndpoint '' -Lookup (& $settingsFor "http://127.0.0.1:$port") -WarningVariable w -WarningAction SilentlyContinue 6>$null
        Assert-Equal 0 $s3Env.Count
        Assert-Match 'does not answer' "$($w[0])"
    }
}

Describe 'Invoke-ContainerBuild hands the S3 level to docker exec by name only' {

    It 'passes value-less -e NAME on the build exec, inside the environment block that sets the values' {
        $text = [IO.File]::ReadAllText((Join-Path $s3Repo 'windows\scripts\modules\WindowsContainerBuild.Reuse.psm1'))
        Assert-Match "\`$s3Args = @\(\`$s3Env\.Keys \| ForEach-Object \{ '-e', \`$_ \}\)" $text 'names, never NAME=value'
        Assert-Match '(?s)Invoke-WithProcessEnvironment -Environment \$s3Env -ScriptBlock \{\s+& \$DockerExe exec @s3Args ' $text
        Assert-False ($text -match 'docker run[^\r\n]*s3Args') 'never on the docker run that creates the reused container'
    }
}

Describe 'Invoke-WithProcessEnvironment' {

    It 'sets the variables for the block and its children, then restores what was there and removes what was not' {
        Invoke-WithEnv @{ KG_TEST_KEPT = 'before'; KG_TEST_NEW = $null } {
            $seen = Invoke-WithProcessEnvironment -Environment ([ordered]@{ KG_TEST_KEPT = 'during'; KG_TEST_NEW = 'set' }) -ScriptBlock {
                pwsh -NoProfile -Command '"$env:KG_TEST_KEPT/$env:KG_TEST_NEW"'
            }
            Assert-Equal 'during/set' "$seen" 'a child process sees them'
            Assert-Equal 'before' $env:KG_TEST_KEPT 'restored'
            Assert-True ($null -eq $env:KG_TEST_NEW) 'removed again'
        }
    }
}

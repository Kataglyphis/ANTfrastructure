#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The history gate over synthetic image configs: see docs/windows-build-resources.md#what-the-published-image-carries

$modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
Import-Module (Join-Path $modDir 'WindowsImageEnv.Common.psm1') -Force -DisableNameChecking
$historyMutantSource = @{ Text = [IO.File]::ReadAllText((Join-Path $modDir 'WindowsImageEnv.Common.psm1')) }

# A config in BuildKit's shape: one history entry per created_by, then the config's Env and Labels.
function New-TestImageConfig {
    param([string[]]$CreatedBy = @(), [string[]]$Env = @('PATH=C:\Windows'), [hashtable]$Labels = @{}, [string[]]$Entrypoint = @())
    $config = @{ Env = $Env; Labels = $Labels }
    if ($Entrypoint) { $config['Entrypoint'] = $Entrypoint }
    @{ history = @($CreatedBy | ForEach-Object { @{ created_by = $_ } }); config = $config }
}

# The 2026-10-17 history, its addresses made generic: the preseed ARG in the base, the S3 ARGs in a compiling stage.
$script:leaky = New-TestImageConfig -CreatedBy @(
    'ARG VULKAN_PRESEED_ENDPOINT=http://10.0.0.16:5000',
    'RUN |3 VULKAN_VERSION=1.4.363.0 VULKAN_PRESEED_ENDPOINT=http://10.0.0.16:5000 CMAKE_VERSION=4.4.4 pwsh -Command & C:\temp\scripts\Install-ScoopTools.ps1',
    'ARG SCCACHE_ENDPOINT=http://10.0.0.26:3900',
    'ARG SCCACHE_BUCKET=kata-bucket',
    ('RUN |6 SCCACHE_WEBDAV_ENDPOINT=http://10.0.0.16:5000 SCCACHE_MULTILEVEL_CHAIN=webdav,s3 SCCACHE_ENDPOINT=http://10.0.0.26:3900 ' +
        'SCCACHE_BUCKET=kata-bucket SCCACHE_REGION=kata-region SCCACHE_S3_USE_SSL=false pwsh -Command & C:\bkmnt\Build-LlvmFromSource.ps1'))
$script:gate = @{ EndpointHost = @('10.0.0.16', '10.0.0.26'); Bucket = 'kata-bucket'; Region = 'kata-region' }
$script:values = @('10.0.0.16', '10.0.0.26', 'kata-bucket', 'kata-region')

# What the secret form leaves, plus what only looks like a leak: versions, a version dir, empty switches, the word sccache.
$script:clean = New-TestImageConfig -CreatedBy @(
    'Apply image 10.0.26100.33650',
    'ARG SCCACHE_FORCE_LOCAL',
    'ARG SCCACHE_LOG=warn',
    'RUN |4 CUDA_WINDOWS_ARM64_CURAND_VERSION=10.4.4.72 SCCACHE_FORCE_LOCAL= SCCACHE_LOG=warn SCCACHE_DIR=C:\sccache\v2 pwsh -Command & C:\bkmnt\Build-LlvmFromSource.ps1',
    'ENV PATH=C:\TensorRT-10.13.3.9\lib;C:\Windows',
    'RUN pwsh -Command Get-Command sccache; Write-Host garage') -Env @(
    'PATH=C:\TensorRT-10.13.3.9\lib;C:\Windows', 'SCCACHE_DIR=C:\sccache\v2', 'RUSTC_WRAPPER=sccache', 'SCCACHE_LOG=warn') -Labels @{
    'org.opencontainers.image.source' = 'https://github.com/Kataglyphis/ANTfrastructure' }

function Get-HistoryReason { param($Config, [hashtable]$Gate, [scriptblock]$Find = { param($c, $g) Find-ImageConfigLeak -Config $c @g })
    @(& $Find $Config $Gate | ForEach-Object { "$($_.Entry): $($_.Reason)" })
}

Describe 'WindowsImageEnv.Common: Find-ImageConfigLeak' {

    It 'finds every carrier of the 2026-10-17 history: the setting names, the addresses, both hosts, the bucket and the region' {
        $r = Get-HistoryReason $script:leaky $script:gate
        foreach ($want in 'history[0]: RFC1918/link-local address in VULKAN_PRESEED_ENDPOINT', "history[1]: a cache endpoint's host",
            'history[2]: the build-host setting SCCACHE_ENDPOINT', 'history[3]: the S3 bucket as SCCACHE_BUCKET',
            'history[4]: the build-host setting SCCACHE_WEBDAV_ENDPOINT', 'history[4]: RFC1918/link-local address in SCCACHE_ENDPOINT',
            'history[4]: the S3 region as SCCACHE_REGION') {
            Assert-True ($r -contains $want) "missing '$want' in: $($r -join ' | ')"
        }
    }

    It 'never names the value it found, so a red gate publishes nothing in its log' {
        $text = (Get-HistoryReason $script:leaky $script:gate) -join "`n"
        foreach ($v in $script:values) { Assert-False $text.Contains($v) "a reason carries $v" }
    }

    It 'passes what the secret form leaves, with the real bucket and region, which are common words' {
        Assert-Equal '' ((Get-HistoryReason $script:clean @{ EndpointHost = @('10.0.0.16', '10.0.0.26'); Bucket = 'sccache'; Region = 'garage' }) -join ' | ')
    }

    It 'finds a hostname endpoint in a label and the entrypoint, never inside a longer name' {
        $inLabel = New-TestImageConfig -CreatedBy @('RUN pwsh -Command echo cache.lan.example.com') -Labels @{ mirror = 'http://cache.lan:3900/x' } -Entrypoint @('cmd', '/c', 'echo', 'xcache.lan')
        $inEntrypoint = New-TestImageConfig -CreatedBy @('RUN pwsh -Command echo ok') -Entrypoint @('curl', 'http://cache.lan:3900')
        $byName = @{ EndpointHost = @('cache.lan') }
        Assert-Equal "config.Labels: a cache endpoint's host" ((Get-HistoryReason $inLabel $byName) -join ' | ')
        Assert-Equal "config.Entrypoint: a cache endpoint's host" ((Get-HistoryReason $inEntrypoint $byName) -join ' | ')
    }

    It 'leaves loopback out of scope, as the env gate does' {
        $c = New-TestImageConfig -CreatedBy @('RUN pwsh -Command curl http://127.0.0.1:5000')
        Assert-Equal '' ((Get-HistoryReason $c @{ EndpointHost = @('127.0.0.1', 'localhost') }) -join ' | ')
    }

    It 'finds a key half passed as a build arg, and passes an empty setting (an undeclared ARG records none)' {
        $c = New-TestImageConfig -CreatedBy @('RUN |2 AWS_SECRET_ACCESS_KEY=x SCCACHE_ENDPOINT= pwsh -Command echo')
        Assert-Equal 'history[0]: the build-host setting AWS_SECRET_ACCESS_KEY' ((Get-HistoryReason $c @{}) -join ' | ')
    }

    It 'finds an address in the config Env even without a gate value' {
        $c = New-TestImageConfig -CreatedBy @('RUN pwsh -Command echo') -Env @('PATH=C:\Windows', 'MIRROR=http://192.168.1.9:8080')
        Assert-Equal 'config.Env: RFC1918/link-local address in MIRROR' ((Get-HistoryReason $c @{}) -join ' | ')
    }

    # A mutant without Rule (its Text replaced by StandIn) must lose the Lost finding of the first case.
    $rules = @(
        @{ Rule = 'the setting-name rule'; Lost = 'history[2]: the build-host setting SCCACHE_ENDPOINT'; StandIn = 'if ($false)'
            Text = 'if ($value -and ($name -match $script:BuildHostAddressName -or $name -match $script:CredentialName))' }
        @{ Rule = 'the address rule'; Lost = 'history[0]: RFC1918/link-local address in VULKAN_PRESEED_ENDPOINT'; StandIn = 'foreach ($why in @())'
            Text = 'foreach ($why in @(Get-ImageEnvAddressLeak -Name $name -Value $value))' }
        @{ Rule = 'the host rule'; Lost = "history[1]: a cache endpoint's host"; StandIn = '{ }'; Text = "{ `"a cache endpoint's host`" }" }
        @{ Rule = 'the bucket rule'; Lost = 'history[3]: the S3 bucket as SCCACHE_BUCKET'
            Text = "if (`$Bucket -and `$name -match 'BUCKET'"; StandIn = "if (`$false -and `$name -match 'BUCKET'" }
        @{ Rule = 'the region rule'; Lost = 'history[4]: the S3 region as SCCACHE_REGION'
            Text = "if (`$Region -and `$name -match 'REGION'"; StandIn = "if (`$false -and `$name -match 'REGION'" }
        @{ Rule = 'the history as a source'; Lost = 'history[2]: the build-host setting SCCACHE_ENDPOINT'
            Text = ', @("history[$i]",'; StandIn = '$null = @("history[$i]",' })
    foreach ($rule in $rules) {
        It "without $($rule.Rule) the first case loses '$($rule.Lost)' (mutation)" {
            Invoke-WithFunctionModule @historyMutantSource -Find $rule.Text -Replace $rule.StandIn -Body {
                $left = Get-HistoryReason $script:leaky $script:gate -Find { param($c, $g) Find-MutImageConfigLeak -Config $c @g }
                Assert-False ($left -contains $rule.Lost) "the mutant still reports '$($rule.Lost)'"
            }
        }
    }
}

Describe 'WindowsImageEnv.Common: Assert-ImageConfigPublishable' {

    It 'throws on the 2026-10-17 history, names the entries, and prints no value' {
        $gate = $script:gate
        $lines = @(& { try { Assert-ImageConfigPublishable -Config $script:leaky -Label 'img:final' @gate } catch { "CAUGHT:$($_.Exception.Message)" } } 6>&1 | ForEach-Object { "$_" })
        $msg = (@($lines | Where-Object { $_ -like 'CAUGHT:*' }) -join '')
        Assert-Match 'history gate FAILED: \d+ finding\(s\) in the history and config of img:final' $msg
        Assert-Match 'history\[4\]' $msg
        Assert-True (@($lines | Where-Object { $_ -match '^\s+LEAK history\[\d+\]: ' }).Count -ge 7) 'one LEAK line per finding'
        foreach ($v in $script:values) { Assert-False (($lines + $msg) -join "`n").Contains($v) "the gate printed $v" }
    }

    It 'passes the clean config and says how much it read' {
        $out = @(Assert-ImageConfigPublishable -Config $script:clean -Label 'img:final' -EndpointHost '10.0.0.16' -Bucket 'sccache' -Region 'garage' 6>&1 | ForEach-Object { "$_" })
        Assert-Match '6 history entries, no build-host address' ($out -join ' ')
    }

    It 'refuses a config with no history, which it never read' {
        Assert-Throws { Assert-ImageConfigPublishable -Config @{ config = @{ Env = @('A=1') } } -Label 'img:x' 6>$null } -MessagePattern 'never read'
    }
}

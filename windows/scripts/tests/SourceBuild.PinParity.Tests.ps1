#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A baked -DefaultValue is what a script builds when its env pin is not forwarded, so each must equal versions.env.

# One scan surface for W1/W1b/W1c; the matchers stay per-Describe because they read different AST shapes.
function Get-PinScanAst {
    $scriptsDir = Split-Path $PSScriptRoot -Parent
    $files = @(Get-ChildItem -Path $scriptsDir -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.FullName -notmatch '[\\/](tests|modules)[\\/]' } | Sort-Object Name)  # #108 grouped layout
    $files += @(Get-ChildItem -Path (Join-Path $scriptsDir 'modules') -Filter '*.psm1' -File | Sort-Object Name)
    foreach ($f in $files) {
        $ast = Get-TestScriptAst -ScriptPath $f.FullName
        [pscustomobject]@{ File = $f; Ast = $ast }
    }
}

# Shared 'DefaultValue' arm: literal-valued when the AST is a string constant.
function Get-AstDefaultValue {
    param($ArgAst)
    if ($ArgAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return @{ Value = $ArgAst.Value; IsLiteral = $true }
    }
    if ($null -ne $ArgAst) { return @{ Value = $ArgAst.Extent.Text; IsLiteral = $false } }
    return @{ Value = $null; IsLiteral = $false }
}

# Both pin APIs require the same command/default discovery, but accept different environment ASTs.
function Get-PinDefaultCall {
    param([Parameter(Mandatory)][string]$CommandName)
    foreach ($entry in @(Get-PinScanAst)) {
        $calls = @(Get-TestAstCommands -Ast $entry.Ast -Name $CommandName)
        foreach ($call in $calls) {
            $parameters = Get-TestCommandArguments -Command $call -AsAst
            $default = Get-AstDefaultValue $parameters['DefaultValue']
            if ($null -eq $default.Value -or ($default.IsLiteral -and $default.Value -eq '')) { continue }
            [pscustomobject]@{
                Script = $entry.File.Name
                Line = $call.Extent.StartLineNumber
                Parameters = $parameters
                Default = $default.Value
                DefaultIsLiteral = $default.IsLiteral
            }
        }
    }
}

function Get-CanonicalPins {
    param([Parameter(Mandatory)][string]$Label)
    $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
    if (-not (Test-Path $envPath)) {
        throw "${Label}: canonical pin file not found at $envPath"
    }
    return (ConvertFrom-VersionsEnv -Path $envPath)
}
function Get-KnownPinSiteMap {
    param([object[]]$Sites, [scriptblock]$ResolveKey)
    $found = @{}
    foreach ($site in $Sites) {
        $key = & $ResolveKey $site
        if ($null -ne $key) { $found["$($site.Script)|$key"] = $true }
    }
    return $found
}

function Assert-KnownPinSitesDiscovered {
    param([object[]]$Sites, [scriptblock]$ResolveKey, [string[]]$Expected, [string]$Scanner)
    $found = Get-KnownPinSiteMap -Sites $Sites -ResolveKey $ResolveKey
    $missing = @($Expected | Where-Object { -not $found.ContainsKey($_) })
    Assert-True ($missing.Count -eq 0) "scanner-rot guard [$Scanner] missed known site(s): $($missing -join ', ')"
}

# Every scanner must reject unmapped sites and stale exceptions through the same checks.
function Assert-PinSiteMapping {
    param([object[]]$Sites, [string[]]$Allow, [scriptblock]$ResolveKey,
        [scriptblock]$SiteId, [scriptblock]$DescribeUnknown, [string]$Label)
    $seenAllow = @{}
    $unknown = @()
    foreach ($site in $Sites) {
        if ($null -ne (& $ResolveKey $site)) { continue }
        $id = & $SiteId $site
        if ($Allow -contains $id) { $seenAllow[$id] = $true; continue }
        $unknown += & $DescribeUnknown $site
    }
    Assert-True ($unknown.Count -eq 0) ("unmapped $Label site(s) - hardcoded values must not bypass the canonical pins:`n  " + ($unknown -join "`n  "))
    foreach ($id in $Allow) {
        Assert-True $seenAllow.ContainsKey($id) "stale allowlist entry [$id]: no such call site exists anymore - remove it"
    }
}

function Get-PinDefaultMismatch {
    param($Site, [string]$Key, [string]$Expected, [string]$Note = '',
        [ValidateSet('None', 'Single', 'All')][string]$TrimMode = 'None', [string]$Hint)
    if (-not $Site.DefaultIsLiteral) {
        return "$($Site.Script):$($Site.Line): -DefaultValue for $Key is not a string literal ($($Site.Default)) - parity cannot be verified statically; use a literal"
    }
    $actual = $Site.Default
    $comparedExpected = $Expected
    switch ($TrimMode) {
        Single {
            $comparedExpected = $comparedExpected -replace '^v', ''
            $actual = $actual -replace '^v', ''
            $Note = " (compared after StripVPrefix: '$actual' vs '$comparedExpected')"
        }
        All {
            $comparedExpected = $comparedExpected.TrimStart('v')
            $actual = $actual.TrimStart('v')
            $Note += " (compared after TrimVPrefix: '$actual' vs '$comparedExpected')"
        }
    }
    if ($actual -cne $comparedExpected) {
        return "$($Site.Script):$($Site.Line): -DefaultValue '$($Site.Default)' != versions.env ${Key}=$Expected$Note - $Hint"
    }
}

function Assert-PinDefaultSites {
    param([object[]]$Sites, [Parameter(Mandatory)][scriptblock]$Compare, [string]$FailureLabel)
    $failures = @()
    foreach ($site in $Sites) {
        $finding = & $Compare $site
        if ($finding) { $failures += $finding }
    }
    Assert-True ($failures.Count -eq 0) ("${FailureLabel}:`n  " + ($failures -join "`n  "))
}

function Get-PinTwinSite {
    param([object[]]$Sites, [string[]]$Scripts, [string]$Key, [string]$KeyProperty)
    foreach ($site in $Sites) {
        if ($Scripts -contains $site.Script -and @($site.$KeyProperty) -contains $Key) { $site }
    }
}

function Assert-PinTwinLiterals {
    param([object[]]$Sites, [string]$CountMessage, [string]$DisplayName, [scriptblock]$Check)
    Assert-Equal 2 $Sites.Count $CountMessage
    foreach ($site in $Sites) {
        Assert-True $site.DefaultIsLiteral "$($site.Script):$($site.Line) $DisplayName default must be a string literal"
        if ($Check) { & $Check $site }
    }
}

Describe 'SourceBuild pin parity (W1): -DefaultValue fallbacks vs versions.env' {

    function Get-PinParityPins { return (Get-CanonicalPins -Label 'PinParity') }

    # Non-version defaults only; '' defaults are pin-free and need no entry.
    function Get-PinParityAllowlist {
        return @(
            'Build-LitertLmFromSource.ps1|VCPKG_ROOT'   # local toolchain root, not a version
        )
    }

    # Literal-'' defaults are dropped: they bake nothing that can drift.
    function Get-PinParitySite {
        foreach ($site in @(Get-PinDefaultCall -CommandName 'Get-SourceBuildVersion')) {
            $envVars = @()
            $argAst = $site.Parameters['EnvironmentVariables']
            if ($null -ne $argAst) {
                $envVars = @($argAst.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                        ForEach-Object { $_.Value })
            }
            [pscustomobject]@{
                Script = $site.Script
                Line = $site.Line
                EnvVars = $envVars
                Default = $site.Default
                DefaultIsLiteral = $site.DefaultIsLiteral
                StripV = $site.Parameters.Contains('StripVPrefix')
            }
        }
    }

    # First -EnvironmentVariables entry in versions.env, matching the helper's first-hit-wins order.
    function Resolve-PinParityKey {
        param($Site, $Pins)
        foreach ($name in @($Site.EnvVars)) {
            if ($Pins.Contains($name)) { return $name }
        }
        return $null
    }

    # A commit override (TVM_COMMIT) wins key resolution, but the default is the tag fallback, so compare against TVM_REF.
    $script:DefaultValueKeyOverride = @{
        'Build-TvmFromSource.ps1|TVM_COMMIT' = 'TVM_REF'
    }
    function Resolve-DefaultValueKey {
        param($Site, $ResolvedKey)
        $id = "$($Site.Script)|$ResolvedKey"
        if ($script:DefaultValueKeyOverride.ContainsKey($id)) { return $script:DefaultValueKeyOverride[$id] }
        return $ResolvedKey
    }

    It 'parses versions.env and discovers a plausible number of pin sites' {
        $pins = Get-PinParityPins
        Assert-True ($pins.Count -gt 0) 'versions.env parsed to a non-empty table'
        $sites = @(Get-PinParitySite)
        # 14 known version-pin sites + the VCPKG_ROOT allowlisted site = 15.
        Assert-True ($sites.Count -ge 15) "expected at least 15 -DefaultValue sites, scanner found $($sites.Count) - scan broke or sites were removed; update this suite deliberately"
    }

    It 'still discovers every known (script, key) pin site - scanner-rot guard' {
        $pins = Get-PinParityPins
        Assert-KnownPinSitesDiscovered -Sites @(Get-PinParitySite) -ResolveKey { param($site)
            $resolved = Resolve-PinParityKey -Site $site -Pins $pins
            if ($null -ne $resolved) { $resolved }
        } -Scanner 'Get-SourceBuildVersion' -Expected @(
                # TVM_COMMIT wins key resolution; the default itself is compared against TVM_REF.
                'Build-TvmFromSource.ps1|TVM_COMMIT',
                'Build-IreeFromSource.ps1|IREE_VERSION',
                'Build-LitertFromSource.ps1|LITERT_VERSION',
                'Export-LitertLmBridge.ps1|LITERT_VERSION',
                'Build-LitertLmFromSource.ps1|LITERT_LM_VERSION',
                'Build-LitertLmBazel.ps1|LITERT_LM_VERSION',
                'Build-LitertLmFromSource.ps1|PROTOC_VERSION',
                'Build-LitertLmFromSource.ps1|JRE_VERSION',
                'Build-OpencvFromSource.ps1|OPENCV_VERSION',
                'Build-FfmpegFromSource.ps1|FFMPEG_VERSION',
                'Build-FfmpegFromSource.ps1|PYAV_VERSION',
                'Build-GstreamerFromSource.ps1|GSTREAMER_VERSION',
                # The .pc writer's ORT pin must stay a W1 site: W1c cannot see a variable-indirected fallback.
                'Build-GstreamerFromSource.ps1|ONNXRUNTIME_VERSION',
                'Build-OnnxFromSource.ps1|ONNXRUNTIME_VERSION',
                'Build-OnnxGenaiFromSource.ps1|ONNXRUNTIME_GENAI_VERSION')
    }

    It 'every literal -DefaultValue equals its canonical versions.env pin' {
        $pins = Get-PinParityPins
        Assert-PinDefaultSites -Sites @(Get-PinParitySite) -FailureLabel 'hardcoded default(s) drifted from versions.env' -Compare { param($s)
            $key = Resolve-PinParityKey -Site $s -Pins $pins
            if ($null -eq $key) { return }
            $defaultKey = Resolve-DefaultValueKey -Site $s -ResolvedKey $key
            $note = if ($defaultKey -ne $key) { " (DefaultValue is the $defaultKey tag fallback, not the $key commit override)" } else { '' }
            Get-PinDefaultMismatch -Site $s -Key $defaultKey -Expected ([string]$pins[$defaultKey]) -Note $note `
                -TrimMode $(if ($s.StripV) { 'Single' } else { 'None' }) `
                -Hint 'update the script default (and any twin site) to the canonical pin'
        }
    }

    It 'unknown-site guard: every site maps to a versions.env key or the explicit non-version allowlist' {
        $pins = Get-PinParityPins
        $allow = @(Get-PinParityAllowlist)
        Assert-PinSiteMapping -Sites @(Get-PinParitySite) -Allow $allow -Label '-DefaultValue' `
            -ResolveKey { param($site) Resolve-PinParityKey -Site $site -Pins $pins } `
            -SiteId { param($site) "$($site.Script)|$(@($site.EnvVars) -join ',')" } `
            -DescribeUnknown { param($site) "$($site.Script):$($site.Line): -DefaultValue '$($site.Default)' resolves via [$(@($site.EnvVars) -join ', ')] and none is a versions.env key - add the pin to versions.env, or (non-version values ONLY) extend Get-PinParityAllowlist in this suite" }
    }

    It 'LITERT_VERSION twin defaults (Build-LitertFromSource.ps1 + Export-LitertLmBridge.ps1) both equal the canonical tag' {
        $pins = Get-PinParityPins
        Assert-True ($pins.Contains('LITERT_VERSION')) 'LITERT_VERSION is pinned in versions.env'
        $canonical = [string]$pins['LITERT_VERSION']
        $twins = @(Get-PinTwinSite -Sites @(Get-PinParitySite) -Scripts 'Build-LitertFromSource.ps1', 'Export-LitertLmBridge.ps1' -Key LITERT_VERSION -KeyProperty EnvVars)
        Assert-PinTwinLiterals -Sites $twins -DisplayName LiteRT -CountMessage 'exactly the two twin LITERT_VERSION default sites exist (build script + export bridge)' -Check { param($s)
            # Neither twin uses -StripVPrefix, so the default must carry the v prefix too.
            Assert-True ($s.Default -ceq $canonical) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env LITERT_VERSION=$canonical - the two LiteRT defaults must be bumped together"
        }
    }

    # This static pin gate cannot prove the build driver forwards the environment variable at runtime.
    It 'LiteRT-LM CMake and Bazel resolve the same environment pin and literal default' {
        $pins = Get-PinParityPins
        $canonical = [string]$pins['LITERT_LM_VERSION']
        $twins = @(Get-PinTwinSite -Sites @(Get-PinParitySite) -Scripts 'Build-LitertLmFromSource.ps1', 'Build-LitertLmBazel.ps1' -Key LITERT_LM_VERSION -KeyProperty EnvVars)
        Assert-PinTwinLiterals -Sites $twins -DisplayName LiteRT-LM -CountMessage 'exactly the two LiteRT-LM default sites exist' -Check { param($s)
            Assert-True ((@($s.EnvVars) -join ',') -ceq 'LITERT_LM_VERSION') "$($s.Script):$($s.Line): unexpected environment pin order"
            Assert-True ($s.Default -ceq $canonical) "$($s.Script):$($s.Line): default differs from versions.env LITERT_LM_VERSION=$canonical"
            Assert-True (-not $s.StripV) "$($s.Script):$($s.Line): unexpected v-prefix stripping"
        }
    }
}

# W1b: the same drift through Resolve-ContainerImageValue, whose -DefaultValue wins whenever the env pin is not forwarded.
Describe 'SourceBuild pin parity (W1b): Resolve-ContainerImageValue -DefaultValue fallbacks vs versions.env' {

    function Get-RcivPins { return (Get-CanonicalPins -Label 'PinParity(W1b)') }

    # Non-version defaults (paths, derived URLs, dynamic pass-throughs); '' defaults need no entry.
    function Get-RcivAllowlist {
        return @(
            'Install-Cuda.ps1|CUDNN_ROOT',               # install root path, default derived from $CudnnVersion - not a version
            'Install-Cuda.ps1|WINDOWS_TARGET_ARCH',      # arch selector, not a version: amd64/arm64 decides the CUDA payload branch (#176)
            'Install-Rocm.ps1|WINDOWS_TARGET_ARCH',      # arch selector, not a version: anything but amd64 is refused (no Windows arm64 ROCm)
            'Install-VulkanLoader.ps1|WINDOWS_TARGET_ARCH', # arch selector, not a version: the pinned zip is x64-only, anything else is refused
            'Install-Tensorrt.ps1|TENSORRT_ROOT',        # install root path literal - not a version
            'Install-ScoopTools.ps1|GIT_INSTALLER_URL', # URL default derived from $gitVer; GIT_VERSION parity is asserted at ITS site
            'Test-Container.ps1|<dynamic>'       # Get-ExpectedVersion wrapper: env name AND default are pass-through variables
        )
    }

    # Drift whose fix waits for a rebuild window reports as pending; delete an entry in the change that fixes its script.
    $script:KnownDriftAwaitingRebuildWindow = @()

    function Get-RcivKnownDriftId {
        return @($script:KnownDriftAwaitingRebuildWindow | ForEach-Object { "$($_.Script)|$($_.EnvVar)" })
    }

    # FindAll recurses into function bodies, so wrapper-internal calls are sites; a fallback definition of the helper is not.
    function Get-RcivSite {
        foreach ($site in @(Get-PinDefaultCall -CommandName 'Resolve-ContainerImageValue')) {
            $envVar = '<none>'
            $argAst = $site.Parameters['EnvironmentVariable']
            # Nested strings can name a property rather than the environment variable.
            if ($argAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $envVar = $argAst.Value
            } elseif ($null -ne $argAst) {
                $envVar = '<dynamic>'
            }
            [pscustomobject]@{
                Script = $site.Script
                Line = $site.Line
                EnvVar = $envVar
                Default = $site.Default
                DefaultIsLiteral = $site.DefaultIsLiteral
                TrimV = $site.Parameters.Contains('TrimVPrefix')
            }
        }
    }

    # A direct versions.env key or a derived pin; $null leaves the site to the unknown-site guard.
    function Resolve-RcivExpected {
        param($Site, $Pins)
        if ($Site.EnvVar -eq '<dynamic>' -or $Site.EnvVar -eq '<none>') { return $null }
        if ($Pins.Contains($Site.EnvVar)) {
            return [pscustomobject]@{ Key = $Site.EnvVar; Expected = [string]$Pins[$Site.EnvVar]; Derivation = '' }
        }
        if ($Site.EnvVar -eq 'CUDA_VERSION_MAJOR_MINOR' -and $Pins.Contains('CUDA_VERSION')) {
            # Mirrors windows/Build-Buildkit.ps1's $cudaMajorMinor: the first two components of CUDA_VERSION.
            $parts = @(([string]$Pins['CUDA_VERSION']) -split '\.')
            $mm = if ($parts.Count -ge 2) { @($parts[0], $parts[1]) -join '.' } else { [string]$Pins['CUDA_VERSION'] }
            return [pscustomobject]@{ Key = 'CUDA_VERSION_MAJOR_MINOR'; Expected = $mm; Derivation = ' (derived: major.minor of CUDA_VERSION)' }
        }
        return $null
    }

    function Assert-RcivKnownDriftEntries {
        param([object[]]$Entry, [object[]]$Sites, $Pins)
        foreach ($record in $Entry) {
            $id = "$($record.Script)|$($record.EnvVar)"
            $hits = @($Sites | Where-Object { $_.Script -eq $record.Script -and $_.EnvVar -eq $record.EnvVar })
            # Guard 1: the site must still exist -- otherwise the entry is stale.
            Assert-True ($hits.Count -ge 1) "stale KnownDrift entry [$id]: call site no longer exists - remove it from `$script:KnownDriftAwaitingRebuildWindow"
            foreach ($s in $hits) {
                Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line): KnownDrift site default must be a string literal, got ($($s.Default))"
                $resolved = Resolve-RcivExpected -Site $s -Pins $Pins
                Assert-NotNull $resolved "KnownDrift entry [$id]: $($record.EnvVar) is no longer a versions.env (or derived) pin - re-pin it or remove the entry"
                $cmpExpected = $resolved.Expected
                $cmpActual = $s.Default
                if ($s.TrimV) {
                    $cmpExpected = $cmpExpected.TrimStart('v')
                    $cmpActual = $cmpActual.TrimStart('v')
                }
                # Guard 2: fixed drift must be delisted, or the entry would mask a future re-drift.
                Assert-True ($cmpActual -cne $cmpExpected) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' now MATCHES versions.env $($resolved.Key)=$($resolved.Expected) - drift is FIXED: remove this entry from `$script:KnownDriftAwaitingRebuildWindow"
                # Guard 3: a third value is new, untracked drift.
                Assert-True ($s.Default -ceq $record.DriftedDefault) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' is neither the pin ($($resolved.Expected)) nor the recorded drifted value '$($record.DriftedDefault)' - NEW drift; fix the script or update the KnownDrift entry deliberately"
                # The harness has no Set-ItResult -Pending; this yellow line is the pending marker.
                Write-Host "  [pend] $($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $($resolved.Key)=$($resolved.Expected) - KNOWN drift awaiting the batched Windows rebuild window (backlog W1b); fix the script default in that window and delete the KnownDrift entry" -ForegroundColor Yellow
            }
        }
    }

    It 'discovers a plausible number of Resolve-ContainerImageValue -DefaultValue sites' {
        $pins = Get-RcivPins
        Assert-True ($pins.Count -gt 0) 'versions.env parsed to a non-empty table'
        $sites = @(Get-RcivSite)
        # 5 version-pin sites + 4 allowlisted non-version sites = 9.
        Assert-True ($sites.Count -ge 9) "expected at least 9 Resolve-ContainerImageValue -DefaultValue sites, scanner found $($sites.Count) - scan broke or sites were removed; update this suite deliberately"
    }

    It 'still discovers every known (script, env var) Resolve-ContainerImageValue pin site - scanner-rot guard' {
        $pins = Get-RcivPins
        Assert-KnownPinSitesDiscovered -Sites @(Get-RcivSite) -ResolveKey { param($site)
            $resolved = Resolve-RcivExpected -Site $site -Pins $pins
            if ($null -ne $resolved) { $resolved.Key }
        } -Scanner 'Resolve-ContainerImageValue' -Expected @(
                'Install-ScoopTools.ps1|GIT_VERSION',
                'Install-ScoopTools.ps1|WIX_VERSION',
                'Install-ScoopTools.ps1|WIX_UI_EXT_VERSION',
                'Test-Toolchain.ps1|WIX_UI_EXT_VERSION',
                'Install-Tensorrt.ps1|CUDA_VERSION_MAJOR_MINOR')
    }

    It 'every literal Resolve-ContainerImageValue -DefaultValue equals its canonical (or derived) pin - excluding tracked known drift' {
        $pins = Get-RcivPins
        $knownIds = @(Get-RcivKnownDriftId)
        Assert-PinDefaultSites -Sites @(Get-RcivSite) -FailureLabel 'hardcoded Resolve-ContainerImageValue default(s) drifted from versions.env' -Compare { param($s)
            $resolved = Resolve-RcivExpected -Site $s -Pins $pins
            if ($null -eq $resolved) { return }
            if ($knownIds -contains "$($s.Script)|$($s.EnvVar)") { return }
            Get-PinDefaultMismatch -Site $s -Key $resolved.Key -Expected $resolved.Expected -Note $resolved.Derivation `
                -TrimMode $(if ($s.TrimV) { 'All' } else { 'None' }) `
                -Hint 'update the script default to the canonical pin (or, ONLY while a rebuild window blocks the fix, add a KnownDriftAwaitingRebuildWindow entry)'
        }
    }

    It 'unknown-site guard: every Resolve-ContainerImageValue site maps to a versions.env pin, a derived pin, or the explicit non-version allowlist' {
        $pins = Get-RcivPins
        $allow = @(Get-RcivAllowlist)
        Assert-PinSiteMapping -Sites @(Get-RcivSite) -Allow $allow -Label 'Resolve-ContainerImageValue -DefaultValue' `
            -ResolveKey { param($site) Resolve-RcivExpected -Site $site -Pins $pins } `
            -SiteId { param($site) "$($site.Script)|$($site.EnvVar)" } `
            -DescribeUnknown { param($site) "$($site.Script):$($site.Line): -DefaultValue '$($site.Default)' resolves via [$($site.EnvVar)] which is no versions.env key - add the pin to versions.env, or (non-version values ONLY) extend Get-RcivAllowlist in this suite" }
    }

    It 'known drifted defaults (backlog W1b) are tracked as PENDING until the rebuild window - and must be delisted the moment they are fixed' {
        $pins = Get-RcivPins
        $sites = @(Get-RcivSite)
        Assert-RcivKnownDriftEntries -Entry $script:KnownDriftAwaitingRebuildWindow -Sites $sites -Pins $pins
    }

    It 'rejects stale, fixed and changed known-drift records instead of silently treating them as pending' {
        $entry = [pscustomobject]@{ Script = 'fixture.ps1'; EnvVar = 'PIN'; DriftedDefault = '0.9' }
        $site = [pscustomobject]@{ Script = 'fixture.ps1'; Line = 1; EnvVar = 'PIN'; Default = '0.9'; DefaultIsLiteral = $true; TrimV = $false }
        $pins = @{ PIN = '1.0' }
        Assert-RcivKnownDriftEntries -Entry @($entry) -Sites @($site) -Pins $pins
        Assert-Throws { Assert-RcivKnownDriftEntries -Entry @($entry) -Sites @() -Pins $pins } -MessagePattern 'stale KnownDrift entry'
        $site.Default = '1.0'
        Assert-Throws { Assert-RcivKnownDriftEntries -Entry @($entry) -Sites @($site) -Pins $pins } -MessagePattern 'now MATCHES versions.env'
        $site.Default = '0.8'
        Assert-Throws { Assert-RcivKnownDriftEntries -Entry @($entry) -Sites @($site) -Pins $pins } -MessagePattern 'neither the pin'
    }

    It 'WIX_UI_EXT_VERSION twin defaults (Install-ScoopTools.ps1 + Test-Toolchain.ps1) carry the SAME literal - install and verify gates must never disagree' {
        # Even when drifted they must agree, or a defaults-only build installs one version and fails its own toolchain gate.
        $twins = @(Get-PinTwinSite -Sites @(Get-RcivSite) -Scripts 'Install-ScoopTools.ps1', 'Test-Toolchain.ps1' -Key WIX_UI_EXT_VERSION -KeyProperty EnvVar)
        Assert-PinTwinLiterals -Sites $twins -DisplayName 'WiX UI extension' -CountMessage 'exactly the two twin WIX_UI_EXT_VERSION default sites exist (install script + verify gate)'
        Assert-True (@($twins)[0].Default -ceq @($twins)[1].Default) "WIX_UI_EXT_VERSION twin defaults disagree: $(@($twins)[0].Script):$(@($twins)[0].Line)='$(@($twins)[0].Default)' vs $(@($twins)[1].Script):$(@($twins)[1].Line)='$(@($twins)[1].Default)' - the two must be bumped together"
    }
}

Describe 'SourceBuild pin parity (W1c): if($env:KEY){...}else{<literal>} fallbacks vs versions.env' {
    # The raw idiom the resolver scans miss; an else-literal for a key not in versions.env is a behaviour default, not a pin.

    function Get-IdiomPins { return (Get-CanonicalPins -Label 'PinParity(W1c)') }

    function Get-EnvElseLiteralSite {
        $sites = @()
        foreach ($entry in @(Get-PinScanAst)) {
            $f = $entry.File; $ast = $entry.Ast
            foreach ($ifAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
                if ($null -eq $ifAst.ElseClause) { continue }
                # Env vars the condition references, however it tests them.
                $envNames = @($ifAst.Clauses[0].Item1.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $n.VariablePath.UserPath -like 'env:*' }, $true) |
                        ForEach-Object { $_.VariablePath.UserPath.Substring(4) } | Sort-Object -Unique)
                if ($envNames.Count -eq 0) { continue }
                # Only a single bare string literal in the else branch is the pin idiom.
                $elseStrings = @($ifAst.ElseClause.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
                if ($elseStrings.Count -ne 1) { continue }
                if ($ifAst.ElseClause.Statements.Count -ne 1) { continue }
                $literal = $elseStrings[0].Value
                if ([string]::IsNullOrEmpty($literal)) { continue }
                foreach ($name in $envNames) {
                    $sites += [pscustomobject]@{
                        Script  = $f.Name
                        Line    = $ifAst.Extent.StartLineNumber
                        Key     = $name
                        Literal = $literal
                    }
                }
            }
        }
        return $sites
    }

    It 'every env-else-literal fallback for a versions.env key equals the canonical pin' {
        $pins = Get-IdiomPins
        $bad = @()
        foreach ($s in @(Get-EnvElseLiteralSite)) {
            if (-not $pins.Contains($s.Key)) { continue }
            if ($s.Literal -ne $pins[$s.Key]) {
                $bad += "$($s.Script):$($s.Line): else-literal '$($s.Literal)' != versions.env $($s.Key)=$($pins[$s.Key]) - update the literal (and any twin site) to the canonical pin"
            }
        }
        Assert-True ($bad.Count -eq 0) ("env-else-literal default(s) drifted from versions.env:`n  " + ($bad -join "`n  "))
    }

    It 'scanner-rot guard: still discovers the known idiom sites' {
        $pins = Get-IdiomPins
        Assert-KnownPinSitesDiscovered -Sites @(Get-EnvElseLiteralSite) -ResolveKey { param($site)
            if ($pins.Contains($site.Key)) { $site.Key }
        } -Scanner 'env-else-literal' -Expected @(
                'Build-FfmpegFromSource.ps1|NV_CODEC_HEADERS_REF',
                'Build-TorchApp.ps1|APP_REF',
                'Build-GstreamerFromSource.ps1|LIBFFI_MESON_VERSION',
                'Build-ToolchainAll.ps1|NUGET_VERSION',
                'Install-Vcpkg.ps1|VCPKG_REF',
                'Install-Vs.ps1|VISUAL_STUDIO_VERSION',
                'Install-Vs.ps1|WINDOWS_SDK_BUILD')
    }
}

Describe 'Pin parity shared validation contracts' {
    It 'selects only the requested twin sites and rejects missing or nonliteral defaults' {
        $first = [pscustomobject]@{ Script = 'first.ps1'; Line = 1; EnvVars = @('PIN'); DefaultIsLiteral = $true }
        $second = [pscustomobject]@{ Script = 'second.ps1'; Line = 2; EnvVars = @('PIN'); DefaultIsLiteral = $true }
        $other = [pscustomobject]@{ Script = 'other.ps1'; Line = 3; EnvVars = @('PIN'); DefaultIsLiteral = $true }
        $twins = @(Get-PinTwinSite -Sites @($first, $second, $other) -Scripts 'first.ps1', 'second.ps1' -Key PIN -KeyProperty EnvVars)
        Assert-Equal 'first.ps1,second.ps1' (($twins.Script) -join ',') 'selected sites'
        Assert-Throws { Assert-PinTwinLiterals -Sites @($first) -CountMessage fixture -DisplayName twin } -MessagePattern 'expected \[2\] but got \[1\]'
        $second.DefaultIsLiteral = $false
        Assert-Throws { Assert-PinTwinLiterals -Sites @($first, $second) -CountMessage fixture -DisplayName twin } -MessagePattern 'second.ps1:2 twin default must be a string literal'
    }

    It 'fails closed when a scanner omits a required known site' {
        $site = [pscustomobject]@{ Script = 'fixture.ps1'; Key = 'PIN' }
        Assert-Throws {
            Assert-KnownPinSitesDiscovered -Sites @($site) -ResolveKey { param($entry) $entry.Key } `
                -Expected @('fixture.ps1|PIN', 'missing.ps1|MISSING') -Scanner fixture
        } -MessagePattern 'scanner-rot guard \[fixture\].*missing\.ps1\|MISSING'
    }

    It 'aggregates every comparison failure while retaining empty verdicts as matches' {
        Assert-PinDefaultSites -Sites @('matching') -Compare { $null } -FailureLabel fixture
        Assert-Throws {
            Assert-PinDefaultSites -Sites @('first', 'matching', 'second') -Compare { param($site)
                if ($site -ne 'matching') { "$site mismatch" }
            } -FailureLabel fixture
        } -MessagePattern '(?s)fixture:.*first mismatch.*second mismatch'
    }

    It 'detects a shared verdict collector that loses mismatch findings' {
        Invoke-TestFunctionMutations -Find '$failures += $finding' -Replace '$null = $finding' -Expected 'expected an exception but none was thrown' -Body {
                Assert-Throws { Assert-MutPinDefaultSites -Sites wrong -Compare { 'mismatch' } -FailureLabel fixture }
            } -ScriptPath 'windows/scripts/tests/SourceBuild.PinParity.Tests.ps1' -FunctionName @('Assert-PinDefaultSites')
    }

    $site = [pscustomobject]@{ Script = 'fixture.ps1'; Line = 1; Key = 'PIN'; Default = 'v1'; DefaultIsLiteral = $true }
    $resolve = { param($entry) if ($entry.Key -eq 'PIN') { $entry.Key } }
    $idOf = { param($entry) "$($entry.Script)|$($entry.Key)" }
    $describe = { param($entry) "unmapped $($entry.Key)" }

    It 'records only resolved known sites' {
        $unknown = [pscustomobject]@{ Script = 'other.ps1'; Key = 'UNKNOWN' }
        $map = Get-KnownPinSiteMap -Sites @($site, $unknown) -ResolveKey $resolve
        Assert-Equal 1 $map.Count
        Assert-True $map.ContainsKey('fixture.ps1|PIN')
    }

    It 'accepts known and explicitly excepted sites' {
        $excepted = [pscustomobject]@{ Script = 'other.ps1'; Key = 'PATH' }
        Assert-PinSiteMapping -Sites @($site, $excepted) -Allow @('other.ps1|PATH') `
            -ResolveKey $resolve -SiteId $idOf -DescribeUnknown $describe -Label fixture
    }

    It 'rejects an unknown site and a stale exception independently' {
        $unknown = [pscustomobject]@{ Script = 'other.ps1'; Key = 'UNKNOWN' }
        Assert-Throws { Assert-PinSiteMapping -Sites @($unknown) -Allow @() `
                -ResolveKey $resolve -SiteId $idOf -DescribeUnknown $describe -Label fixture } -MessagePattern 'unmapped UNKNOWN'
        Assert-Throws { Assert-PinSiteMapping -Sites @($site) -Allow @('absent.ps1|PATH') `
                -ResolveKey $resolve -SiteId $idOf -DescribeUnknown $describe -Label fixture } -MessagePattern 'stale allowlist'
    }

    It 'compares literal defaults case-sensitively and refuses dynamic defaults' {
        Assert-Null (Get-PinDefaultMismatch -Site $site -Key PIN -Expected v1 -Hint fix)
        Assert-Match '!= versions.env PIN=V1' (Get-PinDefaultMismatch -Site $site -Key PIN -Expected V1 -Hint fix)
        $dynamic = [pscustomobject]@{ Script = 'fixture.ps1'; Line = 2; Default = '$computed'; DefaultIsLiteral = $false }
        Assert-Match 'not a string literal' (Get-PinDefaultMismatch -Site $dynamic -Key PIN -Expected v1 -Hint fix)
    }

    It 'keeps single-prefix stripping distinct from TrimStart semantics' {
        $repeated = [pscustomobject]@{ Script = 'fixture.ps1'; Line = 3; Default = 'vv1'; DefaultIsLiteral = $true }
        Assert-NotNull (Get-PinDefaultMismatch -Site $repeated -Key PIN -Expected v1 -TrimMode Single -Hint fix)
        Assert-Null (Get-PinDefaultMismatch -Site $repeated -Key PIN -Expected v1 -TrimMode All -Hint fix)
        Assert-Null (Get-PinDefaultMismatch -Site $site -Key PIN -Expected 1 -TrimMode Single -Hint fix)
    }
}

#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A baked -DefaultValue is what a script builds when its env pin is not forwarded, so each must equal versions.env.

# One scan surface for W1/W1b/W1c; the matchers stay per-Describe because they read different AST shapes.
function Get-PinScanAst {
    param([string]$MustMentionPattern = '')
    $scriptsDir = Split-Path $PSScriptRoot -Parent
    $files = @(Get-ChildItem -Path $scriptsDir -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.FullName -notmatch '[\\/](tests|modules)[\\/]' } | Sort-Object Name)  # #108 grouped layout
    $files += @(Get-ChildItem -Path (Join-Path $scriptsDir 'modules') -Filter '*.psm1' -File | Sort-Object Name)
    foreach ($f in $files) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) {
            # Fatal only when the file could hold a site the caller would miss; syntax health is another gate's job.
            if ($MustMentionPattern -and ((Get-Content -Path $f.FullName -Raw) -match $MustMentionPattern)) {
                throw ('PinParity: ' + $f.Name + ' has parse errors; cannot scan: ' + @($errors)[0].Message)
            }
            continue
        }
        [pscustomobject]@{ File = $f; Ast = $ast }
    }
}

# A parameter's argument is attached (-Name:value) or the next element.
function Get-CommandParameterArgumentMap {
    param([System.Management.Automation.Language.CommandAst]$Call)
    $map = [ordered]@{}
    $elems = $Call.CommandElements
    for ($i = 0; $i -lt $elems.Count; $i++) {
        $e = $elems[$i]
        if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        # Abbreviated parameter names would surface via the unknown-site guard.
        $argAst = $e.Argument
        if ($null -eq $argAst -and ($i + 1) -lt $elems.Count -and
            $elems[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $argAst = $elems[$i + 1]
        }
        $map[$e.ParameterName] = $argAst
    }
    return $map
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

function Get-CanonicalPins {
    param([Parameter(Mandatory)][string]$Label)
    $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
    if (-not (Test-Path $envPath)) {
        throw "${Label}: canonical pin file not found at $envPath"
    }
    return (ConvertFrom-VersionsEnv -Path $envPath)
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
        $sites = @()
        foreach ($entry in @(Get-PinScanAst -MustMentionPattern 'Get-SourceBuildVersion')) {
            $f = $entry.File; $ast = $entry.Ast

            $calls = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Get-SourceBuildVersion' }, $true))
            foreach ($call in $calls) {
                $default = $null
                $defaultIsLiteral = $false
                $envVars = @()
                $stripV = $false

                foreach ($p in (Get-CommandParameterArgumentMap $call).GetEnumerator()) {
                    $argAst = $p.Value
                    switch ($p.Key) {
                        'DefaultValue' {
                            $d = Get-AstDefaultValue $argAst
                            $default = $d.Value
                            $defaultIsLiteral = $d.IsLiteral
                        }
                        'EnvironmentVariables' {
                            if ($null -ne $argAst) {
                                $envVars = @($argAst.FindAll({ param($n)
                                            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                                        ForEach-Object { $_.Value })
                            }
                        }
                        'StripVPrefix' {
                            $stripV = $true
                        }
                    }
                }

                if ($null -eq $default) { continue }                       # no -DefaultValue at all
                if ($defaultIsLiteral -and $default -eq '') { continue }   # pin-free fallback
                $sites += [pscustomobject]@{
                    Script           = $f.Name
                    Line             = $call.Extent.StartLineNumber
                    EnvVars          = $envVars
                    Default          = $default
                    DefaultIsLiteral = $defaultIsLiteral
                    StripV           = $stripV
                }
            }
        }
        return $sites
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
        # 13 known version-pin sites + the VCPKG_ROOT allowlisted site = 14.
        Assert-True ($sites.Count -ge 14) "expected at least 14 -DefaultValue sites, scanner found $($sites.Count) - scan broke or sites were removed; update this suite deliberately"
    }

    It 'still discovers every known (script, key) pin site - scanner-rot guard' {
        $pins = Get-PinParityPins
        $found = @{}
        foreach ($s in @(Get-PinParitySite)) {
            $key = Resolve-PinParityKey -Site $s -Pins $pins
            if ($null -ne $key) { $found["$($s.Script)|$key"] = $true }
        }
        foreach ($expected in @(
                # TVM_COMMIT wins key resolution; the default itself is compared against TVM_REF.
                'Build-TvmFromSource.ps1|TVM_COMMIT',
                'Build-IreeFromSource.ps1|IREE_VERSION',
                'Build-LitertFromSource.ps1|LITERT_VERSION',
                'Export-LitertLmBridge.ps1|LITERT_VERSION',
                'Build-LitertLmFromSource.ps1|LITERT_LM_VERSION',
                'Build-LitertLmFromSource.ps1|PROTOC_VERSION',
                'Build-LitertLmFromSource.ps1|JRE_VERSION',
                'Build-OpencvFromSource.ps1|OPENCV_VERSION',
                'Build-FfmpegFromSource.ps1|FFMPEG_VERSION',
                'Build-FfmpegFromSource.ps1|PYAV_VERSION',
                'Build-GstreamerFromSource.ps1|GSTREAMER_VERSION',
                # The .pc writer's ORT pin must stay a W1 site: W1c cannot see a variable-indirected fallback.
                'Build-GstreamerFromSource.ps1|ONNXRUNTIME_VERSION',
                'Build-OnnxFromSource.ps1|ONNXRUNTIME_VERSION',
                'Build-OnnxGenaiFromSource.ps1|ONNXRUNTIME_GENAI_VERSION')) {
            Assert-True $found.ContainsKey($expected) "known pin site [$expected] no longer discovered - default removed, key renamed, or scanner broke; update this suite deliberately"
        }
    }

    It 'every literal -DefaultValue equals its canonical versions.env pin' {
        $pins = Get-PinParityPins
        $failures = @()
        foreach ($s in @(Get-PinParitySite)) {
            $key = Resolve-PinParityKey -Site $s -Pins $pins
            if ($null -eq $key) { continue }   # handled by the unknown-site guard below
            if (-not $s.DefaultIsLiteral) {
                $failures += "$($s.Script):$($s.Line): -DefaultValue for $key is not a string literal ($($s.Default)) - parity cannot be verified statically; use a literal"
                continue
            }
            $defaultKey = Resolve-DefaultValueKey -Site $s -ResolvedKey $key
            $expected = [string]$pins[$defaultKey]
            $cmpExpected = $expected
            $cmpActual = $s.Default
            $note = if ($defaultKey -ne $key) { " (DefaultValue is the $defaultKey tag fallback, not the $key commit override)" } else { '' }
            if ($s.StripV) {
                # The script strips the leading v from whichever value wins.
                $cmpExpected = $cmpExpected -replace '^v', ''
                $cmpActual = $cmpActual -replace '^v', ''
                $note = " (compared after StripVPrefix: '$cmpActual' vs '$cmpExpected')"
            }
            if ($cmpActual -cne $cmpExpected) {
                $failures += "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $defaultKey=$expected$note - update the script default (and any twin site) to the canonical pin"
            }
        }
        Assert-True ($failures.Count -eq 0) ("hardcoded default(s) drifted from versions.env:`n  " + ($failures -join "`n  "))
    }

    It 'unknown-site guard: every site maps to a versions.env key or the explicit non-version allowlist' {
        $pins = Get-PinParityPins
        $allow = @(Get-PinParityAllowlist)
        $seenAllow = @{}
        $unknown = @()
        foreach ($s in @(Get-PinParitySite)) {
            $key = Resolve-PinParityKey -Site $s -Pins $pins
            if ($null -ne $key) { continue }
            $id = "$($s.Script)|$(@($s.EnvVars) -join ',')"
            if ($allow -contains $id) { $seenAllow[$id] = $true; continue }
            $unknown += "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' resolves via [$(@($s.EnvVars) -join ', ')] and none is a versions.env key - add the pin to versions.env, or (non-version values ONLY) extend Get-PinParityAllowlist in this suite"
        }
        Assert-True ($unknown.Count -eq 0) ("unmapped -DefaultValue site(s) - hardcoded values must not bypass the canonical pins:`n  " + ($unknown -join "`n  "))
        # Keep the allowlist honest: a vanished site means a stale entry.
        foreach ($id in $allow) {
            Assert-True $seenAllow.ContainsKey($id) "stale allowlist entry [$id]: no such call site exists anymore - remove it"
        }
    }

    It 'LITERT_VERSION twin defaults (Build-LitertFromSource.ps1 + Export-LitertLmBridge.ps1) both equal the canonical tag' {
        $pins = Get-PinParityPins
        Assert-True ($pins.Contains('LITERT_VERSION')) 'LITERT_VERSION is pinned in versions.env'
        $canonical = [string]$pins['LITERT_VERSION']
        $twins = @(Get-PinParitySite | Where-Object {
                ($_.Script -eq 'Build-LitertFromSource.ps1' -or $_.Script -eq 'Export-LitertLmBridge.ps1') -and
                (@($_.EnvVars) -contains 'LITERT_VERSION') })
        Assert-Equal 2 $twins.Count 'exactly the two twin LITERT_VERSION default sites exist (build script + export bridge)'
        foreach ($s in $twins) {
            Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line) LiteRT default must be a string literal"
            # Neither twin uses -StripVPrefix, so the default must carry the v prefix too.
            Assert-True ($s.Default -ceq $canonical) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env LITERT_VERSION=$canonical - the two LiteRT defaults must be bumped together"
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
        $sites = @()
        foreach ($entry in @(Get-PinScanAst -MustMentionPattern 'Resolve-ContainerImageValue')) {
            $f = $entry.File; $ast = $entry.Ast

            $calls = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Resolve-ContainerImageValue' }, $true))
            foreach ($call in $calls) {
                $default = $null
                $defaultIsLiteral = $false
                $envVar = '<none>'
                $trimV = $false

                foreach ($p in (Get-CommandParameterArgumentMap $call).GetEnumerator()) {
                    $argAst = $p.Value
                    switch ($p.Key) {
                        'DefaultValue' {
                            $d = Get-AstDefaultValue $argAst
                            $default = $d.Value
                            $defaultIsLiteral = $d.IsLiteral
                        }
                        'EnvironmentVariable' {
                            # Only a direct literal names the env var; a nested FindAll would pull 'EnvVar' out of $pinned.EnvVar.
                            if ($argAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $envVar = $argAst.Value
                            } elseif ($null -ne $argAst) {
                                $envVar = '<dynamic>'
                            }
                        }
                        'TrimVPrefix' {
                            $trimV = $true
                        }
                    }
                }

                if ($null -eq $default) { continue }                       # no -DefaultValue at all
                if ($defaultIsLiteral -and $default -eq '') { continue }   # pin-free fallback
                $sites += [pscustomobject]@{
                    Script           = $f.Name
                    Line             = $call.Extent.StartLineNumber
                    EnvVar           = $envVar
                    Default          = $default
                    DefaultIsLiteral = $defaultIsLiteral
                    TrimV            = $trimV
                }
            }
        }
        return $sites
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

    It 'discovers a plausible number of Resolve-ContainerImageValue -DefaultValue sites' {
        $pins = Get-RcivPins
        Assert-True ($pins.Count -gt 0) 'versions.env parsed to a non-empty table'
        $sites = @(Get-RcivSite)
        # 5 version-pin sites + 4 allowlisted non-version sites = 9.
        Assert-True ($sites.Count -ge 9) "expected at least 9 Resolve-ContainerImageValue -DefaultValue sites, scanner found $($sites.Count) - scan broke or sites were removed; update this suite deliberately"
    }

    It 'still discovers every known (script, env var) Resolve-ContainerImageValue pin site - scanner-rot guard' {
        $pins = Get-RcivPins
        $found = @{}
        foreach ($s in @(Get-RcivSite)) {
            $resolved = Resolve-RcivExpected -Site $s -Pins $pins
            if ($null -ne $resolved) { $found["$($s.Script)|$($resolved.Key)"] = $true }
        }
        foreach ($expected in @(
                'Install-ScoopTools.ps1|GIT_VERSION',
                'Install-ScoopTools.ps1|WIX_VERSION',
                'Install-ScoopTools.ps1|WIX_UI_EXT_VERSION',
                'Test-Toolchain.ps1|WIX_UI_EXT_VERSION',
                'Install-Tensorrt.ps1|CUDA_VERSION_MAJOR_MINOR')) {
            Assert-True $found.ContainsKey($expected) "known pin site [$expected] no longer discovered - default removed, key renamed, or scanner broke; update this suite (and any KnownDrift entry) deliberately"
        }
    }

    It 'every literal Resolve-ContainerImageValue -DefaultValue equals its canonical (or derived) pin - excluding tracked known drift' {
        $pins = Get-RcivPins
        $knownIds = @(Get-RcivKnownDriftId)
        $failures = @()
        foreach ($s in @(Get-RcivSite)) {
            $resolved = Resolve-RcivExpected -Site $s -Pins $pins
            if ($null -eq $resolved) { continue }   # handled by the unknown-site guard below
            if ($knownIds -contains "$($s.Script)|$($s.EnvVar)") { continue }   # handled by the pending It below
            if (-not $s.DefaultIsLiteral) {
                $failures += "$($s.Script):$($s.Line): -DefaultValue for $($resolved.Key) is not a string literal ($($s.Default)) - parity cannot be verified statically; use a literal"
                continue
            }
            $cmpExpected = $resolved.Expected
            $cmpActual = $s.Default
            $note = $resolved.Derivation
            if ($s.TrimV) {
                # The helper TrimStart('v')s whichever value wins.
                $cmpExpected = $cmpExpected.TrimStart('v')
                $cmpActual = $cmpActual.TrimStart('v')
                $note += " (compared after TrimVPrefix: '$cmpActual' vs '$cmpExpected')"
            }
            if ($cmpActual -cne $cmpExpected) {
                $failures += "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $($resolved.Key)=$($resolved.Expected)$note - update the script default to the canonical pin (or, ONLY while a rebuild window blocks the fix, add a KnownDriftAwaitingRebuildWindow entry)"
            }
        }
        Assert-True ($failures.Count -eq 0) ("hardcoded Resolve-ContainerImageValue default(s) drifted from versions.env:`n  " + ($failures -join "`n  "))
    }

    It 'unknown-site guard: every Resolve-ContainerImageValue site maps to a versions.env pin, a derived pin, or the explicit non-version allowlist' {
        $pins = Get-RcivPins
        $allow = @(Get-RcivAllowlist)
        $seenAllow = @{}
        $unknown = @()
        foreach ($s in @(Get-RcivSite)) {
            $resolved = Resolve-RcivExpected -Site $s -Pins $pins
            if ($null -ne $resolved) { continue }
            $id = "$($s.Script)|$($s.EnvVar)"
            if ($allow -contains $id) { $seenAllow[$id] = $true; continue }
            $unknown += "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' resolves via [$($s.EnvVar)] which is no versions.env key - add the pin to versions.env, or (non-version values ONLY) extend Get-RcivAllowlist in this suite"
        }
        Assert-True ($unknown.Count -eq 0) ("unmapped Resolve-ContainerImageValue -DefaultValue site(s) - hardcoded values must not bypass the canonical pins:`n  " + ($unknown -join "`n  "))
        # Keep the allowlist honest: a vanished site means a stale entry.
        foreach ($id in $allow) {
            Assert-True $seenAllow.ContainsKey($id) "stale allowlist entry [$id]: no such call site exists anymore - remove it"
        }
    }

    It 'known drifted defaults (backlog W1b) are tracked as PENDING until the rebuild window - and must be delisted the moment they are fixed' {
        $pins = Get-RcivPins
        $sites = @(Get-RcivSite)
        foreach ($entry in $script:KnownDriftAwaitingRebuildWindow) {
            $id = "$($entry.Script)|$($entry.EnvVar)"
            $hits = @($sites | Where-Object { $_.Script -eq $entry.Script -and $_.EnvVar -eq $entry.EnvVar })
            # Guard 1: the site must still exist -- otherwise the entry is stale.
            Assert-True ($hits.Count -ge 1) "stale KnownDrift entry [$id]: call site no longer exists - remove it from `$script:KnownDriftAwaitingRebuildWindow"
            foreach ($s in $hits) {
                Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line): KnownDrift site default must be a string literal, got ($($s.Default))"
                $resolved = Resolve-RcivExpected -Site $s -Pins $pins
                Assert-NotNull $resolved "KnownDrift entry [$id]: $($entry.EnvVar) is no longer a versions.env (or derived) pin - re-pin it or remove the entry"
                $cmpExpected = $resolved.Expected
                $cmpActual = $s.Default
                if ($s.TrimV) {
                    $cmpExpected = $cmpExpected.TrimStart('v')
                    $cmpActual = $cmpActual.TrimStart('v')
                }
                # Guard 2: fixed drift must be delisted, or the entry would mask a future re-drift.
                Assert-True ($cmpActual -cne $cmpExpected) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' now MATCHES versions.env $($resolved.Key)=$($resolved.Expected) - drift is FIXED: remove this entry from `$script:KnownDriftAwaitingRebuildWindow"
                # Guard 3: a third value is new, untracked drift.
                Assert-True ($s.Default -ceq $entry.DriftedDefault) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' is neither the pin ($($resolved.Expected)) nor the recorded drifted value '$($entry.DriftedDefault)' - NEW drift; fix the script or update the KnownDrift entry deliberately"
                # The harness has no Set-ItResult -Pending; this yellow line is the pending marker.
                Write-Host "  [pend] $($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $($resolved.Key)=$($resolved.Expected) - KNOWN drift awaiting the batched Windows rebuild window (backlog W1b); fix the script default in that window and delete the KnownDrift entry" -ForegroundColor Yellow
            }
        }
    }

    It 'WIX_UI_EXT_VERSION twin defaults (Install-ScoopTools.ps1 + Test-Toolchain.ps1) carry the SAME literal - install and verify gates must never disagree' {
        # Even when drifted they must agree, or a defaults-only build installs one version and fails its own toolchain gate.
        $twins = @(Get-RcivSite | Where-Object {
                ($_.Script -eq 'Install-ScoopTools.ps1' -or $_.Script -eq 'Test-Toolchain.ps1') -and
                $_.EnvVar -eq 'WIX_UI_EXT_VERSION' })
        Assert-Equal 2 $twins.Count 'exactly the two twin WIX_UI_EXT_VERSION default sites exist (install script + verify gate)'
        foreach ($s in $twins) {
            Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line) WiX UI extension default must be a string literal"
        }
        Assert-True (@($twins)[0].Default -ceq @($twins)[1].Default) "WIX_UI_EXT_VERSION twin defaults disagree: $(@($twins)[0].Script):$(@($twins)[0].Line)='$(@($twins)[0].Default)' vs $(@($twins)[1].Script):$(@($twins)[1].Line)='$(@($twins)[1].Default)' - the two must be bumped together"
    }
}

Describe 'SourceBuild pin parity (W1c): if($env:KEY){...}else{<literal>} fallbacks vs versions.env' {
    # The raw idiom the resolver scans miss; an else-literal for a key not in versions.env is a behaviour default, not a pin.

    function Get-IdiomPins {
        $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
        if (-not (Test-Path $envPath)) { throw "PinParity(W1c): canonical pin file not found at $envPath" }
        return (ConvertFrom-VersionsEnv -Path $envPath)
    }

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
        $found = @{}
        foreach ($s in @(Get-EnvElseLiteralSite)) {
            if ($pins.Contains($s.Key)) { $found["$($s.Script)|$($s.Key)"] = $true }
        }
        foreach ($expected in @(
                'Build-FfmpegFromSource.ps1|NV_CODEC_HEADERS_REF',
                'Build-LitertLmBazel.ps1|LITERT_LM_VERSION',
                'Build-TorchApp.ps1|APP_REF',
                'Build-OpencvFromSource.ps1|PYTHON_VERSION',
                'Build-GstreamerFromSource.ps1|LIBFFI_MESON_VERSION',
                'Build-ToolchainAll.ps1|NUGET_VERSION',
                'Install-Vcpkg.ps1|VCPKG_REF',
                'Install-Vs.ps1|VISUAL_STUDIO_VERSION',
                'Install-Vs.ps1|WINDOWS_SDK_BUILD')) {
            Assert-True ($found.ContainsKey($expected)) "scanner no longer sees the known idiom site $expected - the scan broke or the site changed shape; update this suite deliberately"
        }
    }
}

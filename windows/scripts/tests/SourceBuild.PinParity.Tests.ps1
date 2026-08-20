#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Backlog W1: pin-parity gate for the Windows source-build scripts.
#
# Every `Get-SourceBuildVersion ... -DefaultValue '<literal>'` fallback baked
# into windows\scripts\*.ps1 must equal the canonical pin in
# linux/scripts/01-core/versions.env: the default is what a script builds when
# the corresponding env pin is NOT forwarded (local runs, new lanes, forgotten
# ARG plumbing), so a drifted default silently builds a DIFFERENT version than
# the pinned chain. The classic case is the LITERT_VERSION twin:
# build-litert-from-source.ps1 and litert-lm-export-bridge.ps1 both bake the
# same tag and must be bumped together — this suite pins the pair explicitly.
#
# Discovery is AST-based (CommandAst scan of top-level windows\scripts\*.ps1
# plus modules\*.psm1 — every current and realistically future call site), so
# NEW call sites are found automatically. Unknown-site guard: a discovered site
# whose -EnvironmentVariables name no versions.env key fails the run unless it
# is pin-free (-DefaultValue '') or on the explicit non-version allowlist
# below — new scripts cannot drift silently.
#
# Comparison rule mirrors the helper (WindowsSourceBuild.Common.psm1): with
# -StripVPrefix the leading 'v' is stripped from WHICHEVER value wins (env pin
# or default), so parity for those sites is defined on the stripped forms
# (e.g. default '1.28.0' vs ONNXRUNTIME_VERSION=v1.28.0 is IN sync). All other
# sites compare raw — no over-normalization.
#
# Backlog W1b (second Describe below): the SAME drift class exists via the
# OTHER resolver, Resolve-ContainerImageValue (WindowsContainerImage.Common.psm1)
# -- the setup-*/verify-* container-image scripts bake version literals into its
# -DefaultValue exactly like the source-build scripts do with
# Get-SourceBuildVersion. Covered by a parallel AST scan + parity gate.
#
# Harness-style suite (TestHarness.psm1 Describe/It; PS 5.1 + 7.x, no Pester).
# ConvertFrom-VersionsEnv comes from WindowsScripts.Shared.psm1, imported by
# Invoke-Tests.ps1.

Describe 'SourceBuild pin parity (W1): -DefaultValue fallbacks vs versions.env' {

    function Get-PinParityPins {
        $envPath = Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env'
        if (-not (Test-Path $envPath)) {
            throw "PinParity: canonical pin file not found at $envPath"
        }
        return (ConvertFrom-VersionsEnv -Path $envPath)
    }

    # Non-version -DefaultValue literals (paths/roots, deliberately never pinned
    # in versions.env). Entry format: '<script name>|<EnvironmentVariables joined by ,>'.
    # Empty-string defaults need no entry: they are pin-free (nothing baked in,
    # nothing to drift) and are dropped by the scanner, e.g. build-tvm's VULKAN_SDK.
    function Get-PinParityAllowlist {
        return @(
            'build-litert-lm-from-source.ps1|VCPKG_ROOT'   # local toolchain root, not a version
        )
    }

    # AST-scan for Get-SourceBuildVersion calls carrying a -DefaultValue.
    # Returns one record per call site; literal-'' defaults are dropped (see above).
    function Get-PinParitySite {
        $scriptsDir = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -Path $scriptsDir -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.FullName -notmatch '\\(tests|modules)\\' } | Sort-Object Name)  # #108 grouped layout
        $files += @(Get-ChildItem -Path (Join-Path $scriptsDir 'modules') -Filter '*.psm1' -File | Sort-Object Name)

        $sites = @()
        foreach ($f in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors -and @($errors).Count -gt 0) {
                # Fatal only when the file plausibly contains a site this suite
                # would then miss; general syntax health is another gate's job.
                if ((Get-Content -Path $f.FullName -Raw) -match 'Get-SourceBuildVersion') {
                    throw "PinParity: $($f.Name) has parse errors; cannot scan its Get-SourceBuildVersion sites: $(@($errors)[0].Message)"
                }
                continue
            }

            $calls = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Get-SourceBuildVersion' }, $true))
            foreach ($call in $calls) {
                $default = $null
                $defaultIsLiteral = $false
                $envVars = @()
                $stripV = $false

                $elems = $call.CommandElements
                for ($i = 0; $i -lt $elems.Count; $i++) {
                    $e = $elems[$i]
                    if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    # Argument is either attached (-Name:value) or the next element.
                    # All in-repo sites spell parameter names out in full; an
                    # abbreviated form would surface via the unknown-site guard.
                    $argAst = $e.Argument
                    if ($null -eq $argAst -and ($i + 1) -lt $elems.Count -and
                        $elems[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                        $argAst = $elems[$i + 1]
                    }
                    switch ($e.ParameterName) {
                        'DefaultValue' {
                            if ($argAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $default = $argAst.Value
                                $defaultIsLiteral = $true
                            } elseif ($null -ne $argAst) {
                                $default = $argAst.Extent.Text
                            }
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

    # Canonical versions.env key for a site = the FIRST -EnvironmentVariables
    # entry that exists in versions.env (mirrors the helper's own first-hit-wins
    # resolution when the pins are exported into the environment).
    function Resolve-PinParityKey {
        param($Site, $Pins)
        foreach ($name in @($Site.EnvVars)) {
            if ($Pins.Contains($name)) { return $name }
        }
        return $null
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
                'build-tvm-from-source.ps1|TVM_REF',
                'build-iree-from-source.ps1|IREE_VERSION',
                'build-litert-from-source.ps1|LITERT_VERSION',
                'litert-lm-export-bridge.ps1|LITERT_VERSION',
                'build-litert-lm-from-source.ps1|LITERT_LM_VERSION',
                'build-litert-lm-from-source.ps1|PROTOC_VERSION',
                'build-litert-lm-from-source.ps1|JRE_VERSION',
                'build-opencv-from-source.ps1|OPENCV_VERSION',
                'build-ffmpeg-from-source.ps1|FFMPEG_VERSION',
                'build-ffmpeg-from-source.ps1|PYAV_VERSION',
                'build-gstreamer-from-source.ps1|GSTREAMER_VERSION',
                'build-onnx-from-source.ps1|ONNXRUNTIME_VERSION',
                'build-onnx-genai-from-source.ps1|ONNXRUNTIME_GENAI_VERSION')) {
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
            $expected = [string]$pins[$key]
            $cmpExpected = $expected
            $cmpActual = $s.Default
            $note = ''
            if ($s.StripV) {
                # The script strips the leading v from whichever value wins, so
                # parity for -StripVPrefix sites is defined on the stripped forms.
                $cmpExpected = $cmpExpected -replace '^v', ''
                $cmpActual = $cmpActual -replace '^v', ''
                $note = " (compared after StripVPrefix: '$cmpActual' vs '$cmpExpected')"
            }
            if ($cmpActual -cne $cmpExpected) {
                $failures += "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $key=$expected$note - update the script default (and any twin site) to the canonical pin"
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

    It 'LITERT_VERSION twin defaults (build-litert-from-source.ps1 + litert-lm-export-bridge.ps1) both equal the canonical tag' {
        $pins = Get-PinParityPins
        Assert-True ($pins.Contains('LITERT_VERSION')) 'LITERT_VERSION is pinned in versions.env'
        $canonical = [string]$pins['LITERT_VERSION']
        $twins = @(Get-PinParitySite | Where-Object {
                ($_.Script -eq 'build-litert-from-source.ps1' -or $_.Script -eq 'litert-lm-export-bridge.ps1') -and
                (@($_.EnvVars) -contains 'LITERT_VERSION') })
        Assert-Equal 2 $twins.Count 'exactly the two twin LITERT_VERSION default sites exist (build script + export bridge)'
        foreach ($s in $twins) {
            Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line) LiteRT default must be a string literal"
            # Raw compare: neither site uses -StripVPrefix, so the baked default
            # must carry the exact canonical tag INCLUDING the v prefix.
            Assert-True ($s.Default -ceq $canonical) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env LITERT_VERSION=$canonical - the two LiteRT defaults must be bumped together"
        }
    }
}

# ============================================================================
# Backlog W1b: pin parity for the SECOND shadow-pin mechanism,
# Resolve-ContainerImageValue (WindowsContainerImage.Common.psm1).
#
# Resolution order in the helper is Value > env var > -DefaultValue, so exactly
# as with Get-SourceBuildVersion a drifted -DefaultValue literal silently wins
# whenever the env pin is not forwarded. Parameter shape differs from the W1
# helper and the scanner mirrors it faithfully:
#   * -EnvironmentVariable is a SINGLE string (not an array) -- one env name
#     per site; a non-literal name (e.g. verify-toolchain's $pinned.EnvVar or
#     smoke-test's $Key) is recorded as '<dynamic>'.
#   * -TrimVPrefix TrimStart('v')s the RESOLVED value, so parity for such
#     sites is defined on the TrimStart('v') forms of both values.
#   * literal-'' defaults are pin-free (env absent => empty => site-local
#     "skip/unpinned" semantics) and are dropped, same rule as W1.
#
# Derived pins: CUDA_VERSION_MAJOR_MINOR is deliberately NOT a versions.env
# key -- build.ps1/build-buildkit.ps1 derive it from CUDA_VERSION and bake it
# as an ARG/env. Its baked default must therefore equal the major.minor of the
# canonical CUDA_VERSION pin (a first-two-components rule here, mirroring the
# derivation in windows/build.ps1).
#
# KNOWN DRIFT AWAITING THE REBUILD WINDOW: see
# $script:KnownDriftAwaitingRebuildWindow below. The 3 listed sites ARE
# drifted today, but the script fixes are batched for the next Windows rebuild
# window (editing windows\scripts\*.ps1 invalidates COPY layers), so this
# suite must stay green while DOCUMENTING the drift. TestHarness.psm1 has no
# Pester Set-ItResult -Pending, so pending is emulated: a dedicated It prints
# a yellow [pend] line per tracked site and passes -- and hard guards turn it
# RED the moment a listed default is fixed (entry must then be REMOVED), the
# default drifts to yet another value, or the call site disappears.
# ============================================================================
Describe 'SourceBuild pin parity (W1b): Resolve-ContainerImageValue -DefaultValue fallbacks vs versions.env' {

    function Get-RcivPins {
        $envPath = Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env'
        if (-not (Test-Path $envPath)) {
            throw "PinParity(W1b): canonical pin file not found at $envPath"
        }
        return (ConvertFrom-VersionsEnv -Path $envPath)
    }

    # Non-version Resolve-ContainerImageValue defaults (paths / derived URLs /
    # dynamic pass-throughs -- deliberately never pinned in versions.env).
    # Entry format: '<script name>|<EnvironmentVariable literal, or <dynamic>>'.
    # Empty-string defaults need no entry (dropped by the scanner, e.g. the
    # *_SHA256 pins and verify-toolchain's tool-version gates).
    function Get-RcivAllowlist {
        return @(
            'setup-cuda.ps1|CUDNN_ROOT',               # install root path, default derived from $CudnnVersion - not a version
            'setup-tensorrt.ps1|TENSORRT_ROOT',        # install root path literal - not a version
            'setup-scoop-tools.ps1|GIT_INSTALLER_URL', # URL default derived from $gitVer; GIT_VERSION parity is asserted at ITS site
            'smoke-test-container.ps1|<dynamic>'       # Get-ExpectedVersion wrapper: env name AND default are pass-through variables
        )
    }

    # KNOWN LIVE DRIFT (backlog W1b, verified 2026-08-10): these -DefaultValue
    # literals lag versions.env, but the windows\scripts\*.ps1 fixes are batched
    # for the next Windows rebuild window (COPY-layer invalidation). Until then
    # these exact (script, env var, drifted default) triples are reported as
    # pending, NOT failures. THE MOMENT a listed default is fixed to match the
    # pin, the guard test below FAILS with "remove from KnownDrift list" --
    # delete the entry in the same change that fixes the script.
    #   setup-scoop-tools.ps1:105  GIT_VERSION        '2.54.0' (pin 2.55.0)
    #   setup-scoop-tools.ps1:128  WIX_UI_EXT_VERSION '4.0.4'  (pin 4.0.6)
    #   verify-toolchain.ps1:122   WIX_UI_EXT_VERSION '4.0.4'  (pin 4.0.6)
    $script:KnownDriftAwaitingRebuildWindow = @(
        [pscustomobject]@{ Script = 'setup-scoop-tools.ps1'; EnvVar = 'GIT_VERSION';        DriftedDefault = '2.54.0' },
        [pscustomobject]@{ Script = 'setup-scoop-tools.ps1'; EnvVar = 'WIX_UI_EXT_VERSION'; DriftedDefault = '4.0.4' },
        [pscustomobject]@{ Script = 'verify-toolchain.ps1';  EnvVar = 'WIX_UI_EXT_VERSION'; DriftedDefault = '4.0.4' }
    )

    function Get-RcivKnownDriftId {
        return @($script:KnownDriftAwaitingRebuildWindow | ForEach-Object { "$($_.Script)|$($_.EnvVar)" })
    }

    # AST-scan for Resolve-ContainerImageValue calls carrying a -DefaultValue.
    # Same file set as the W1 scanner (top-level windows\scripts\*.ps1 +
    # modules\*.psm1); FindAll recurses into function bodies, so wrapper-internal
    # sites (smoke-test's Get-ExpectedVersion) are found. smoke-test's local
    # FALLBACK DEFINITION of the helper is a FunctionDefinitionAst, not a
    # CommandAst, so it is correctly not a site. Literal-'' defaults dropped.
    function Get-RcivSite {
        $scriptsDir = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -Path $scriptsDir -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.FullName -notmatch '\\(tests|modules)\\' } | Sort-Object Name)  # #108 grouped layout
        $files += @(Get-ChildItem -Path (Join-Path $scriptsDir 'modules') -Filter '*.psm1' -File | Sort-Object Name)

        $sites = @()
        foreach ($f in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors -and @($errors).Count -gt 0) {
                if ((Get-Content -Path $f.FullName -Raw) -match 'Resolve-ContainerImageValue') {
                    throw "PinParity(W1b): $($f.Name) has parse errors; cannot scan its Resolve-ContainerImageValue sites: $(@($errors)[0].Message)"
                }
                continue
            }

            $calls = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Resolve-ContainerImageValue' }, $true))
            foreach ($call in $calls) {
                $default = $null
                $defaultIsLiteral = $false
                $envVar = '<none>'
                $trimV = $false

                $elems = $call.CommandElements
                for ($i = 0; $i -lt $elems.Count; $i++) {
                    $e = $elems[$i]
                    if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    # Argument is either attached (-Name:value) or the next element.
                    # All in-repo sites spell parameter names out in full; an
                    # abbreviated form would surface via the unknown-site guard.
                    $argAst = $e.Argument
                    if ($null -eq $argAst -and ($i + 1) -lt $elems.Count -and
                        $elems[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                        $argAst = $elems[$i + 1]
                    }
                    switch ($e.ParameterName) {
                        'DefaultValue' {
                            if ($argAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $default = $argAst.Value
                                $defaultIsLiteral = $true
                            } elseif ($null -ne $argAst) {
                                $default = $argAst.Extent.Text
                            }
                        }
                        'EnvironmentVariable' {
                            # SINGLE string parameter: accept ONLY a direct string
                            # literal as the env name. Anything else ($Key,
                            # $pinned.EnvVar, ...) is a dynamic pass-through --
                            # a nested-literal FindAll (as W1 uses for its array
                            # parameter) would mis-extract e.g. the member name
                            # 'EnvVar' from $pinned.EnvVar.
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

    # Expected pin for a site: direct versions.env key, or a derived rule.
    # Returns $null when neither applies (unknown-site guard territory).
    function Resolve-RcivExpected {
        param($Site, $Pins)
        if ($Site.EnvVar -eq '<dynamic>' -or $Site.EnvVar -eq '<none>') { return $null }
        if ($Pins.Contains($Site.EnvVar)) {
            return [pscustomobject]@{ Key = $Site.EnvVar; Expected = [string]$Pins[$Site.EnvVar]; Derivation = '' }
        }
        if ($Site.EnvVar -eq 'CUDA_VERSION_MAJOR_MINOR' -and $Pins.Contains('CUDA_VERSION')) {
            # Mirror windows/build.ps1's $cudaMajorMinor derivation: first two
            # dotted components of the canonical CUDA_VERSION pin.
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
        # 5 version-pin sites (GIT_VERSION, WIX_VERSION, WIX_UI_EXT_VERSION x2,
        # CUDA_VERSION_MAJOR_MINOR) + 4 allowlisted non-version sites = 9.
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
                'setup-scoop-tools.ps1|GIT_VERSION',
                'setup-scoop-tools.ps1|WIX_VERSION',
                'setup-scoop-tools.ps1|WIX_UI_EXT_VERSION',
                'verify-toolchain.ps1|WIX_UI_EXT_VERSION',
                'setup-tensorrt.ps1|CUDA_VERSION_MAJOR_MINOR')) {
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
                # The helper TrimStart('v')s whichever value wins, so parity for
                # -TrimVPrefix sites is defined on the trimmed forms.
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
                # Guard 2: fixed drift MUST be delisted (keeps this list honest,
                # so it can never mask a FUTURE re-drift of the same site).
                Assert-True ($cmpActual -cne $cmpExpected) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' now MATCHES versions.env $($resolved.Key)=$($resolved.Expected) - drift is FIXED: remove this entry from `$script:KnownDriftAwaitingRebuildWindow"
                # Guard 3: the default must be EXACTLY the recorded drifted value;
                # a third value means new, untracked drift -- fail loudly.
                Assert-True ($s.Default -ceq $entry.DriftedDefault) "$($s.Script):$($s.Line): -DefaultValue '$($s.Default)' is neither the pin ($($resolved.Expected)) nor the recorded drifted value '$($entry.DriftedDefault)' - NEW drift; fix the script or update the KnownDrift entry deliberately"
                # Harness has no Set-ItResult -Pending; this yellow line is the
                # documented pending marker (the It itself stays green).
                Write-Host "  [pend] $($s.Script):$($s.Line): -DefaultValue '$($s.Default)' != versions.env $($resolved.Key)=$($resolved.Expected) - KNOWN drift awaiting the batched Windows rebuild window (backlog W1b); fix the script default in that window and delete the KnownDrift entry" -ForegroundColor Yellow
            }
        }
    }

    It 'WIX_UI_EXT_VERSION twin defaults (setup-scoop-tools.ps1 + verify-toolchain.ps1) carry the SAME literal - install and verify gates must never disagree' {
        # Same twin economics as the W1 LITERT pair: setup installs the WiX UI
        # extension the default names, verify-toolchain asserts the extension the
        # default names. Even while both are (known-)drifted from versions.env,
        # they must at least agree with EACH OTHER, or a defaults-only container
        # build installs one version and then fails its own toolchain gate.
        $twins = @(Get-RcivSite | Where-Object {
                ($_.Script -eq 'setup-scoop-tools.ps1' -or $_.Script -eq 'verify-toolchain.ps1') -and
                $_.EnvVar -eq 'WIX_UI_EXT_VERSION' })
        Assert-Equal 2 $twins.Count 'exactly the two twin WIX_UI_EXT_VERSION default sites exist (install script + verify gate)'
        foreach ($s in $twins) {
            Assert-True $s.DefaultIsLiteral "$($s.Script):$($s.Line) WiX UI extension default must be a string literal"
        }
        Assert-True (@($twins)[0].Default -ceq @($twins)[1].Default) "WIX_UI_EXT_VERSION twin defaults disagree: $(@($twins)[0].Script):$(@($twins)[0].Line)='$(@($twins)[0].Default)' vs $(@($twins)[1].Script):$(@($twins)[1].Line)='$(@($twins)[1].Default)' - the two must be bumped together"
    }
}

Describe 'SourceBuild pin parity (W1c): if($env:KEY){...}else{<literal>} fallbacks vs versions.env' {
    # Backlog #69: build-ffmpeg's `else { 'n13.0.19.0' }` drifted against
    # NV_CODEC_HEADERS_REF=n13.1.15.0 - re-planting the exact incident
    # versions.env documents ("a wrong nv-codec-headers ref 404'd and NVENC
    # was silently skipped on both lanes"). W1/W1b scan only the two resolver
    # helpers; this Describe covers the RAW idiom. Membership in versions.env
    # is the version-ness filter: an else-literal for a key NOT in
    # versions.env (FFMPEG_TOOLCHAIN, GPU_TYPE, PKG_CONFIG_PATH) is a
    # behavior default, not a pin, and is ignored.

    function Get-IdiomPins {
        $envPath = Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env'
        if (-not (Test-Path $envPath)) { throw "PinParity(W1c): canonical pin file not found at $envPath" }
        return (ConvertFrom-VersionsEnv -Path $envPath)
    }

    function Get-EnvElseLiteralSite {
        $scriptsDir = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -Path $scriptsDir -Recurse -Filter '*.ps1' -File |
                Where-Object { $_.FullName -notmatch '\\(tests|modules)\\' } | Sort-Object Name)  # #108 grouped layout
        $files += @(Get-ChildItem -Path (Join-Path $scriptsDir 'modules') -Filter '*.psm1' -File | Sort-Object Name)
        $sites = @()
        foreach ($f in $files) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors -and @($errors).Count -gt 0) { continue } # syntax health is another gate's job
            foreach ($ifAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
                if ($null -eq $ifAst.ElseClause) { continue }
                # env vars referenced by the CONDITION (covers bare $env:X,
                # IsNullOrWhiteSpace($env:X), $env:X -match ...).
                $envNames = @($ifAst.Clauses[0].Item1.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $n.VariablePath.UserPath -like 'env:*' }, $true) |
                        ForEach-Object { $_.VariablePath.UserPath.Substring(4) } | Sort-Object -Unique)
                if ($envNames.Count -eq 0) { continue }
                # else branch must be a SINGLE bare string literal - anything
                # richer (string building, cmdlet calls) is not the pin idiom.
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
                'build-ffmpeg-from-source.ps1|NV_CODEC_HEADERS_REF',
                'build-litert-lm-bazel.ps1|LITERT_LM_VERSION',
                'assemble-torch-app.ps1|APP_REF',
                'build-opencv-from-source.ps1|PYTHON_VERSION',
                'build-gstreamer-from-source.ps1|LIBFFI_MESON_VERSION',
                'build-toolchain-all.ps1|NUGET_VERSION',
                'setup-vcpkg.ps1|VCPKG_REF',
                'setup-vs.ps1|VISUAL_STUDIO_VERSION',
                'setup-vs.ps1|WINDOWS_SDK_BUILD')) {
            Assert-True ($found.ContainsKey($expected)) "scanner no longer sees the known idiom site $expected - the scan broke or the site changed shape; update this suite deliberately"
        }
    }
}

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
        $files = @(Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -File | Sort-Object Name)
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

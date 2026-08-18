#requires -Version 7.0
# Backlog #56: the CMake source-patchers rewrite upstream files with bare
# string(REPLACE ...) and then print "Patched ..." UNCONDITIONALLY. If upstream
# reformats the text a pattern targets, the replace silently does nothing, the
# success message still prints, and the defect the patch existed to fix returns
# — after a full media-litert build.
#
# The concrete case: sentencepiece defines a duplicate ABSL_FLAG(minloglevel)
# that collides with abseil's own, aborting litert_lm_main.exe on EVERY run.
# /FORCE:MULTIPLE hides it at link time, so a silently no-op'd regex would ship
# a link-clean, unusable exe while the log claimed "fixes abseil flag ODR abort".
#
# Test-PatchesApplyClean.ps1 globs '*.patch' only, so these .cmake patchers are
# outside the CI patch-drift job entirely. This suite is their gate.


Describe 'CMake source patchers guard against silent no-ops (backlog #56)' {

    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $patchRoot = Join-Path $repoRoot 'windows\scripts\patches'

    # A replace that rewrites upstream source MUST go through the guarded macro.
    # Anything else (e.g. splitting a local "a|b" pair into a list) is exempt via
    # an explicit marker so the exemption is a decision on the record, not a gap.
    $exemptMarker = 'patch-assert-exempt'

    function Get-CmakePatcher {
        if (-not (Test-Path $patchRoot)) { return , @() }
        return , @(Get-ChildItem $patchRoot -Recurse -Filter '*.cmake' -File |
                Where-Object { $_.Name -ne 'patch-assert.cmake' })
    }

    It 'finds .cmake patchers to check (guards against a dead scanner)' {
        $files = Get-CmakePatcher
        Assert-True ($files.Count -ge 5) "expected >=5 .cmake patchers under windows/scripts/patches, got $($files.Count)"
    }

    It 'routes every source-rewriting string(REPLACE) through a guarded macro' {
        $offenders = @()
        foreach ($f in (Get-CmakePatcher)) {
            $lines = Get-Content $f.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '^\s*string\s*\(\s*(REGEX\s+)?REPLACE') { continue }
                # Exemption may sit on the same line or in the 3 lines above it.
                $ctxStart = [Math]::Max(0, $i - 3)
                $context = ($lines[$ctxStart..$i] -join "`n")
                if ($context -match [regex]::Escape($exemptMarker)) { continue }
                $offenders += "$($f.Name):$($i + 1)"
            }
        }
        $detail = ($offenders -join ', ')
        Assert-Equal 0 $offenders.Count ("unguarded string(REPLACE) in a source patcher — use patch_replace_required / patch_regex_replace_required, or mark it '$exemptMarker' with a reason: $detail")
    }

    It 'ships the guard macros next to the patchers that include them' {
        # The macros must live INSIDE patches/litert-lm/ because the Dockerfile
        # COPYs that directory specifically — a helper one level up would not be
        # in the image, and the include() would fail at build time.
        $helper = Join-Path $patchRoot 'litert-lm\patch-assert.cmake'
        Assert-True (Test-Path $helper) 'patches/litert-lm/patch-assert.cmake must exist (it is COPY-reachable; a parent-dir helper would not be)'
        $body = Get-Content $helper -Raw
        foreach ($m in @('patch_replace_required', 'patch_regex_replace_required')) {
            Assert-True ($body -match "macro\s*\(\s*$m") "patch-assert.cmake must define macro $m"
        }
        # Macros, not functions: they assign to the CALLER's variable.
        Assert-True ($body -notmatch 'function\s*\(\s*patch_replace_required') 'patch_replace_required must be a macro (functions cannot assign to the caller variable without PARENT_SCOPE)'
        Assert-True ($body -match 'FATAL_ERROR') 'the guard must FATAL_ERROR on a no-op, not warn'
    }

    It 'has every including patcher pointing at the co-located helper' {
        foreach ($f in (Get-CmakePatcher)) {
            $body = Get-Content $f.FullName -Raw
            if ($body -notmatch 'patch_(regex_)?replace_required') { continue }
            Assert-True ($body -match 'include\s*\(\s*"?\$\{CMAKE_CURRENT_LIST_DIR\}/patch-assert\.cmake') `
                "$($f.Name) uses the guard macros but does not include `${CMAKE_CURRENT_LIST_DIR}/patch-assert.cmake"
        }
    }
}

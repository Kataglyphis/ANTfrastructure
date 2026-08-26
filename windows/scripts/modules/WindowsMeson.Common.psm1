#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Meson plumbing for the GStreamer monorepo build: the build-only-subproject
# interpreter patch, the two failure-triage helpers, and the wrap
# download/extract pair.
#
# WHY THIS IS ITS OWN MODULE — CACHE BOUNDARY, NOT TASTE.
# These five functions lived inside build-gstreamer-from-source.ps1 (backlog
# #128/#133) with a comment explaining that a module was the WRONG home: at the
# time the only module homes available were the six in `buildmods`, which are
# the import closure of WindowsSourceBuild.Common and are mounted into all 11
# media/merge RUNs — so editing any of them re-keyed every media branch on both
# lanes. That reasoning was correct and is now obsolete: #134 gave the merge
# lane its own leaf modules, and this file is mounted by
# Dockerfile.media-merge-builder ONLY. A change here costs the GStreamer layer
# and nothing else.
#
# Keep that property: do NOT add this module to Dockerfile.media-builder's
# `buildmods` stage, and do not move these functions into a module that is.
# The same rule, and the same reason, as WindowsGstPlugins.Common.psm1.
#
# DELIBERATELY DEPENDENCY-FREE: no Import-Module. Three of the five are pure
# string/collection functions with fixture tests; the other two shell out to
# curl.exe and 7z.exe. Nothing here needs Shared, and staying dependency-free is
# what lets the merge Dockerfile mount this file alone.

Set-StrictMode -Version Latest

# meson 1.12.0 (master identical, checked 2026-08-26) mishandles "build-only"
# subprojects -- the copy of a subproject meson configures for the BUILD machine
# when a cross build asks for `native: true`. Nothing in this monorepo asks for
# that explicitly; meson's own gnome module does (`gnome.mkenums_simple` ->
# find_tool -> dependency('glib-2.0', native: true, required: false)), so under
# forcefallback every cross configure runs glib's meson.build a second time for
# the build machine. That copy is never needed (glib-mkenums/genmarshal are
# python scripts resolved through the host glib's override), but three meson
# bugs turn its mere ATTEMPT into missing plugins -- measured arm64 runs 25-27:
#
#  (1) Interpreter.summary is keyed by NAME and shared across interpreters, so
#      the second glib configure throws "Summary section 'Build environment'
#      already have key 'host cpu'" (glib meson.build:2777) and glib(build)
#      fails. Left in place on purpose: a build-machine glib that configures
#      is a build-machine glib that COMPILES (run 26/27: 5772 targets, then
#      'glibconfig.h' file not found), and nothing consumes it.
#  (2) do_subproject's failure paths call disabled_subproject(subp_name,
#      exception=e) WITHOUT for_machine, whose default is HOST -- the failed
#      build-machine holder overwrites the healthy HOST glib holder. That is
#      the poison: libnice's anonymous dependency('', fallback: ['glib',
#      'libglib_dep']) reaches glib by name and gets 'Subproject
#      "subprojects/glib" required but not found' (the gio-2.0 lookup survives
#      because overrides are a different table), webrtc/nice vanish, and every
#      later native:true request re-runs the whole failing configure because
#      the BUILD key never received the disabled entry (30+ times on run 25).
#      PATCHED: pass for_machine at both sites.
#  (3) Targets and include dirs of a build-only subproject live under
#      `build.<subdir>` (build.py: BuildProject.prefix), but configure_file
#      writes to the UNprefixed self.subdir -- the build machine's
#      glibconfig.h/config.h/fficonfig.h land in, and overwrite, the HOST
#      subproject's build dir (run 27: the build compile could not find them
#      where its -I pointed; the host compile silently used x64 configs).
#      PATCHED: configure_file's output path and returned File carry the
#      project prefix, exactly like targets do.
#
# Net effect: glib(build) still dies at (1), is now recorded under BUILD only,
# clobbers nothing, gnome.find_tool falls through to the host override as
# designed, libnice and webrtc configure. Idempotent (one marker per fix);
# throws when either site count is off -- load-bearing on the cross lane, a
# silent miss reappears as the libnice error two hours later. Upstream draft:
# out/upstream-issue-meson-summary-build-subproject.md (all three).
# Fixture test: SourceBuild.MesonBuildSubprojectPatch.Tests.ps1.
function Invoke-MesonBuildSubprojectPatch {
    param(
        [Parameter(Mandatory)]
        [string]$InterpreterPath
    )
    if (-not (Test-Path $InterpreterPath -PathType Leaf)) { throw "Invoke-MesonBuildSubprojectPatch: $InterpreterPath not found" }
    $text = [System.IO.File]::ReadAllText($InterpreterPath)
    $applied = @()

    # (2) failed build-only subprojects must be recorded under THEIR machine.
    $markerKey = '[kataglyphis meson build-subproject machine-key fix]'
    if ($text -notmatch [regex]::Escape($markerKey)) {
        # [ \t] rather than \s in the line anchors: \s matches the newline and a
        # trailing `\s*$` swallows the blank line after a site (measured in the
        # fixture test -- one line fewer after patching).
        $rxKey = '(?m)^([ \t]+return self\.disabled_subproject\(subp_name, exception=e)\)[ \t]*$'
        $hits = [regex]::Matches($text, $rxKey).Count
        if ($hits -ne 2) { throw "Invoke-MesonBuildSubprojectPatch: expected exactly 2 'disabled_subproject(subp_name, exception=e)' sites in $InterpreterPath, found $hits -- meson layout changed; the cross lane would lose webrtc/nice without this fix" }
        $text = [regex]::Replace($text, $rxKey, ('$1, for_machine=for_machine)  # ' + $markerKey))
        $applied += 'machine-key'
    }

    # (3) configure_file outputs of a build-only subproject go to its prefixed dir.
    $markerCf = '[kataglyphis meson build-subproject configure_file fix]'
    if ($text -notmatch [regex]::Escape($markerCf)) {
        $rxCfPath = '(?m)^(        ofile_rpath = os\.path\.join\()self\.subdir(, build_subdir, output\))[ \t]*$'
        $rxCfFile = '(?m)^(        return mesonlib\.File\.from_built_file\()self\.subdir(, output\))[ \t]*$'
        foreach ($rx in @($rxCfPath, $rxCfFile)) {
            $n = [regex]::Matches($text, $rx).Count
            if ($n -ne 1) { throw "Invoke-MesonBuildSubprojectPatch: expected exactly 1 configure_file site for '$rx' in $InterpreterPath, found $n -- meson layout changed" }
        }
        $text = [regex]::Replace($text, $rxCfPath, ('$1self.current_build_project().prefix + self.subdir$2  # ' + $markerCf))
        $text = [regex]::Replace($text, $rxCfFile, ('$1self.current_build_project().prefix + self.subdir$2  # ' + $markerCf))
        $applied += 'configure_file'
    }

    if ($applied.Count -gt 0) {
        [System.IO.File]::WriteAllText($InterpreterPath, $text)
        Write-Host "Patched meson build-subproject fixes ($($applied -join ', ')) ($InterpreterPath)"
    } else {
        Write-Host "meson build-subproject fixes already applied ($InterpreterPath)"
    }
    return $true
}

# meson-log.txt for the monorepo is 400k-800k lines (every subproject's cached
# probe sources are inlined) and streaming all of it through `log` after a failed
# `meson setup` took 30-60 min per attempt on arm64 runs 23-25 -- longer than the
# configure itself, and the diagnosis was always in a handful of lines. Keep
# what carries a diagnosis: every ERROR / Exception / "required but not found" /
# "conflicts with" / "buildable: NO" / "Cannot run cross" line with its 1-based
# line number, the $BlockContext lines after a "Sanity check compile stderr:" or
# "Sanity check compiler command line:" header (the block runs 23 and 24 hid
# in), and the last $TailLines lines. Deliberately NOT `error:`/`WARNING`: every
# feature probe that legitimately fails leaves `error:` lines, and they would
# fill the cap before the real failure. The full file stays at its path inside
# the preserved failed container; the caller's retry classification still scans
# every line. Pure function (fixture test SourceBuild.MesonLogExcerpt.Tests.ps1).
function Select-MesonLogExcerpt {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @(),
        [int]$TailLines = 300,
        [int]$MaxDiagnostics = 400,
        [int]$BlockContext = 12
    )
    $diagPattern  = 'ERROR|Exception|required but not found|conflicts with|is buildable: NO|Cannot run cross'
    $blockPattern = 'Sanity check compile stderr:|Sanity check compiler command line:'
    $picked = New-Object 'System.Collections.Generic.List[string]'
    $total = @($Lines).Count
    $keepUntil = -1
    $diagCount = 0
    # -cmatch on purpose: -match is case-insensitive and `ERROR` would catch every
    # probe's `error:` line (the noise this excerpt exists to drop).
    for ($i = 0; $i -lt $total; $i++) {
        $line = $Lines[$i]
        $isBlock = $line -cmatch $blockPattern
        $isDiag  = $isBlock -or ($line -cmatch $diagPattern)
        if ($isBlock) { $keepUntil = $i + $BlockContext }
        if ($isDiag) { $diagCount++ }
        if (($isDiag -or $i -le $keepUntil) -and $picked.Count -lt $MaxDiagnostics) {
            $picked.Add(('{0,7}: {1}' -f ($i + 1), $line))
        }
    }
    $tailCount = [Math]::Min($TailLines, $total)
    # Explicit empty array: `$x = if (...) { } else { @() }` hands back $null.
    [string[]]$tail = @()
    if ($tailCount -gt 0) { $tail = @($Lines[($total - $tailCount)..($total - 1)]) }
    [pscustomobject]@{
        Total           = $total
        DiagnosticTotal = $diagCount
        Diagnostics     = [string[]]@($picked.ToArray())
        Tail            = $tail
    }
}

# Classifies a failed `meson setup` for the retry decision (the two costumes are
# explained at the call site): HardError = `meson.build:LINE:COL: ERROR/Exception`
# lines anywhere; NetworkError = download/DNS/TLS signatures. The network scan
# covers meson's stdout plus only the LAST $NetworkTail lines of meson-log.txt,
# with word boundaries on the exception names -- meson-log.txt inlines every
# probe's source, and on arm64 run 25 the unbounded case-insensitive `SSLError`
# matched the SDK constant `BINDINFO_OPTIONS_IGNORE_SSLERRORS_ONCE` (urlmon.h)
# inside one of them, turning a deterministic failure into a "transient" retry:
# a full wrap re-download, the identical failure, a second log dump -- an hour
# for nothing. A real download failure is fatal to configure, so its text sits
# at the end of the log. Pure function (SourceBuild.MesonFailureClass.Tests.ps1).
function Get-MesonSetupFailureClass {
    param(
        [AllowEmptyCollection()]
        [string[]]$Output = @(),
        [AllowEmptyCollection()]
        [string[]]$LogLines = @(),
        [int]$NetworkTail = 400
    )
    $all = @($Output) + @($LogLines)
    [string[]]$hard = @($all -match 'meson\.build:\d+:\d+: (ERROR|Exception)')
    $logTotal = @($LogLines).Count
    $tailCount = [Math]::Min($NetworkTail, $logTotal)
    [string[]]$scan = @($Output)
    if ($tailCount -gt 0) { $scan += @($LogLines[($logTotal - $tailCount)..($logTotal - 1)]) }
    [string[]]$network = @($scan -match 'HTTP Error \d+|Failed to download|\bURLError\b|\bSSLError\b|urlopen error|\btimed out\b|connection timeout|actively refused|Temporary failure in name resolution')
    [pscustomobject]@{
        HardError    = $hard
        NetworkError = $network
    }
}

# Downloads one wrap source archive with curl (see the UA note inside) and
# writes it to $DestinationPath. Shared by the wrap pre-extraction loop and the
# libffi force-download, which used to carry two copies of this body.
#
# -Logger is the ONE delta against the stage-script original (#134): the body
# called the script's `log`, a closure over its structured-log context, which
# cannot follow a function into a module. Callers pass their own; without one
# the progress lines go to Write-Host, so the function stays usable standalone
# and in fixtures.
function Invoke-WrapDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$Description = '',
        [scriptblock]$Logger = $null
    )
    # freedesktop/videolan GitLab sit behind the Anubis anti-scraper: browser
    # User-Agents without JS get an HTML challenge page, plain curl UAs pass.
    # The shared Invoke-DownloadWithRetry sends a browser UA (right for the
    # CDNs it serves) - on verify10 it "downloaded" 7 challenge pages and the
    # #88 gate refused them all (correctly, but for the wrong-looking reason:
    # "extraction failed"). Verified 2026-08-17: same URL, browser UA = 7.5 KB
    # HTML, curl UA = 400 KB BZh. So wraps go through curl.exe with its native
    # UA + a magic-byte check.
    $emit = { param($m) if ($Logger) { & $Logger $m } else { Write-Host $m } }
    $label = if ($Description) { $Description } else { $Url }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        # --fail: 4xx/5xx exit non-zero instead of saving the error body.
        $curlOut = & curl.exe --fail --location --silent --show-error --connect-timeout 30 -o $DestinationPath $Url 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -ge 3) {
            $head = [byte[]](Get-Content -Path $DestinationPath -AsByteStream -TotalCount 3)
            $isGzip  = ($head[0] -eq 0x1f -and $head[1] -eq 0x8b)
            $isBzip2 = ($head[0] -eq 0x42 -and $head[1] -eq 0x5a -and $head[2] -eq 0x68)  # 'BZh'
            if ($isGzip -or $isBzip2) { return }
            & $emit "attempt ${attempt}: $label returned non-archive bytes ($($head -join ' ')) - likely an HTML challenge/error page"
        } else {
            & $emit "attempt ${attempt}: curl exit $LASTEXITCODE for $label - $curlOut"
        }
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        if ($attempt -lt 4) { Start-Sleep -Seconds (3 * $attempt) }
    }
    throw "download failed after 4 attempts: $label"
}

# Extracts a downloaded .tar.gz/.tar.bz2 subproject archive into a scratch dir
# beside $Target (7z two-pass: decompress, then untar the LARGEST inner .tar --
# WindowsSourceBuild.Common's Expand-SourceTarball takes the first instead),
# then moves the single top-level source dir onto $Target. Returns $true when a
# directory was moved. Both 7z passes are exit-checked; see the note inside.
# Near-duplicate of Expand-ArchiveSubdirectory/Expand-SourceTarball; merging the
# three is #134's recorded follow-up, deliberately not done in that wave.
function Expand-SubprojectArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Target
    )
    $extractDir = Join-Path (Split-Path -Parent $Target) ('_ext_' + (Split-Path -Leaf $Target))
    New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    # Both passes are exit-checked (2026-08-26 audit): they used to swallow
    # stdout AND stderr with no check, so a truncated or HTML-instead-of-archive
    # download surfaced far downstream as "meson could not find the subproject"
    # instead of naming the extraction failure -- the exact symptom
    # Expand-SourceTarball's comment records having fixed once already.
    cmd.exe /c "7z.exe x ""$Archive"" -o""$extractDir"" -y >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "Expand-SubprojectArchive: 7z failed (exit $LASTEXITCODE) on $Archive -- truncated download or not an archive (size $((Get-Item $Archive -ErrorAction SilentlyContinue).Length) bytes)" }
    $tarFile = @(Get-ChildItem -Path $extractDir -Filter '*.tar' | Sort-Object Length -Descending | Select-Object -First 1)
    if ($tarFile) {
        cmd.exe /c "7z.exe x ""$($tarFile[0].FullName)"" -o""$extractDir"" -y >nul 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "Expand-SubprojectArchive: 7z failed (exit $LASTEXITCODE) on the inner tar of $Archive" }
        Remove-Item $tarFile[0].FullName -Force -ErrorAction SilentlyContinue
    }
    $extracted = @(Get-ChildItem -Path $extractDir -Directory)
    $moved = $false
    if ($extracted.Count -ge 1) {
        Move-Item -Path $extracted[0].FullName -Destination $Target -Force
        $moved = $true
    }
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    return $moved
}

Export-ModuleMember -Function Invoke-MesonBuildSubprojectPatch, Select-MesonLogExcerpt,
    Get-MesonSetupFailureClass, Invoke-WrapDownload, Expand-SubprojectArchive

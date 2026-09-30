#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Dependency-free merge-lane leaf, never in the media-builder buildmods: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

# The site-count throws are load-bearing: see docs/failure-modes.md § meson cross
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
        # [ \t], not \s: a trailing `\s*$` swallows the blank line after a site.
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

# meson-log.txt runs to 800k lines; keep diagnostic lines, sanity-check blocks and the tail, never probe `error:` noise.
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
    # -cmatch: case-insensitive `ERROR` would catch every probe's `error:` line.
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

# Network signatures only in the log's tail, with word boundaries: inlined probe sources mention SSLERRORS too.
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

# -Logger replaces the stage script's `log` closure, which cannot follow a function into a module.
function Invoke-WrapDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$Description = '',
        [scriptblock]$Logger = $null
    )
    # curl's native UA: see docs/windows-build-invariants.md § freedesktop/videolan GitLab downloads must go through Invoke-WrapDownload
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

# Untars the largest inner .tar, unlike Expand-SourceTarball's first; $true when a directory moved onto $Target.
function Expand-SubprojectArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Target
    )
    $extractDir = Join-Path (Split-Path -Parent $Target) ('_ext_' + (Split-Path -Leaf $Target))
    New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    # Exit-checked: a bad archive otherwise surfaces far downstream as a missing meson subproject.
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

# git clone fails in Windows containers, so wrap-gits become tarballs; returns failures for the caller's fail-closed throw.
function Invoke-GstWrapProvisioning {
    param(
        [Parameter(Mandatory)][string]$SubprojectDir,
        [Parameter(Mandatory)][string]$TempDir,
        # Resolved by the caller, where SourceBuild.PinParity's scanner keys on the file name.
        [Parameter(Mandatory)][string]$LibffiVersion,
        [scriptblock]$Logger = { param($m) Write-Host $m }
    )
    # A local list: script scope here is the module's, which the caller's gate never reads.
    $failures = [System.Collections.Generic.List[string]]::new()
    $say = { param($m) & $Logger $m }

    Get-ChildItem -Path $SubprojectDir -Filter '*.wrap' | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $fname = $_.Name
        if ($content -notmatch '^\[wrap-git\]') { return }
        $url = if ($content -match '(?ms)url\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
        $rev = if ($content -match '(?ms)revision\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
        $dir = if ($content -match '(?ms)directory\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
        $target = Join-Path $SubprojectDir $dir
        if (Test-Path $target) { Remove-Item -Path $_.FullName -Force; return }
        # GitLab answers a .git-in-path /-/archive/ URL with HTML, not a tarball.
        $base = $url -replace '\.git$', ''
        $tarballUrl = if ($url -match 'github\.com') { "$base/archive/$rev.tar.gz" }
                      else { "$base/-/archive/$rev/$dir-$rev.tar.bz2" }
        $tmp = Join-Path $TempDir "$dir-$rev.tar"
        $tmpFile = if ($tarballUrl -match '\.bz2$') { "$tmp.bz2" } else { "$tmp.gz" }
        & $say "Pre-extracting $fname..."
        try {
            Invoke-WrapDownload -Url $tarballUrl -DestinationPath $tmpFile -Description "gst wrap $fname ($rev)" -Logger $Logger
            if (Expand-SubprojectArchive -Archive $tmpFile -Target $target) {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                & $say "Pre-extracted $fname to $target"
            } else {
                $failures.Add("$fname (downloaded but extraction into $dir failed)")
            }
        } catch {
            # The real error text: a moved revision and a TLS failure need different fixes.
            $failures.Add("$fname : $($_.Exception.Message)")
            & $say "ERROR: wrap download failed: $fname - $($_.Exception.Message)"
        }
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $libffiTarget = Join-Path $SubprojectDir 'libffi'
    if (-not (Test-Path $libffiTarget)) {
        & $say 'Force-downloading libffi...'
        $libffiUrl = "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson-$LibffiVersion/libffi-meson-$LibffiVersion.tar.bz2"
        $libffiTmp = Join-Path $TempDir 'libffi.tar.bz2'
        try {
            Invoke-WrapDownload -Url $libffiUrl -DestinationPath $libffiTmp -Description "libffi meson port $LibffiVersion" -Logger $Logger
            if (Expand-SubprojectArchive -Archive $libffiTmp -Target $libffiTarget) {
                & $say 'Force-pre-extracted libffi'
            } else {
                $failures.Add('libffi (downloaded but extraction failed)')
            }
        } catch {
            $failures.Add("libffi : $($_.Exception.Message)")
            & $say "ERROR: libffi download failed - $($_.Exception.Message)"
        }
        Remove-Item -Path $libffiTmp -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $SubprojectDir 'libffi.wrap') -Force -ErrorAction SilentlyContinue
    }

    # Not comma-wrapped: the caller @()-wraps, and nesting would make .Count read 1 even when empty.
    return [string[]]$failures.ToArray()
}

Export-ModuleMember -Function Invoke-MesonBuildSubprojectPatch, Select-MesonLogExcerpt,
    Get-MesonSetupFailureClass, Invoke-WrapDownload, Expand-SubprojectArchive,
    Invoke-GstWrapProvisioning

#requires -Version 7.0
# Backlog #55: every file COPY'd into a Windows image has its BYTE CONTENT used
# as the layer-cache key, so a checkout that flips LF<->CRLF invalidates hours
# of cached build layers. `.gitattributes` froze *.ps1/*.psm1/*.env/*.patch for
# exactly that reason — and then .cmake/.cc/.h/.cmd were COPY'd too and left
# unprotected.
#
# That gap was NOT theoretical. On 2026-08-14 windows/scripts/patches/litert-lm/
# held ONE CRLF .cmake next to five LF siblings, with `attr/` unspecified on all
# six and core.autocrlf=true on the host: a fresh clone (this machine, or GitHub
# windows-latest) would have written CRLF for all six, flipping bytes on five of
# them and busting media-litert plus everything downstream.
#
# This test walks the real COPY instructions rather than a hand-kept list, so a
# NEW file type COPY'd into an image fails here instead of silently re-opening
# the hole.


Describe 'COPY-reachable files have a frozen git EOL attribute (backlog #55)' {

    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $windowsDir = Join-Path $repoRoot 'windows'

    # Extensions that carry no line endings at all — a byte-for-byte binary is
    # never touched by autocrlf, so demanding an attribute would be noise.
    $binaryExt = @('.zip', '.exe', '.dll', '.lib', '.png', '.ico', '.pfx', '.cer', '.gz', '.7z', '.msi')

    function Get-CopySourcePath {
        # Every COPY source in every Windows Dockerfile, minus --from=<stage>
        # (those come from another image, not the build context) and minus
        # build-arg-interpolated paths we cannot resolve statically.
        $out = @()
        foreach ($df in (Get-ChildItem $windowsDir -Filter 'Dockerfile*' -File)) {
            $ctxRoot = if ($df.Name -in @('Dockerfile.nvidia')) { $windowsDir } else { $repoRoot }
            # JOIN CONTINUATION LINES FIRST. Windows Dockerfiles use `# escape=\``,
            # and a multi-line COPY's continuation lines do not match ^COPY — so
            # scanning line-by-line dropped them entirely AND mistook the first
            # line's last source for a destination. There are ~10 such COPYs in
            # this tree (2 in base, 6 in media-builder, 2 in media-merge), and the
            # >=10 rot guard was satisfied by the single-line ones alone, which is
            # why the gap was invisible.
            $joined = @()
            $pending = ''
            foreach ($raw in (Get-Content $df.FullName)) {
                $pending = if ($pending) { $pending + ' ' + $raw.Trim() } else { $raw }
                if ($pending -match '`\s*$') { $pending = $pending -replace '`\s*$', ''; continue }
                $joined += $pending
                $pending = ''
            }
            if ($pending) { $joined += $pending }
            foreach ($line in $joined) {
                if ($line -notmatch '^\s*COPY\s') { continue }
                if ($line -match '--from=') { continue }
                $rest = ($line -replace '^\s*COPY\s+', '') -replace '`\s*$', ''
                $tokens = @($rest -split '\s+' | Where-Object { $_ -and $_ -notlike '--*' })
                if ($tokens.Count -lt 2) { continue }
                foreach ($src in $tokens[0..($tokens.Count - 2)]) {
                    if ($src -match '\$\{?\w') { continue }   # ARG-interpolated
                    $out += [pscustomobject]@{
                        Dockerfile = $df.Name
                        Source     = $src
                        FullPath   = Join-Path $ctxRoot ($src -replace '\\', [IO.Path]::DirectorySeparatorChar)
                    }
                }
            }
        }
        return , $out
    }

    It 'finds COPY instructions to check (guards against a dead scanner)' {
        # A scanner that silently matches nothing would make every assertion
        # below vacuously green — the exact "coverage theatre" this suite avoids.
        $copies = Get-CopySourcePath
        Assert-True ($copies.Count -ge 10) "expected >=10 resolvable COPY sources across windows/Dockerfile*, got $($copies.Count)"
    }

    It 'has a git EOL attribute on every COPY-reachable text file' {
        $git = Get-Command git -ErrorAction SilentlyContinue
        # Fail CLOSED, not skipped: without git this test proves nothing, and a
        # silent skip is how a gate rots.
        Assert-True ([bool]$git) 'git is required to read check-attr; refusing to pass vacuously'

        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($c in (Get-CopySourcePath)) {
            if (-not (Test-Path $c.FullPath)) { continue }
            $item = Get-Item $c.FullPath
            if ($item.PSIsContainer) {
                foreach ($f in (Get-ChildItem $c.FullPath -Recurse -File)) { $files.Add($f.FullName) }
            } else {
                $files.Add($item.FullName)
            }
        }

        $unprotected = @()
        foreach ($f in ($files | Sort-Object -Unique)) {
            if ([IO.Path]::GetExtension($f).ToLowerInvariant() -in $binaryExt) { continue }
            $rel = [IO.Path]::GetRelativePath($repoRoot, $f) -replace '\\', '/'
            $attr = (& git -C $repoRoot check-attr text -- $rel) 2>$null
            # "path: text: unspecified" == autocrlf is free to rewrite it.
            if ($attr -match ':\s*text:\s*unspecified\s*$') { $unprotected += $rel }
        }

        $detail = ($unprotected | Select-Object -First 12) -join ', '
        Assert-Equal 0 $unprotected.Count ("COPY-reachable files with NO git EOL attribute (add a rule to .gitattributes): $detail")
    }

    It 'keeps every file in windows/scripts/patches byte-consistent with the index' {
        # The concrete 2026-08-14 defect: worktree CRLF against an LF index. With
        # `-text` in force that is a real byte difference in a COPY'd file, i.e.
        # a layer-cache bust waiting for the next commit.
        $git = Get-Command git -ErrorAction SilentlyContinue
        Assert-True ([bool]$git) 'git is required for this check'
        $eol = & git -C $repoRoot ls-files --eol -- 'windows/scripts/patches' 2>$null
        $mixed = @($eol | Where-Object { $_ -match '^i/(\S+)\s+w/(\S+)' -and $Matches[1] -ne $Matches[2] -and $Matches[1] -ne 'mixed' })
        $detail = ($mixed | Select-Object -First 6) -join ' ; '
        Assert-Equal 0 $mixed.Count "patch files whose worktree EOL differs from the index: $detail"
    }
}

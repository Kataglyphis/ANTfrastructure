#requires -Version 7.0
# COPY'd bytes key the layer cache, so every file type the real COPY lines reach needs a fixed EOL attribute.


Describe 'COPY-reachable files have a frozen git EOL attribute (backlog #55)' {

    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $windowsDir = Join-Path $repoRoot 'windows'

    # Binaries carry no line endings, so autocrlf never touches them.
    $binaryExt = @('.zip', '.exe', '.dll', '.lib', '.png', '.ico', '.pfx', '.cer', '.gz', '.7z', '.msi')

    function Get-CopySourcePath {
        # --from=<stage> sources and build-arg paths are not build-context files.
        $out = @()
        foreach ($df in (Get-ChildItem $windowsDir -Filter 'Dockerfile*' -File)) {
            $ctxRoot = if ($df.Name -in @('Dockerfile.nvidia')) { $windowsDir } else { $repoRoot }
            # Join continuations first, or a multi-line COPY loses its sources and its first line's last source reads as the destination.
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
        # A scanner that matches nothing would make every assertion below vacuously green.
        $copies = Get-CopySourcePath
        Assert-True ($copies.Count -ge 10) "expected >=10 resolvable COPY sources across windows/Dockerfile*, got $($copies.Count)"
    }

    It 'has a git EOL attribute on every COPY-reachable text file' {
        $git = Get-Command git -ErrorAction SilentlyContinue
        # Fail closed: a silent skip is how a gate rots.
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
        # With `-text`, worktree CRLF against an LF index is a real byte difference in a COPY'd file.
        $git = Get-Command git -ErrorAction SilentlyContinue
        Assert-True ([bool]$git) 'git is required for this check'
        $eol = & git -C $repoRoot ls-files --eol -- 'windows/scripts/patches' 2>$null
        $mixed = @($eol | Where-Object { $_ -match '^i/(\S+)\s+w/(\S+)' -and $Matches[1] -ne $Matches[2] -and $Matches[1] -ne 'mixed' })
        $detail = ($mixed | Select-Object -First 6) -join ' ; '
        Assert-Equal 0 $mixed.Count "patch files whose worktree EOL differs from the index: $detail"
    }
}

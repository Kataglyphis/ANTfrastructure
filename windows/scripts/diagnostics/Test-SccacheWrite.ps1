#requires -Version 7.0
<#
.SYNOPSIS
    Diagnoses why sccache L0 (disk) cache writes fail with os error 3, inside the media builder's exact cache mounts.
.DESCRIPTION
    Raw .NET writes separate an unwritable directory (A) from a broken sccache write path (B); sccache alone cannot.
    Always exits 0: the output is the product, and a non-zero exit would truncate the evidence.
#>
[CmdletBinding()]
param(
    [string]$CacheDir = $env:SCCACHE_DIR,

    # Child mode for the spawn matrix: one write, verdict appended to a file since a detached child has no console.
    [string]$ChildWrite = '',
    [string]$ResultFile = '',

    # Layer-cache buster; only echoed, it makes each solve a distinct RUN.
    [string]$Nonce = ''
)

$ErrorActionPreference = 'Continue'
if (-not $CacheDir) { $CacheDir = 'C:\sccache' }

function Write-Section { param([string]$Title) Write-Host "`n=== $Title ===" }
function Write-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $tag = if ($Ok) { '[ OK ]' } else { '[FAIL]' }
    Write-Host ("{0} {1}{2}" -f $tag, $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

if ($ChildWrite) {
    # What the child sees too: a missing or empty mount alone would explain os error 3.
    $report = [ordered]@{
        user    = (whoami)
        pid     = $PID
        cwd     = (Get-Location).Path
        dir     = $ChildWrite
        exists  = (Test-Path $ChildWrite)
        entries = -1
        write   = 'not attempted'
    }
    try { $report.entries = @(Get-ChildItem $ChildWrite -Force -ErrorAction Stop).Count } catch { $report.entries = "ERR: $($_.Exception.Message)" }
    try {
        $nested = Join-Path $ChildWrite ('childprobe\' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $nested -ErrorAction Stop
        $f = Join-Path $nested 'c.bin'
        [IO.File]::WriteAllBytes($f, [byte[]](1..32))
        $report.write = 'OK'
        Remove-Item (Join-Path $ChildWrite 'childprobe') -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        $report.write = "FAIL: $($_.Exception.Message)"
    }
    $line = ($report.Keys | ForEach-Object { "$_=$($report[$_])" }) -join ' | '
    if ($ResultFile) { Add-Content -Path $ResultFile -Value $line -Encoding utf8 } else { Write-Host $line }
    return
}

Write-Section "probe run (nonce=$Nonce)"

Write-Section 'environment'
foreach ($n in 'SCCACHE_DIR', 'SCCACHE_CACHE_SIZE', 'SCCACHE_MULTILEVEL_CHAIN',
    'SCCACHE_WEBDAV_ENDPOINT', 'SCCACHE_ERROR_LOG', 'SCCACHE_LOG',
    'SCCACHE_IDLE_TIMEOUT', 'TEMP', 'TMP', 'USERPROFILE') {
    Write-Host ("  {0,-26} = {1}" -f $n, [Environment]::GetEnvironmentVariable($n))
}
Write-Host ("  {0,-26} = {1}" -f 'CWD', (Get-Location).Path)
Write-Host ("  {0,-26} = {1}" -f 'whoami', (whoami))

Write-Section "target directory: $CacheDir"
if (Test-Path $CacheDir) {
    $di = Get-Item $CacheDir -Force
    Write-Host "  exists     : yes"
    Write-Host "  attributes : $($di.Attributes)"
    Write-Host "  full name  : $($di.FullName)"
    # A reparse point could resolve differently for the server process than for this script.
    Write-Result 'not a reparse point' (-not ($di.Attributes -band [IO.FileAttributes]::ReparsePoint))
    # With types: a file where a single-hex bucket directory belongs would fail every insert into it.
    $top = @(Get-ChildItem $CacheDir -Force -ErrorAction SilentlyContinue)
    Write-Host "  entries    : $($top.Count)"
    foreach ($e in $top) {
        $kind = if ($e.PSIsContainer) { 'DIR ' } else { 'FILE' }
        $size = if ($e.PSIsContainer) { '' } else { " ($($e.Length) bytes)" }
        Write-Host ("    {0} {1}{2}" -f $kind, $e.Name, $size)
    }
} else {
    Write-Result "$CacheDir exists" $false 'MISSING - the cache mount is not present in this RUN'
}

# Hypothesis A: each step of sccache's nested-dir, temp-then-rename write is tested alone, so the failing one is named.
Write-Section 'raw filesystem tests (hypothesis A)'

$probeRoot = Join-Path $CacheDir 'probe-tmp'
$nested = Join-Path $probeRoot 'a1\b2'
try {
    $null = New-Item -ItemType Directory -Force -Path $nested -ErrorAction Stop
    Write-Result 'create nested directory' $true $nested
} catch {
    Write-Result 'create nested directory' $false $_.Exception.Message
}

$plain = Join-Path $nested 'plain.bin'
try {
    [IO.File]::WriteAllBytes($plain, [byte[]](1..64))
    Write-Result 'write file in nested dir' $true "$plain ($((Get-Item $plain).Length) bytes)"
} catch {
    Write-Result 'write file in nested dir' $false $_.Exception.Message
}

# A rename across a wcifs layer boundary can fail where a plain write succeeds (cf. Test-LayerRename.ps1).
$tmpFile = Join-Path $probeRoot 'staged.tmp'
$renamed = Join-Path $nested 'renamed.bin'
try {
    [IO.File]::WriteAllBytes($tmpFile, [byte[]](1..64))
    [IO.File]::Move($tmpFile, $renamed)
    Write-Result 'rename temp -> cache path' $true $renamed
} catch {
    Write-Result 'rename temp -> cache path' $false $_.Exception.Message
}

# Staged from %TEMP% instead: failing only here points at the temp directory.
$sysTmp = [IO.Path]::GetTempPath()
Write-Host "  system temp: $sysTmp (exists: $(Test-Path $sysTmp))"
$tmpFile2 = Join-Path $sysTmp ('sccache-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$renamed2 = Join-Path $nested 'from-systemp.bin'
try {
    [IO.File]::WriteAllBytes($tmpFile2, [byte[]](1..64))
    [IO.File]::Move($tmpFile2, $renamed2)
    Write-Result 'rename %TEMP% -> cache path' $true $renamed2
} catch {
    Write-Result 'rename %TEMP% -> cache path' $false $_.Exception.Message
    Remove-Item $tmpFile2 -Force -ErrorAction SilentlyContinue
}

Remove-Item $probeRoot -Recurse -Force -ErrorAction SilentlyContinue

# New vs inherited paths: a failed raw write into the mount's existing bucket tree is a filesystem defect, not sccache's.
Write-Section 'raw write into a PRE-EXISTING deep path from the mount'

$deep = Get-ChildItem $CacheDir -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[0-9a-f]$' } |
    ForEach-Object { Get-ChildItem $_.FullName -Force -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue } |
    Select-Object -First 3
if (-not $deep) {
    Write-Host '  no pre-existing nested bucket path found (cache root is empty?)'
} else {
    foreach ($dir in $deep) {
        $probeFile = Join-Path $dir.FullName ('inherited-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.bin')
        try {
            [IO.File]::WriteAllBytes($probeFile, [byte[]](1..64))
            Write-Result "write into inherited path" $true $dir.FullName
            Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Result "write into inherited path" $false "$($dir.FullName) -> $($_.Exception.Message)"
        }
    }
}

# The server is detached: do spawned children lose the mount? A plain dir is the control for each spawn shape.
Write-Section 'spawn matrix: can a CHILD process write to the cache mount?'

$self = $PSCommandPath
$altDirEarly = 'C:\sccache-alt'
$null = New-Item -ItemType Directory -Force -Path $altDirEarly -ErrorAction SilentlyContinue
$resFile = Join-Path $env:TEMP ('spawn-results-' + [Guid]::NewGuid().ToString('N') + '.txt')
Set-Content -Path $resFile -Value $null -Force

$pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
$shell = if ($pwsh) { $pwsh.Source } else { (Get-Command powershell.exe).Source }
Write-Host "  child shell: $shell"

function Invoke-SpawnMode {
    param([string]$Mode, [string]$Dir)
    $tagLine = "MODE=$Mode DIR=$Dir"
    Add-Content -Path $resFile -Value "--- $tagLine"
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
        '-ChildWrite', $Dir, '-ResultFile', $resFile)
    switch ($Mode) {
        'attached' {
            # Ordinary synchronous child, console inherited.
            & $shell @childArgs 2>&1 | Out-Null
        }
        'hidden-async' {
            $p = Start-Process -FilePath $shell -ArgumentList $childArgs -WindowStyle Hidden -PassThru
            $null = $p.WaitForExit(60000)
        }
        'detached' {
            # The closest shape to `sccache --start-server`.
            $psi = [Diagnostics.ProcessStartInfo]::new($shell)
            foreach ($a in $childArgs) { $null = $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [Diagnostics.Process]::Start($psi)
            $null = $proc.WaitForExit(60000)
        }
    }
}

foreach ($mode in 'attached', 'hidden-async', 'detached') {
    foreach ($d in $CacheDir, $altDirEarly) { Invoke-SpawnMode -Mode $mode -Dir $d }
}

Get-Content $resFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
Remove-Item $resFile -Force -ErrorAction SilentlyContinue

# Hypothesis B: vary one sccache factor per unique compile; only the multilevel rows failing is an upstream bug.
$sccache = (Get-Command sccache.exe -ErrorAction SilentlyContinue)
if (-not $sccache) {
    Write-Result 'sccache.exe on PATH' $false 'cannot run the compile test'
    return
}
Write-Host "`n  sccache: $($sccache.Source)"

$origEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT
$origChain = $env:SCCACHE_MULTILEVEL_CHAIN
$origDir = $env:SCCACHE_DIR
$altDir = 'C:\sccache-alt'
$null = New-Item -ItemType Directory -Force -Path $altDir -ErrorAction SilentlyContinue

function Invoke-SccacheVariant {
    param(
        [string]$Name,
        [string]$Chain,       # '' => unset
        [string]$Endpoint,    # '' => unset
        [string]$Dir
    )
    Write-Section "variant: $Name"

    # The server reads its config once at start, so a running one would silently measure the old config.
    & $sccache.Source --stop-server 2>&1 | Out-Null
    $global:LASTEXITCODE = 0

    if ($Chain) { $env:SCCACHE_MULTILEVEL_CHAIN = $Chain } else { Remove-Item Env:\SCCACHE_MULTILEVEL_CHAIN -ErrorAction SilentlyContinue }
    if ($Endpoint) { $env:SCCACHE_WEBDAV_ENDPOINT = $Endpoint } else { Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue }
    $env:SCCACHE_DIR = $Dir
    Write-Host ("  chain='{0}' endpoint='{1}' dir='{2}'" -f $Chain, $Endpoint, $Dir)

    Push-Location 'C:\'
    try { & $sccache.Source --start-server 2>&1 | Where-Object { $_ -match 'Listening|error' } | ForEach-Object { Write-Host "  start| $_" } }
    finally { Pop-Location }
    $global:LASTEXITCODE = 0
    & $sccache.Source --zero-stats 2>&1 | Out-Null
    $global:LASTEXITCODE = 0

    # Truncated per variant, so the dump below belongs to this variant.
    if ($env:SCCACHE_ERROR_LOG) {
        Set-Content -Path $env:SCCACHE_ERROR_LOG -Value $null -Force -ErrorAction SilentlyContinue
    }

    # A unique token in real code, not a comment: sccache hashes preprocessed output, and a hit attempts no write.
    $tag = [Guid]::NewGuid().ToString('N')
    $work = Join-Path $env:TEMP ('sccache-probe-' + $tag)
    $null = New-Item -ItemType Directory -Force -Path $work
    $src = Join-Path $work 'probe.cpp'
    @"
#include <cstdio>
int probe_value_$tag() { return 42; }
int main() { std::printf("%d\n", probe_value_$tag()); return 0; }
"@ | Set-Content -Path $src -Encoding ascii

    $compileOk = $false
    Push-Location $work
    try {
        $obj = Join-Path $work 'probe.obj'
        # /Fo without a colon: sccache turns /Fo:C:\x.obj into the bogus path C:\:C:\x.obj.
        & $sccache.Source clang-cl /c /nologo /EHsc "/Fo$obj" $src 2>&1 |
            Where-Object { $_ -notmatch 'DEBUG|INFO ' } | ForEach-Object { Write-Host "  cl| $_" }
        $compileOk = ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }

    $stats = @(& $sccache.Source --show-stats 2>&1)
    $global:LASTEXITCODE = 0
    $stats | Where-Object { $_ -match 'Cache misses\s+\d|Cache write errors|write failures' } |
        ForEach-Object { Write-Host "  $($_.ToString().Trim())" }

    $writeErr = -1
    foreach ($line in $stats) {
        if ($line -match 'Cache write errors\s+(\d+)') { $writeErr = [int]$Matches[1]; break }
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Result "$Name wrote to cache" ($writeErr -eq 0) "compile exit ok=$compileOk, write errors=$writeErr"

    # Stopping flushes the log (the server never idles out), where a failing variant names the path it could not write.
    & $sccache.Source --stop-server 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
    if ($env:SCCACHE_ERROR_LOG -and (Test-Path $env:SCCACHE_ERROR_LOG)) {
        $vlines = @(Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue)
        $interesting = @($vlines | Where-Object {
                $_ -match 'storing in cache|Created cache artifact|executing cache write|storage|cache_write|service=fs|Failed|failed' -and
                $_ -notmatch 'Mozilla'
            })
        Write-Host "  -- storage trace ($($interesting.Count) line(s) of $($vlines.Count)) --"
        $interesting | Select-Object -Last 12 | ForEach-Object { Write-Host "  trace| $($_.ToString().Trim())" }
    }

    return [pscustomobject]@{ Name = $Name; WriteErrors = $writeErr }
}

# An empty dir on the mount vs off it isolates the mount; kept across runs to test inheriting this run's objects.
$mountSubdir = Join-Path $origDir 'probe-persist'
$null = New-Item -ItemType Directory -Force -Path $mountSubdir -ErrorAction SilentlyContinue

$results = @()
$results += Invoke-SccacheVariant -Name 'disk-only'           -Chain ''             -Endpoint ''            -Dir $origDir
$results += Invoke-SccacheVariant -Name 'disk-mounted-subdir' -Chain ''             -Endpoint ''            -Dir $mountSubdir
$results += Invoke-SccacheVariant -Name 'disk-plaindir'       -Chain ''             -Endpoint ''            -Dir $altDir
$results += Invoke-SccacheVariant -Name 'multilevel-mounted'  -Chain 'disk,webdav'  -Endpoint $origEndpoint -Dir $origDir
$results += Invoke-SccacheVariant -Name 'multilevel-plaindir' -Chain 'disk,webdav'  -Endpoint $origEndpoint -Dir $altDir
$results += Invoke-SccacheVariant -Name 'webdav-only'         -Chain ''             -Endpoint $origEndpoint -Dir $origDir
$persistCount = @(Get-ChildItem $mountSubdir -Recurse -Force -File -ErrorAction SilentlyContinue).Count
Write-Host "  (probe-persist now holds $persistCount file(s) - inherited by the NEXT run)"

# Restored, so the error-log dump below reflects the real build configuration.
$env:SCCACHE_MULTILEVEL_CHAIN = $origChain
$env:SCCACHE_WEBDAV_ENDPOINT = $origEndpoint
$env:SCCACHE_DIR = $origDir

Write-Section 'MATRIX VERDICT'
foreach ($r in $results) {
    Write-Host ("  {0,-22} write errors = {1}" -f $r.Name, $r.WriteErrors)
}
$byName = @{}
foreach ($r in $results) { $byName[$r.Name] = $r.WriteErrors }
# Separates a broken mount from broken existing content: same config, empty targets on and off the mount.
$onMountEmpty = $byName['disk-mounted-subdir']
$offMountEmpty = $byName['disk-plaindir']
$onMountFull = $byName['disk-only']
if ($null -ne $onMountEmpty -and $null -ne $offMountEmpty -and $null -ne $onMountFull) {
    if ($onMountFull -gt 0 -and $onMountEmpty -eq 0 -and $offMountEmpty -eq 0) {
        Write-Host '  => An EMPTY dir ON the mount writes fine; the POPULATED root does not.'
        Write-Host '  => The cache mount is innocent. The existing C:\sccache CONTENT is the fault'
        Write-Host '     (candidates: the foreign `logs` dir and `wtest.txt` in the cache root).'
    } elseif ($onMountFull -gt 0 -and $onMountEmpty -gt 0 -and $offMountEmpty -eq 0) {
        Write-Host '  => Empty or full, anything ON the mount fails; off the mount succeeds.'
        Write-Host '  => The BuildKit cache mount itself is the fault.'
    }
}

# A valid root holds only the 16 hex buckets and `preprocessor`; anything else is moved off the mount, sizes printed first.
Write-Section 'narrowing: quarantine foreign entries in the cache root'

$quarantine = 'C:\sccache-quarantine'
$null = New-Item -ItemType Directory -Force -Path $quarantine -ErrorAction SilentlyContinue

# The probe's own inherited state must never be swept as debris, or it destroys its own experiment.
$probeOwned = @('preprocessor', 'bulk-inherit', 'probe-persist')
$foreign = @(Get-ChildItem $origDir -Force -ErrorAction SilentlyContinue | Where-Object {
        -not ($_.PSIsContainer -and $_.Name -match '^[0-9a-f]$') -and $probeOwned -notcontains $_.Name
    })
# The bisect runs whenever disk-only failed, even with no foreign entries left to move.
$after = $null
if (-not $foreign) {
    Write-Host '  no foreign entries left in the root (an earlier run removed them).'
} else {
    foreach ($f in $foreign) {
        $bytes = if ($f.PSIsContainer) {
            (Get-ChildItem $f.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } else { $f.Length }
        Write-Host ("  foreign: {0,-14} {1,12:N0} bytes  ({2})" -f $f.Name, [long]$bytes, $(if ($f.PSIsContainer) { 'dir' } else { 'file' }))
    }
    foreach ($f in $foreign) {
        try {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $quarantine $f.Name) -Force -ErrorAction Stop
            Write-Result "moved $($f.Name) off the mount" $true
        } catch {
            Write-Result "moved $($f.Name) off the mount" $false $_.Exception.Message
        }
    }
    $after = Invoke-SccacheVariant -Name 'disk-only-after-cleanup' -Chain '' -Endpoint '' -Dir $origDir
    Write-Section 'NARROWING VERDICT'
    Write-Host ("  before cleanup: write errors = {0}" -f $byName['disk-only'])
    Write-Host ("  after  cleanup: write errors = {0}" -f $after.WriteErrors)
}

$stillFailing = if ($null -ne $after) { $after.WriteErrors -gt 0 } else { $byName['disk-only'] -gt 0 }
if ($null -ne $after -and $byName['disk-only'] -gt 0 -and $after.WriteErrors -eq 0) {
    Write-Host '  => CONFIRMED: the foreign entries in the cache root broke every insert.'
    Write-Host '  => They are gone now; the L0 disk cache writes again, cache content intact.'
} elseif ($stillFailing) {
    if ($null -ne $after) { Write-Host '  => NOT the foreign entries: the populated root still fails without them.' }
    if ($true) {
        # One change per measurement; everything moves back at the end, or the RUN would take the real cache with it.
        Write-Section 'bisecting the cache root'
        $moved = @{}
        function Move-Out {
            param([string]$Name)
            $src = Join-Path $origDir $Name
            if (-not (Test-Path $src)) { return }
            $dst = Join-Path $quarantine $Name
            try { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; $moved[$Name] = $dst } catch { Write-Host "  could not move $Name : $($_.Exception.Message)" }
        }
        function Move-Back {
            param([string]$Name)
            if (-not $moved.ContainsKey($Name)) { return }
            try { Move-Item -LiteralPath $moved[$Name] -Destination (Join-Path $origDir $Name) -Force -ErrorAction Stop; $null = $moved.Remove($Name) } catch { Write-Host "  could not restore $Name : $($_.Exception.Message)" }
        }
        function Test-Root { param([string]$Label) (Invoke-SccacheVariant -Name $Label -Chain '' -Endpoint '' -Dir $origDir).WriteErrors }

        Move-Out 'preprocessor'
        $noPre = Test-Root 'without-preprocessor'
        if ($noPre -eq 0) {
            Write-Host '  => CULPRIT: the `preprocessor` directory in the cache root.'
            # Left out, so the sections below test without it and show whether stale content or the feature is at fault.
            $null = $moved.Remove('preprocessor')
            Write-Host '  (left out of the mount so the sections below test without it)'
        } else {
            $buckets = @('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f')
            foreach ($b in $buckets) { Move-Out $b }
            $empty = Test-Root 'all-buckets-removed'
            if ($empty -ne 0) {
                Write-Host '  => Even an emptied root at this PATH fails, while a fresh subdir does not.'
                Write-Host '  => Whatever is left is not file content - suspect the path itself.'
            } else {
                Write-Host '  => Bucket content is the fault. Binary-searching for the bucket...'
                $suspects = $buckets
                while ($suspects.Count -gt 1) {
                    $half = [Math]::Floor($suspects.Count / 2)
                    $firstHalf = $suspects[0..($half - 1)]
                    foreach ($b in $firstHalf) { Move-Back $b }
                    $r = Test-Root ("half[" + ($firstHalf -join '') + "]")
                    if ($r -gt 0) {
                        $suspects = $firstHalf
                        foreach ($b in $firstHalf) { Move-Out $b }
                    } else {
                        $suspects = $suspects[$half..($suspects.Count - 1)]
                    }
                    Write-Host ("  narrowed to: {0}" -f ($suspects -join ','))
                }
                # Elimination is an inference; restoring the suspect alone must reproduce the failure.
                $culprit = $suspects[0]
                Move-Back $culprit
                $confirm = Test-Root "confirm-bucket-$culprit"
                Write-Host ("  => CULPRIT BUCKET: {0} (restored alone -> write errors = {1})" -f $culprit, $confirm)
                if ($confirm -gt 0) {
                    Write-Host '  => CONFIRMED by reproduction, not by elimination.'
                    $cb = Join-Path $origDir $culprit
                    $kids = @(Get-ChildItem $cb -Force -ErrorAction SilentlyContinue)
                    Write-Host ("  bucket '{0}' holds {1} top-level entr(y|ies):" -f $culprit, $kids.Count)
                    foreach ($k in $kids) {
                        $kind = if ($k.PSIsContainer) { 'DIR ' } else { 'FILE' }
                        $sz = if ($k.PSIsContainer) { '' } else { " ($($k.Length) bytes)" }
                        Write-Host ("    {0} {1}{2}" -f $kind, $k.Name, $sz)
                    }
                    # A valid bucket holds only single-hex dirs; a file here or a zero-byte object deeper is an anomaly.
                    $odd = @($kids | Where-Object { -not ($_.PSIsContainer -and $_.Name -match '^[0-9a-f]$') })
                    if ($odd) { Write-Host ("  ANOMALY: {0} entr(y|ies) are not single-hex directories: {1}" -f $odd.Count, (($odd | ForEach-Object { $_.Name }) -join ', ')) }
                    $zero = @(Get-ChildItem $cb -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 0 })
                    if ($zero) { Write-Host ("  ANOMALY: {0} zero-byte object(s), e.g. {1}" -f $zero.Count, $zero[0].FullName) }
                } else {
                    Write-Host '  => NOT REPRODUCED: restoring it alone writes fine, so the'
                    Write-Host '     failure needs a COMBINATION of buckets (or total size), not one entry.'
                }
            }
        }
        # Restore everything so the mount keeps its cache.
        foreach ($k in @($moved.Keys)) { Move-Back $k }
        Write-Host '  restored all buckets to the mount.'
    }
}

# N unique compiles: a repaired root fails 0/N, a path-dependent defect a steady fraction; one compile cannot tell.
Write-Section 'determinism: N unique compiles against the populated root'

$env:SCCACHE_MULTILEVEL_CHAIN = $origChain
$env:SCCACHE_WEBDAV_ENDPOINT = $origEndpoint
$env:SCCACHE_DIR = $origDir
# Both configurations: the real build uses the chain, so disk-only alone proves nothing about it.
$repeat = 6
$summary = @()
foreach ($cfg in @(
        @{ Label = 'disk-only'; Chain = ''; Endpoint = '' },
        @{ Label = 'multilevel'; Chain = 'disk,webdav'; Endpoint = $origEndpoint }
    )) {
    $fails = 0
    for ($i = 1; $i -le $repeat; $i++) {
        $r = Invoke-SccacheVariant -Name "$($cfg.Label)-repeat-$i" -Chain $cfg.Chain -Endpoint $cfg.Endpoint -Dir $origDir
        if ($r.WriteErrors -gt 0) { $fails++ }
    }
    $summary += [pscustomobject]@{ Label = $cfg.Label; Fails = $fails }
    Write-Host ("  {0,-12} {1} of {2} runs failed to write" -f $cfg.Label, $fails, $repeat)
}

$d = ($summary | Where-Object { $_.Label -eq 'disk-only' }).Fails
$m = ($summary | Where-Object { $_.Label -eq 'multilevel' }).Fails
if ($d -eq 0 -and $m -eq $repeat) {
    Write-Host '  => THE CHAIN IS THE FAULT: the same populated directory writes cleanly'
    Write-Host '     as a plain disk cache and fails 100% through SCCACHE_MULTILEVEL_CHAIN.'
    Write-Host '     Minimal repro for upstream; and dropping L0 fixes it here today.'
} elseif ($d -eq 0 -and $m -eq 0) {
    Write-Host '  => Both configurations write cleanly HERE, yet the build still fails —'
    Write-Host '     so the probe environment still differs from the build. Do not claim a fix.'
} elseif ($d -eq $repeat -and $m -eq $repeat) {
    Write-Host '  => Still 100% broken in both; the earlier "repair" was an artefact.'
} else {
    Write-Host ('  => Mixed result (disk {0}/{1}, chain {2}/{1}): path-dependent damage.' -f $d, $repeat, $m)
}

# Concurrency: the build writes in parallel (ninja -j), which the serial runs above never reproduce.
Write-Section 'concurrency: N unique compiles AT ONCE'

$parallel = 16
& $sccache.Source --stop-server 2>&1 | Out-Null
$env:SCCACHE_MULTILEVEL_CHAIN = $origChain
$env:SCCACHE_WEBDAV_ENDPOINT = $origEndpoint
$env:SCCACHE_DIR = $origDir
Push-Location 'C:\'
try { & $sccache.Source --start-server 2>&1 | Where-Object { $_ -match 'Listening|error' } | ForEach-Object { Write-Host "  start| $_" } }
finally { Pop-Location }
& $sccache.Source --zero-stats 2>&1 | Out-Null
$global:LASTEXITCODE = 0

$pwork = Join-Path $env:TEMP ('sccache-par-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $pwork
$procs = @()
for ($i = 1; $i -le $parallel; $i++) {
    $t = [Guid]::NewGuid().ToString('N')
    $s = Join-Path $pwork "p$i.cpp"
    @"
#include <cstdio>
int probe_value_$t() { return $i; }
int main() { std::printf("%d\n", probe_value_$t()); return 0; }
"@ | Set-Content -Path $s -Encoding ascii
    $psi = [Diagnostics.ProcessStartInfo]::new($sccache.Source)
    foreach ($a in @('clang-cl', '/c', '/nologo', '/EHsc', "/Fo$(Join-Path $pwork "p$i.obj")", $s)) { $null = $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $pwork
    $procs += [Diagnostics.Process]::Start($psi)
}
foreach ($p in $procs) { $null = $p.WaitForExit(180000) }
$okCount = @($procs | Where-Object { $_.HasExited -and $_.ExitCode -eq 0 }).Count
Write-Host "  $okCount of $parallel concurrent compiles exited 0"

$pstats = @(& $sccache.Source --show-stats 2>&1)
$global:LASTEXITCODE = 0
$pstats | Where-Object { $_ -match 'Compile requests\s+\d|Cache misses\s+\d|Cache write errors|write failures' } |
    ForEach-Object { Write-Host "  $($_.ToString().Trim())" }
$pWriteErr = -1
foreach ($line in $pstats) { if ($line -match 'Cache write errors\s+(\d+)') { $pWriteErr = [int]$Matches[1]; break } }
Remove-Item $pwork -Recurse -Force -ErrorAction SilentlyContinue

Write-Section 'CONCURRENCY VERDICT'
Write-Host ("  serial (6+6 runs): {0} + {1} write failures" -f $d, $m)
Write-Host ("  parallel ({0} at once): {1} write failures" -f $parallel, $pWriteErr)
if ($pWriteErr -gt 0 -and $d -eq 0 -and $m -eq 0) {
    Write-Host '  => CONCURRENCY IS THE TRIGGER: the same mount, the same config, the same'
    Write-Host '     server - serial writes succeed, parallel writes fail. That is the build.'
} elseif ($pWriteErr -eq 0) {
    Write-Host '  => Not concurrency either: 16 at once write cleanly. The probe still'
    Write-Host '     does not reproduce the build; something else about the media RUN differs.'
}

# Path length: os error 3 is also what a path past MAX_PATH returns, and the build compiles from deep CMake paths.
Write-Section 'path length: compile from a DEEP source path'

$deepRoot = 'C:\temp'
$seg = 'a-very-long-directory-segment-mimicking-a-cmake-object-dir'
$deepDir = $deepRoot
foreach ($i in 1..3) { $deepDir = Join-Path $deepDir "$seg-$i" }
$null = New-Item -ItemType Directory -Force -Path $deepDir -ErrorAction SilentlyContinue
Write-Host ("  depth: {0} chars -> {1}" -f $deepDir.Length, $deepDir)

if (-not (Test-Path $deepDir)) {
    Write-Host '  could not create the deep directory (already a MAX_PATH failure at mkdir).'
} else {
    & $sccache.Source --stop-server 2>&1 | Out-Null
    $env:SCCACHE_DIR = $origDir
    Push-Location 'C:\'
    try { & $sccache.Source --start-server 2>&1 | Where-Object { $_ -match 'Listening' } | ForEach-Object { Write-Host "  start| $_" } }
    finally { Pop-Location }
    & $sccache.Source --zero-stats 2>&1 | Out-Null
    $global:LASTEXITCODE = 0

    $t = [Guid]::NewGuid().ToString('N')
    $dsrc = Join-Path $deepDir 'deep_probe_translation_unit_with_a_long_name.cpp'
    @"
#include <cstdio>
int probe_value_$t() { return 7; }
int main() { std::printf("%d\n", probe_value_$t()); return 0; }
"@ | Set-Content -Path $dsrc -Encoding ascii
    $dobj = Join-Path $deepDir 'deep_probe_translation_unit_with_a_long_name.cpp.obj'
    Write-Host ("  source path: {0} chars / object path: {1} chars" -f $dsrc.Length, $dobj.Length)
    Push-Location $deepDir
    try {
        & $sccache.Source clang-cl /c /nologo /EHsc "/Fo$dobj" $dsrc 2>&1 |
            Where-Object { $_ -notmatch 'DEBUG|INFO |TRACE' } | ForEach-Object { Write-Host "  cl| $_" }
        Write-Result 'deep compile exited 0' ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }

    $dstats = @(& $sccache.Source --show-stats 2>&1)
    $global:LASTEXITCODE = 0
    $dstats | Where-Object { $_ -match 'Cache misses\s+\d|Cache write errors|write failures' } |
        ForEach-Object { Write-Host "  $($_.ToString().Trim())" }
    $dErr = -1
    foreach ($line in $dstats) { if ($line -match 'Cache write errors\s+(\d+)') { $dErr = [int]$Matches[1]; break } }
    Write-Section 'PATH-LENGTH VERDICT'
    if ($dErr -gt 0) {
        Write-Host '  => REPRODUCED from a deep source path while short paths write cleanly.'
        Write-Host '     Path length is the trigger; os error 3 is MAX_PATH, not a bad directory.'
    } else {
        Write-Host '  => Not path length either: a deep source path writes cleanly too.'
    }
    Remove-Item (Join-Path $deepRoot "$seg-1") -Recurse -Force -ErrorAction SilentlyContinue
}

# Bulk: N objects on vs off the BuildKit cache mount, since losses only show once the directory holds content.
Write-Section "bulk write test: cache MOUNT vs plain directory (N unique objects)"

function Invoke-BulkWrite {
    param([string]$Label, [string]$Dir, [int]$Count)

    & $sccache.Source --stop-server 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
    Remove-Item Env:\SCCACHE_MULTILEVEL_CHAIN -ErrorAction SilentlyContinue
    Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue
    $env:SCCACHE_DIR = $Dir
    $null = New-Item -ItemType Directory -Force -Path $Dir -ErrorAction SilentlyContinue
    Push-Location 'C:\'
    try { & $sccache.Source --start-server 2>&1 | Where-Object { $_ -match 'Listening|error' } | ForEach-Object { Write-Host "  start| $_" } }
    finally { Pop-Location }
    & $sccache.Source --zero-stats 2>&1 | Out-Null
    $global:LASTEXITCODE = 0

    $work = Join-Path $env:TEMP ('bulk-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $work
    Push-Location $work
    try {
        for ($i = 1; $i -le $Count; $i++) {
            # Unique in real code: a comment is preprocessed away and every TU would share one key.
            $t = [Guid]::NewGuid().ToString('N')
            $s = Join-Path $work "b$i.cpp"
            "int probe_$t() { return $i; }" | Set-Content -Path $s -Encoding ascii
            & $sccache.Source clang-cl /c /nologo "/Fo$(Join-Path $work "b$i.obj")" $s 2>&1 | Out-Null
        }
    } finally { Pop-Location }
    $global:LASTEXITCODE = 0

    $st = @(& $sccache.Source --show-stats 2>&1)
    $global:LASTEXITCODE = 0
    $misses = -1; $werr = -1
    foreach ($line in $st) {
        if ($line -match 'Cache misses\s+(\d+)') { if ($misses -lt 0) { $misses = [int]$Matches[1] } }
        if ($line -match 'Cache write errors\s+(\d+)') { if ($werr -lt 0) { $werr = [int]$Matches[1] } }
    }
    $sz = ($st | Where-Object { $_ -match 'Cache size\s+(.*)' } | Select-Object -First 1)
    Write-Host ("  {0,-14} dir={1}" -f $Label, $Dir)
    Write-Host ("  {0,-14} misses={1} write errors={2}  {3}" -f '', $misses, $werr, $(if ($sz) { $sz.ToString().Trim() } else { '' }))
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Label = $Label; Misses = $misses; WriteErrors = $werr }
}

# Stable names, kept: the trigger is inheriting a populated dir across RUNs, so the second probe run is the experiment.
$bulkN = 250
$mountDir = Join-Path $CacheDir 'bulk-inherit'   # ON the BuildKit cache mount
$plainDir = 'C:\bulk-plain-inherit'              # NOT a mount: container filesystem
foreach ($d in $mountDir, $plainDir) {
    $n = @(Get-ChildItem $d -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    Write-Host ("  inherited from a previous run: {0,-28} {1} file(s)" -f $d, $n)
}

$onMount = Invoke-BulkWrite -Label 'ON mount' -Dir $mountDir -Count $bulkN
$offMount = Invoke-BulkWrite -Label 'OFF mount' -Dir $plainDir -Count $bulkN

Write-Section 'BULK VERDICT'
Write-Host ("  ON  mount ({0}): {1} write errors of {2} misses" -f $mountDir, $onMount.WriteErrors, $onMount.Misses)
Write-Host ("  OFF mount ({0}): {1} write errors of {2} misses" -f $plainDir, $offMount.WriteErrors, $offMount.Misses)
if ($onMount.WriteErrors -gt 0 -and $offMount.WriteErrors -eq 0) {
    Write-Host '  => THE BUILDKIT CACHE MOUNT IS THE FAULT. Same sccache, same config,'
    Write-Host '     same object count — only the target filesystem differs. Reportable'
    Write-Host '     against moby/buildkit (WCOW cache mounts), not against sccache.'
} elseif ($onMount.WriteErrors -gt 0 -and $offMount.WriteErrors -gt 0) {
    Write-Host '  => Both fail: it is sccache, not the mount. Report against mozilla/sccache.'
} elseif ($onMount.WriteErrors -eq 0 -and $offMount.WriteErrors -eq 0) {
    Write-Host ('  => Neither fails at N={0}. Either the threshold is higher, or the probe' -f $bulkN)
    Write-Host '     still differs from a real build. Do NOT read this as a clean bill.'
}
# Not deleted; the plain dir dies with the container, which makes it the control.
Write-Host ("  kept for the next run: {0}" -f $mountDir)

Write-Section 'sccache error log'
& $sccache.Source --stop-server 2>&1 | Where-Object { $_ -match 'Stopping|error' } | ForEach-Object { Write-Host "  stop| $_" }
$global:LASTEXITCODE = 0
$errLog = $env:SCCACHE_ERROR_LOG
if ($errLog -and (Test-Path $errLog)) {
    $lines = @(Get-Content $errLog -ErrorAction SilentlyContinue)
    $writeFails = @($lines | Where-Object { $_ -match 'Error executing cache write' })
    Write-Host "  $($lines.Count) line(s) in $errLog; $($writeFails.Count) cache-write error(s)"
    $lines | Select-Object -Last 25 | ForEach-Object { Write-Host "  log| $_" }
} else {
    Write-Host "  no error log at '$errLog'"
}

Remove-Item $altDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n=== probe complete ==="

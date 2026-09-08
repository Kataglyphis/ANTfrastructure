#requires -Version 7.0
<#
.SYNOPSIS
    Diagnose WHY every sccache L0 (disk) cache write fails with
    `The system cannot find the path specified. (os error 3)`.

.DESCRIPTION
    Runs INSIDE a container RUN that carries the SAME cache mounts and the SAME
    sccache environment as the media builder, so anything this script sees is
    what the real build sees. Bind-mounted rather than COPY'd or inlined (the
    #27 pattern) so it can be edited without busting a layer.

    MEASURED CONTEXT (2026-08-15, the run this probe exists to explain):
      onnx    0 misses  ->   0 writes ->   0 failures
      opencv  1 miss    ->   1 write  ->   1 failure
      genai 157 misses  -> 157 writes -> 157 failures
    i.e. EVERY L0 write fails, 100%, in every stage - the earlier
    "genai is special" reading was an artefact of the miss counts. And
    `L1 (webdav) writes 0` alongside it: when L0 fails the whole write chain
    dies there, so nothing ever reaches the remote either.

    Two hypotheses this probe separates, which is its entire job:
      A) C:\sccache itself is not writable (mount/ACL/filesystem level)
         -> the raw .NET write tests below fail too.
      B) The directory is fine and sccache's OWN write path is what breaks
         (temp-file placement, cross-device rename, path length, ...)
         -> raw writes SUCCEED and only the sccache compile fails.
    Do not skip the raw tests: a probe that only runs sccache cannot tell
    these apart, which is how the CWD theory survived as long as it did.

    Exits 0 even when tests fail - this is a DIAGNOSTIC, its output is the
    product. A non-zero exit would only truncate the evidence.
#>
[CmdletBinding()]
param(
    [string]$CacheDir = $env:SCCACHE_DIR,

    # --- child mode (the script re-invokes ITSELF; see the spawn matrix) ------
    # When -ChildWrite is given the script does nothing but attempt one write
    # into that directory and append a one-line verdict to -ResultFile, then
    # exits. Results go to a FILE because a detached child has no console to
    # write to - printing would silently lose exactly the evidence we are after.
    [string]$ChildWrite = '',
    [string]$ResultFile = '',

    # Layer-cache buster, threaded through from the Dockerfile ARG. Unused apart
    # from being echoed - its only job is to make each solve a distinct RUN.
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
    # Report what this process can SEE as well as what it can DO: if a spawned
    # child finds the cache mount missing or empty, that alone explains
    # `os error 3` and makes the write result secondary.
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
    # A reparse point here would be the smoking gun for a mount that resolves
    # differently for the server process than for this script.
    Write-Result 'not a reparse point' (-not ($di.Attributes -band [IO.FileAttributes]::ReparsePoint))
    # Full listing with TYPE: sccache's disk cache buckets objects into
    # single-hex-character directories. A plain FILE sitting where a bucket
    # directory belongs would make an insert into that bucket fail - so the
    # shape of this listing is evidence, not decoration.
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

# --- Hypothesis A: is the directory writable AT ALL, the way sccache uses it? -
# sccache's disk cache stores objects under two nested hex directories and
# writes via a temp file that is then renamed into place. Each step is tested
# separately so the failing one is named, not guessed at.
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

# The rename step is the interesting one on Windows containers: a rename that
# crosses a wcifs layer boundary can fail where a plain write succeeds (this
# host has a known layer-rename quirk, cf. Test-LayerRename.ps1).
$tmpFile = Join-Path $probeRoot 'staged.tmp'
$renamed = Join-Path $nested 'renamed.bin'
try {
    [IO.File]::WriteAllBytes($tmpFile, [byte[]](1..64))
    [IO.File]::Move($tmpFile, $renamed)
    Write-Result 'rename temp -> cache path' $true $renamed
} catch {
    Write-Result 'rename temp -> cache path' $false $_.Exception.Message
}

# Same again but staging from %TEMP%, which is where sccache would put its
# temp file if it does NOT stage inside the cache dir. If THIS one fails while
# the in-cache-dir rename above succeeds, the temp directory is the fault.
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

# --- The distinction the earlier raw tests missed: NEW path vs EXISTING path --
# Every raw test above creates its OWN directories (`probe-tmp\a1\b2`) and they
# all pass, while sccache writes into the PRE-EXISTING bucket tree that came in
# with the mount (`8\a\c\<hash>`). That difference was invisible for days.
#
# It also explains the one result that never made sense: the failure disappears
# for the rest of a container's life after every bucket is moved off the mount
# and back (which materialises the whole tree locally), and returns in the next
# fresh container. If writing into an inherited deep path fails HERE, with no
# sccache in the picture at all, then this is a mount/filesystem defect and not
# an sccache bug - and it is reportable as such.
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

# --- Who can write into the cache mount: this process, or also children? -----
# The raw tests above pass IN THIS PROCESS while sccache's server fails against
# the same directory. The server is a DETACHED process, so the question is
# whether spawned children lose access to the BuildKit cache mount. Three spawn
# shapes, from most attached to fully detached, against BOTH the mount and a
# plain directory as the control - a child that fails on both is simply broken
# and says nothing about the mount.
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
            # Closest shape to `sccache --start-server`: no window, no console,
            # parent does not wait on a job object it owns.
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

# --- Hypothesis B: WHICH sccache configuration breaks the write? -------------
# The raw tests above proved C:\sccache is writable, so the fault is in
# sccache's own write path. This matrix isolates WHICH part by varying one
# factor at a time and compiling a genuinely unique file under each:
#
#   disk-only            no remote, no chain      -> is the plain disk cache OK?
#   multilevel-mounted   disk,webdav on the mount -> the real build's config
#   multilevel-plaindir  disk,webdav on a normal  -> does the cache MOUNT matter,
#                        container directory         or is the chain broken
#                                                    wherever it points?
#   webdav-only          remote, no chain         -> is the remote itself fine?
#
# Reading the result: if disk-only and webdav-only both write cleanly while the
# two multilevel rows fail, the defect is in sccache's multilevel layer and is
# an upstream bug with a minimal repro, not a misconfiguration here.
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

    # The server reads its configuration ONCE, at start. So every variant must
    # stop the previous server first, or it silently measures the old config -
    # the same trap that made SCCACHE_ERROR_LOG look broken for four builds.
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

    # Truncate the error log per variant, so the dump below belongs to THIS
    # variant and not to the previous one (server is stopped, handle is free).
    if ($env:SCCACHE_ERROR_LOG) {
        Set-Content -Path $env:SCCACHE_ERROR_LOG -Value $null -Force -ErrorAction SilentlyContinue
    }

    # A unique body per variant: an identical source is a cache HIT and attempts
    # no write at all - the trap that made two stages of this investigation
    # worthless (onnx 0 misses -> 0 writes -> a meaningless "0 errors").
    #
    # The uniqueness must survive PREPROCESSING: sccache hashes the preprocessor
    # output, so a unique value in a // comment changes nothing. The first cut of
    # this probe did exactly that and every variant produced the identical hash
    # key 8acec69b..., which turned the webdav-only row into a cache hit that
    # measured nothing. Put the token in real code instead.
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
        # /Fo with NO colon after it: `/Fo:C:\x.obj` makes sccache build the
        # bogus path `C:\:C:\x.obj` and fail with "failed to zip up compiler
        # outputs", which looks like a cache bug and is not one (2026-08-14).
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

    # Stop the server so its log FLUSHES (SCCACHE_IDLE_TIMEOUT=0 means it never
    # exits on its own and the buffered tail dies with the RUN), then print the
    # storage lines for THIS variant. This is where a failing variant names the
    # path it could not write - the whole reason for running at debug level.
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

# CONFOUND, caught 2026-08-15 after the first matrix "proved" the mount guilty:
# `multilevel-plaindir` changed TWO things at once - off the cache mount AND
# into an EMPTY directory - while C:\sccache carries 114 MiB plus two foreign
# entries in its root (a `logs` dir left over from before #90 moved the error
# log out, and a stray `wtest.txt`). A two-variable comparison cannot name a
# cause. These two rows split it apart:
#   disk-mounted-subdir : EMPTY dir, still ON the mount  -> isolates the mount
#   disk-plaindir       : same single-level config, off the mount (control)
# PERSISTENT on purpose (not deleted at the end). The open question for the
# "just point SCCACHE_DIR at a fresh directory" fix is whether a subdir that
# WORKS while empty still works once a LATER container inherits the objects this
# one wrote. Keeping it across runs answers that: run the probe twice and read
# this row both times. Deleting it, as the first version did, made every run
# test a fresh empty dir and could never have shown the regression.
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

# Restore, so the error-log dump below reflects the REAL build configuration.
$env:SCCACHE_MULTILEVEL_CHAIN = $origChain
$env:SCCACHE_WEBDAV_ENDPOINT = $origEndpoint
$env:SCCACHE_DIR = $origDir

Write-Section 'MATRIX VERDICT'
foreach ($r in $results) {
    Write-Host ("  {0,-22} write errors = {1}" -f $r.Name, $r.WriteErrors)
}
$byName = @{}
foreach ($r in $results) { $byName[$r.Name] = $r.WriteErrors }
# The one comparison that separates "the cache MOUNT is broken" from "the
# EXISTING cache content is broken": same single-level config, both empty
# targets, one on the mount and one off it.
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

# --- Narrow it: is it the FOREIGN entries in the cache root? ------------------
# The matrix says an empty dir on the mount writes fine while the populated root
# does not, so something IN C:\sccache breaks inserts. A valid sccache disk
# cache root holds only the 16 single-hex-character buckets (plus `preprocessor`
# when the preprocessor cache is on). Everything else is debris - and here the
# debris is OURS: `logs` is where the error log lived before #90 moved it out,
# and `wtest.txt` is the residue of an old write test.
#
# This MOVES the foreign entries off the mount (into a container-local dir that
# dies with the RUN, so they do not come back), then re-runs the failing variant
# unchanged. If the write succeeds afterwards, the cause is named and fixed in
# one step. Sizes are printed BEFORE the move: never discard evidence silently.
Write-Section 'narrowing: quarantine foreign entries in the cache root'

$quarantine = 'C:\sccache-quarantine'
$null = New-Item -ItemType Directory -Force -Path $quarantine -ErrorAction SilentlyContinue

# `bulk-inherit` / `probe-persist` are THIS PROBE's own state, deliberately left
# on the mount so the NEXT run inherits it. Excluding them is not cosmetic: the
# first inheritance experiment reported "0 files inherited" and looked like the
# mount had lost 250 objects, when in fact this very sweep had classified the
# directory as debris and moved it off the mount minutes earlier — the probe
# destroyed its own experiment and produced a spectacular false conclusion.
$probeOwned = @('preprocessor', 'bulk-inherit', 'probe-persist')
$foreign = @(Get-ChildItem $origDir -Force -ErrorAction SilentlyContinue | Where-Object {
        -not ($_.PSIsContainer -and $_.Name -match '^[0-9a-f]$') -and $probeOwned -notcontains $_.Name
    })
# The bisect below must run whenever disk-only failed, NOT only when foreign
# entries happen to exist: an earlier probe already moved `logs`/`wtest.txt` off
# the mount for good, so on the next run this list is empty and gating the whole
# narrowing on it silently skipped the search entirely.
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
        # --- Bisect what is left: `preprocessor`, then the 16 hash buckets ----
        # Each step moves content OFF the mount and re-runs the same failing
        # variant, so exactly one thing changes per measurement. Everything is
        # moved BACK at the end (the quarantine dir is container-local and would
        # otherwise take 114 MiB of real cache with it when the RUN ends).
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
            # Leave it OFF for the repeat/concurrency sections below. The first
            # cut restored it before those ran, so they measured the broken state
            # again (5/6 and 6/6 failures) and buried the finding one line above.
            # Keeping it out also lets sccache build a FRESH preprocessor cache
            # during the repeats, which answers the follow-up question in the same
            # run: is the DIRECTORY's content stale, or is the FEATURE the problem?
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
                # The search above narrows by ELIMINATION - every half it tested
                # came back clean, so the last suspect was never itself shown to
                # fail. Restore it alone and reproduce, or this is an inference,
                # not a finding.
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
                    # A valid bucket contains only further single-hex dirs. A file
                    # at this level, or a zero-byte object deeper down, is the kind
                    # of thing that makes an insert resolve a path that is not there.
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

# --- Is the failure even deterministic? --------------------------------------
# The bisect ended in a contradiction: `disk-only` failed against the populated
# root at the START of the run, yet the very same root (all 16 buckets restored)
# wrote CLEANLY at the end. Two readings, and one measurement separates them:
#
#   a) the move-out/move-in cycle repaired whatever was stale -> now 0/N fail
#   b) the failure is PATH-DEPENDENT - each variant compiles a unique source, so
#      it lands in a different `<h0>\<h1>\<h2>` subpath, and only some are bad
#      -> roughly a constant fraction of N fails
#
# A single compile cannot tell these apart, which is exactly how a one-shot
# probe produced a confident wrong answer twice in this investigation already.
Write-Section 'determinism: N unique compiles against the populated root'

$env:SCCACHE_MULTILEVEL_CHAIN = $origChain
$env:SCCACHE_WEBDAV_ENDPOINT = $origEndpoint
$env:SCCACHE_DIR = $origDir
# BOTH configurations, because the first cut of this section repeated ONLY
# `disk-only` and reported "10/10 clean, repaired" — while the real build, which
# uses the CHAIN, went on failing 157/157 in the very next run. The chain is the
# configuration that matters; measuring the other one and generalising is the
# same mistake this investigation has now made three times.
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

# --- The last untested variable: CONCURRENCY ---------------------------------
# Every measurement so far compiled ONE file at a time, and every one of them
# passed once the tree was rewritten - while the real build, running `ninja
# -j19`, still fails 100 % of its writes (opencv 1/1, genai 157/157) minutes
# after the probe reported 12/12 clean against the same mount. Serial-vs-parallel
# is the difference the probe never reproduced.
#
# Caveat worth stating: a race would normally fail SOME writes, not all of them,
# so this hypothesis does not fully fit either. Measure it rather than argue it.
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

# --- Path LENGTH: the difference the probe never imitated ---------------------
# A fresh SCCACHE_DIR (`C:\sccache\v2`) writes cleanly in every probe and STILL
# fails 1/1 in the build, so the cache directory is not the variable - the probe
# itself is. One thing it has never reproduced: the build compiles from paths
# like
#   C:\temp\onnx-genai-src\build\Windows-ClangCL\Release\CMakeFiles\onnxruntime-genai-obj.dir\src\engine\decoders\...
# while the probe compiles from a ~70-character temp dir. `os error 3`
# (ERROR_PATH_NOT_FOUND) is exactly what Windows returns when a path exceeds
# MAX_PATH without long-path support - the same code, from a completely
# different cause than any directory-state theory.
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

# --- THE DECISIVE ONE: is it the BUILDKIT CACHE MOUNT? -----------------------
# Two full builds established that sccache's local disk cache loses writes once
# its directory holds content — 1849 of 1862 in opencv, with AND without the
# multi-level chain, at 63 MiB against a 15 GiB limit. Every single-write probe
# so far was too small to see it: the effect only appears after enough objects
# have gone in, which is why one compile against a fresh dir always looked fine.
#
# This writes N objects into a FRESH directory ON the cache mount and into a
# FRESH directory OFF it (plain container filesystem), same sccache, same
# config, back to back. BuildKit's WCOW cache-mount support is new (moby/buildkit
# #5603 / PR #5708, shipped v0.21.0; race fixed in PR #5885; "cache mounts fail
# silently" is #1648) so "the mount cannot take sustained writes" is a live
# hypothesis — and this is the first probe section big enough to test it.
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
            # Unique in REAL CODE — a unique // comment is stripped by the
            # preprocessor and every TU would collide on one hash key.
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

# STABLE names, deliberately NOT deleted at the end. N=250 into a dir this same
# container just created writes cleanly — measured — so writing volume is not the
# trigger. What the build does and the probe never did is INHERIT a populated
# directory across the container boundary: opencv's RUN opens a cache dir that a
# PREVIOUS RUN filled, and fails 99 %; onnx fills its own and mostly succeeds.
# Keeping these dirs makes the SECOND probe run the actual experiment — it starts
# with whatever the first run left behind. Run the probe twice and compare.
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
# NOT deleted: the next run must inherit them. `C:\bulk-plain-inherit` dies with
# the container anyway, which is itself the control — only the mounted one can
# carry state across the boundary.
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

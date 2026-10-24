#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Replays one real ONNX Runtime CUDA TU bare and sccache-wrapped and diffs the symbol tables.
.DESCRIPTION
    Synthetic probes never reproduced the dropped-instantiation miscompile, so this uses the TU's exact ninja command.
    A MISSING list is the miscompile, pinned to one command anyone can replay.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-ort',
    # Dockerfile.probe declares ARG ORT_REF, so a -BuildArg override arrives as $env:ORT_REF.
    [string]$OrtRef = $(if ($env:ORT_REF) { $env:ORT_REF } else { 'v1.28.0' }),
    [string]$Tu = 'bias_softmax_impl.cu',
    # Override to test a locally built sccache (patch-verify probe).
    [string]$SccacheExe = '',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== ONNX TU replay probe ($Tu @ $OrtRef) nonce=$Nonce ==="

Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

function Get-ReplayFileMatchCount {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Pattern,
        [switch]$SimpleMatch, [Management.Automation.ActionPreference]$ReadErrorAction = 'SilentlyContinue')
    $total = Select-String -Path $Path -Pattern $Pattern -SimpleMatch:$SimpleMatch -AllMatches -ErrorAction $ReadErrorAction |
        ForEach-Object {
            if ($SimpleMatch) { [regex]::Matches($_.Line, [regex]::Escape($Pattern), [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count }
            else { $_.Matches.Count }
        } | Measure-Object -Sum
    if ($null -eq $total) { return 0 }
    return [int]$total.Sum
}

function Write-ReplayDifference {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reference,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Difference,
        [Parameter(Mandatory)][string]$OnlyReferenceLabel, [Parameter(Mandatory)][string]$OnlyDifferenceLabel)
    Compare-Object $Reference $Difference | ForEach-Object {
        $tag = if ($_.SideIndicator -eq '<=') { $OnlyReferenceLabel } else { $OnlyDifferenceLabel }
        Write-Host ("  {0}: {1}" -f $tag, $_.InputObject)
    }
}

function Write-ReplayTokenDifference {
    param([string]$HeaderFormat, [object[]]$Plan, [object[]]$Executed,
        [string]$OnlyPlanLabel, [string]$OnlyExecutedLabel)
    Write-Host ($HeaderFormat -f $Plan.Count, $Executed.Count)
    Write-ReplayDifference -Reference $Plan -Difference $Executed -OnlyReferenceLabel $OnlyPlanLabel -OnlyDifferenceLabel $OnlyExecutedLabel
}

function Get-ReplayStepFacts {
    param([Parameter(Mandatory)][string]$Line, [Parameter(Mandatory)][Collections.IDictionary]$Rules,
        [Parameter(Mandatory)][string]$DefaultKind, [Parameter(Mandatory)][string]$DefinePattern)
    $kind = $DefaultKind
    foreach ($rule in $Rules.GetEnumerator()) {
        if ($Line -match $rule.Key) { $kind = $rule.Value; break }
    }
    return [pscustomobject]@{ Kind = $kind; Defines = [regex]::Matches($Line, $DefinePattern).Count }
}

function Get-ReplayStepRecord {
    param([object[]]$Lines, [string]$Pattern, [Collections.IDictionary]$Rules, [string]$DefaultKind, [string]$DefinePattern)
    $Lines | Select-String -Pattern $Pattern | ForEach-Object {
        $facts = Get-ReplayStepFacts -Line $_.Line -Rules $Rules -DefaultKind $DefaultKind -DefinePattern $DefinePattern
        [pscustomobject]@{ Line = $_.Line; Kind = $facts.Kind; Defines = $facts.Defines }
    }
}

function Write-ReplayStepRows {
    param([object[]]$Lines, [string]$Pattern, [Collections.IDictionary]$Rules, [string]$DefaultKind,
        [string]$DefinePattern, [ValidateSet('plan', 'exec', 'xform')][string]$Style)
    Get-ReplayStepRecord -Lines $Lines -Pattern $Pattern -Rules $Rules -DefaultKind $DefaultKind -DefinePattern $DefinePattern |
        ForEach-Object {
            $row = $_
            switch ($Style) {
                plan { Write-Host ("plan  {0,-11} -D count={1,3}  USE_CUDA={2}" -f $row.Kind, $row.Defines, ($row.Line -match 'DUSE_CUDA')) }
                exec { Write-Host ("exec  {0,-11} -D count={1,3}  USE_CUDA={2}" -f $row.Kind, $row.Defines, ($row.Line -match 'USE_CUDA')) }
                xform { Write-Host ("xform {0,-9} -D={1,-3} DOUBLE_MATH={2} CUDACC={3} len={4}" -f $row.Kind, $row.Defines, ($row.Line -match 'CUDA_DOUBLE_MATH'), ($row.Line -match '__CUDACC__'), $row.Line.Length) }
            }
        }
}

function Format-ReplayTrace {
    param([object[]]$Lines, [string]$Prefix, [int]$Limit)
    $Lines | Select-String 'cicc|ptxas|cudafe|fatbinary' | Select-Object -First $Limit | ForEach-Object {
        $line = $_.Line.Trim()
        "$Prefix| $($line.Substring(0, [Math]::Min(300, $line.Length)))"
    }
}

function Measure-ReplayIntermediate {
    param([Parameter(Mandatory)][string]$BareDirectory, [Parameter(Mandatory)][string]$WrappedDirectory,
        [Parameter(Mandatory)][string[]]$Patterns, [switch]$SimpleMatch, [switch]$Sort)
    foreach ($pair in @(@('bare', $BareDirectory), @('wrap', $WrappedDirectory))) {
        $files = @(Get-ChildItem $pair[1] -File -ErrorAction SilentlyContinue)
        if ($Sort) { $files = @($files | Sort-Object Name) }
        foreach ($file in $files) {
            $counts = @(foreach ($pattern in $Patterns) {
                Get-ReplayFileMatchCount -Path $file.FullName -Pattern $pattern -SimpleMatch:$SimpleMatch
            })
            [pscustomobject]@{ Side = $pair[0]; File = $file; Counts = $counts }
        }
    }
}

function Get-ReplaySymbols {
    param([Parameter(Mandatory)][string]$Path)
    (& llvm-nm --defined-only $Path 2>$null) -replace '^\S+\s+\S+\s+', '' | Sort-Object -Unique
}

function Write-Chunked([string]$Prefix, [string]$Line, [int]$Limit = 0) {
    if (-not $Line) { Write-Host "$Prefix <absent>"; return }
    $length = if ($Limit -gt 0) { [Math]::Min($Line.Length, $Limit) } else { $Line.Length }
    for ($i = 0; $i -lt $length; $i += 230) {
        Write-Host ("{0} {1}" -f $Prefix, $Line.Substring($i, [Math]::Min(230, $length - $i)))
    }
}

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir

# 1. Source
if (-not (Test-Path 'ort\.git')) {
    & git clone --depth 1 --branch $OrtRef --recurse-submodules --shallow-submodules `
        https://github.com/microsoft/onnxruntime.git ort 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "clone failed ($LASTEXITCODE)" }
}

# 2. Configure without any launcher, to get the raw command
$cuda = $env:CUDA_PATH
$build = Join-Path $WorkDir 'build'
& cmake -S ort\cmake -B $build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl `
    -DCMAKE_LINKER=lld-link "-DCMAKE_AR=llvm-lib" `
    -Donnxruntime_BUILD_SHARED_LIB=ON -Donnxruntime_BUILD_UNIT_TESTS=OFF `
    -Dprotobuf_MSVC_STATIC_RUNTIME=OFF `
    -Donnxruntime_USE_CUDA=ON `
    "-DCMAKE_CUDA_COMPILER:FILEPATH=$cuda\bin\nvcc.exe" `
    "-DCMAKE_CUDA_ARCHITECTURES=80-real;86-real;89-real;90-real" `
    -DCMAKE_CUDA_STANDARD:STRING=17 `
    "-DCMAKE_CUDA_FLAGS:STRING=-Xcompiler=/wd4067 -Xcompiler=/Zc:preprocessor --compiler-options /Zc:preprocessor -DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING" `
    "-DCUDNN_ROOT=$env:CUDNN_ROOT" "-Donnxruntime_CUDNN_HOME=$env:CUDNN_ROOT" `
    "-Donnxruntime_CUDA_HOME=$cuda" `
    2>&1 | Select-Object -Last 8 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }

# 3. The TU's exact command
Set-Location $build
$objLine = & ninja -t targets all 2>$null | Select-String -SimpleMatch $Tu | Select-String 'providers_cuda' | Select-Object -First 1
if (-not $objLine) { throw "TU $Tu not found in ninja targets" }
$obj = ($objLine.Line -split ':')[0].Trim()
Write-Host "target: $obj"
$cmd = (& ninja -t commands $obj | Select-String -SimpleMatch $Tu | Select-Object -Last 1).Line
if (-not $cmd) { throw "no command for $obj" }
Write-Host "command: $($cmd.Substring(0, [Math]::Min(500, $cmd.Length))) ..."
Set-Content -Path replay-cmd.txt -Value $cmd

# ninja emits `cmd /S /C "<real command>"`- strip that wrapper if present.
if ($cmd -match '^\s*C?:?.*cmd(\.exe)? /S /C "(.*)"\s*$') { $cmd = $Matches[2] }

# 4. Bare vs wrapped
& cmd.exe /S /C "$cmd" 2>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "bare compile failed ($LASTEXITCODE)" }
Copy-Item $obj "$WorkDir\bare.obj" -Force

$sccache = if ($SccacheExe) { $SccacheExe } else { "$env:USERPROFILE\.cargo\bin\sccache.exe" }
Write-Host "sccache under test: $sccache"
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'sccache-debug.log'
$env:SCCACHE_LOG = 'debug'
$env:SCCACHE_SERVER_PORT = '4236'
& $sccache --stop-server 2>&1 | Out-Null
& $sccache --start-server 2>&1 | Out-Null
Remove-Item $obj -Force
& cmd.exe /S /C "`"$sccache`" $cmd" 2>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
$wrappedExit = $LASTEXITCODE
& $sccache --show-stats 2>&1 | Select-String 'Compile requests|Cache hits |Cache misses ' | ForEach-Object { "$_" }
& $sccache --stop-server 2>&1 | Out-Null
if ($wrappedExit -ne 0) { throw "wrapped compile failed ($wrappedExit)" }
Copy-Item $obj "$WorkDir\wrapped.obj" -Force

# 5. Verdict
$bareSyms = Get-ReplaySymbols -Path "$WorkDir\bare.obj"
$wrapSyms = Get-ReplaySymbols -Path "$WorkDir\wrapped.obj"
$missing = @(Compare-Object $bareSyms $wrapSyms | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject |
    # ??_C@ string literals embed cudafe's randomized module id, so only code/data symbols count as a miss.
    Where-Object { $_ -notmatch '^\?\?_C@' })
Write-Host ("bare symbols: {0}  wrapped symbols: {1}" -f $bareSyms.Count, $wrapSyms.Count)
if ($missing.Count -gt 0) {
    Write-Host "[FAIL] wrapped object MISSING $($missing.Count) symbol(s):"
    $missing | Select-Object -First 40 | ForEach-Object { Write-Host "  MISSING: $_" }
} else {
    Write-Host '[ OK ] wrapped object contains every bare-object symbol (this TU does not reproduce)'
}
# 6b. Host-step define diff, plan vs sccache: arch defines there guard the dropped double code paths.
Set-Location $build
$planLines = & cmd.exe /S /C "$cmd --dryrun" 2>&1
function Write-ReplayHostDifference {
    param([object[]]$PlanLines)
$planHost = ($planLines | Select-String 'cl\.exe' | Select-Object -Last 1).Line
$planTokens = @([regex]::Matches($planHost, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
$execLine = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'bias_softmax_impl\.cu\.obj\]: get_cached_or_compile' | Select-Object -Last 1).Line
$execTokens = @([regex]::Matches($execLine, '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
$planD = @($planTokens | Where-Object { $_ -match '^[-/](D|FI|I)' } | Sort-Object -Unique)
$execD = @($execTokens | Where-Object { $_ -match '^[-/](D|FI|I)' } | Sort-Object -Unique)
Write-ReplayTokenDifference -HeaderFormat 'plan host-step -D/-FI/-I tokens: {0}; sccache host-step: {1}' `
    -Plan $planD -Executed $execD -OnlyPlanLabel 'ONLY-IN-PLAN' -OnlyExecutedLabel 'ONLY-IN-EXEC'
}

# 6e. Preprocess define delta: sccache preprocesses cudafe++'s input itself, so its define set picks the #ifdef branches.
function Write-ReplayPreprocessorDifference {
    param([object[]]$PlanLines)
$planPPLine = ($planLines | Select-String ' -E |\-EP |/EP ' | Select-Object -Last 1).Line
$execPPLine = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'preprocess' | Select-Object -First 1).Line
if ($planPPLine -and $execPPLine) {
    $planDefs = @([regex]::Matches($planPPLine, '-D\s*"?([^"\s]+)"?') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    $execDefs = @([regex]::Matches($execPPLine, '\\?"-D"?,?\s*\\?"([^"\\]+)\\?"|"-D([^"]+)"') | ForEach-Object { if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value } }) | Sort-Object -Unique
    if ($execDefs.Count -eq 0) {
        # Rust Debug vector form: "...", "-DFOO", ... - fall back to plain -D capture
        $execDefs = @([regex]::Matches($execPPLine, '-D([^"\\]+)') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    Write-ReplayTokenDifference -HeaderFormat 'define delta: plan={0} exec={1}' -Plan $planDefs -Executed $execDefs `
        -OnlyPlanLabel 'LOST-BY-SCCACHE' -OnlyExecutedLabel 'ADDED-BY-SCCACHE'
} else {
    Write-Host ("define delta: line capture failed (plan={0} exec={1})" -f [bool]$planPPLine, [bool]$execPPLine)
}
}

# 6d. Full raw lines, chunked: the per-side regex counts below can look contradictory.
function Write-ReplayRawStepLines {
    param([string]$Cmd, [object[]]$PlanLines)
Write-Host ("truth: original command carries -DUSE_CUDA: " + [bool]($cmd -match '[-/]DUSE_CUDA'))
$planPP = ($planLines | Select-String ' -E |\-EP |/EP ' | Select-Object -First 1).Line
Write-Chunked 'planPP|' $planPP
$planFE = ($planLines | Select-String 'cudafe\+\+' | Select-Object -First 1).Line
Write-Chunked 'planFE|' $planFE
$execPP = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'msvc\] preprocess' | Select-Object -First 1).Line
Write-Chunked 'execPP|' $execPP
$execFE = (Get-Content $env:SCCACHE_ERROR_LOG | Select-String 'module_id\]: get_cached_or_compile' | Select-Object -First 1).Line
Write-Chunked 'execFE|' $execFE
}

# 6c. Per-step USE_CUDA: the dropped instantiation sits behind #ifdef USE_CUDA, so find the first step that loses it.
function Write-ReplayStepAccounting {
    param([object[]]$PlanLines)
Write-Host '--- per-step USE_CUDA accounting (plan) ---'
Write-ReplayStepRows -Lines $planLines -Pattern 'cudafe|cicc|cl\.exe.*-E|cl\.exe.*/E|cl\.exe' `
    -Rules ([ordered]@{ 'cudafe\+\+' = 'cudafe++'; 'cicc' = 'cicc'; '-EP|/EP|-E |/E ' = 'preprocess' }) -DefaultKind host-cl -DefinePattern '[-/]D' -Style plan
Write-Host '--- per-step USE_CUDA accounting (sccache executed) ---'
Write-ReplayStepRows -Lines (Get-Content $env:SCCACHE_ERROR_LOG) -Pattern 'get_cached_or_compile|msvc\] preprocess|creating.*command' `
    -Rules ([ordered]@{ 'module_id' = 'cudafe++'; 'compute_\d+\.ptx' = 'cicc'; 'preprocess' = 'preprocess'; '\.cu\.obj' = 'host-cl' }) -DefaultKind other -DefinePattern '"-D|\\"-D|[-/]D' -Style exec
}

# 6. nvcc's plan vs sccache's executed steps, on stdout since the container fs dies with the RUN.
function Write-ReplayStepAnalysis {
    param([string]$Build, [string]$Cmd, [object[]]$PlanLines)
Write-ReplayHostDifference -PlanLines $PlanLines
Write-ReplayPreprocessorDifference -PlanLines $PlanLines
Write-ReplayRawStepLines -Cmd $Cmd -PlanLines $PlanLines
Write-ReplayStepAccounting -PlanLines $PlanLines
Set-Location $build
Format-ReplayTrace -Lines @(& cmd.exe /S /C "$cmd --dryrun" 2>&1) -Prefix plan -Limit 40
if (Test-Path $env:SCCACHE_ERROR_LOG) {
    Format-ReplayTrace -Lines (Get-Content $env:SCCACHE_ERROR_LOG) -Prefix exec -Limit 120
}
}
Write-ReplayStepAnalysis -Build $build -Cmd $cmd -PlanLines $planLines

# 7. Both flows keep their intermediates; the first wrapped file with fewer Iddd markers than bare is the broken step.
$keepBare = Join-Path $WorkDir 'keep-bare'
$keepWrap = Join-Path $WorkDir 'keep-wrap'
$null = New-Item -ItemType Directory -Force -Path $keepBare, $keepWrap
Set-Location $build
Remove-Item $obj -Force -ErrorAction SilentlyContinue
& cmd.exe /S /C "$cmd --keep --keep-dir `"$keepBare`"" 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "bare --keep compile failed ($LASTEXITCODE)" }

# Fresh cache dir: the wrapped run must MISS, or the sub-steps never execute.
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache-keep'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'sccache-keep.log'
$env:SCCACHE_LOG = 'trace'
& $sccache --start-server 2>&1 | Out-Null
Remove-Item $obj -Force -ErrorAction SilentlyContinue
& cmd.exe /S /C "`"$sccache`" $cmd --keep --keep-dir `"$keepWrap`"" 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" }
$keepExit = $LASTEXITCODE
& $sccache --stop-server 2>&1 | Out-Null
if ($keepExit -ne 0) { throw "wrapped --keep compile failed ($keepExit)" }

function Write-ReplayIntermediateCounts {
    param([string]$KeepBare, [string]$KeepWrap)
Measure-ReplayIntermediate -BareDirectory $keepBare -WrappedDirectory $keepWrap -Patterns @('BiasSoftmaxWarpForwardIddd', 'BiasSoftmaxWarpForwardIfff') | ForEach-Object {
    if ($_.Counts[0] -or $_.Counts[1]) {
        Write-Host ("stub-count {0,-4} {1,-40} ddd={2,-5} fff={3}" -f $_.Side, $_.File.Name, $_.Counts[0], $_.Counts[1])
    }
}

Measure-ReplayIntermediate -BareDirectory $keepBare -WrappedDirectory $keepWrap -Patterns @('BiasSoftmaxImpl<double', 'BiasSoftmaxImpl<float') -SimpleMatch -Sort | ForEach-Object {
    Write-Host ("ii-scan {0,-4} {1,-44} {2,10:N0} B  dbl={3,-4} flt={4}" -f $_.Side, $_.File.Name, $_.File.Length, $_.Counts[0], $_.Counts[1])
}
}

function Write-ReplayKeepDefinePresence {
    param([string]$KeepLog)
if (Test-Path $keepLog) {
    foreach ($needle in @('CUDA_DOUBLE_MATH_FUNCTIONS', '__CUDACC__', '__CUDACC_VER_MAJOR__')) {
        $n = Get-ReplayFileMatchCount -Path $keepLog -Pattern $needle -SimpleMatch -ReadErrorAction Stop
        Write-Host ("define-presence in sccache debug log: {0} = {1}" -f $needle, [int]$n)
    }
}
}

# 9. The transformed commands sccache executed (trace level)
function Write-ReplayTransformedCommands {
    param([string]$KeepLog)
if (Test-Path $keepLog) {
    Write-ReplayStepRows -Lines (Get-Content $keepLog) -Pattern 'transformed nvcc command' `
        -Rules ([ordered]@{ 'cudafe' = 'cudafe++'; 'cicc' = 'cicc'; 'ptxas' = 'ptxas'; 'fatbinary' = 'fatbin'; 'cl\.exe|cl ' = 'cl' }) -DefaultKind '?' -DefinePattern '-D' -Style xform
    $clLine = (Get-Content $keepLog | Select-String 'transformed nvcc command' | Where-Object { $_.Line -match 'cpp1\.ii|cpp4\.ii' } | Select-Object -First 1).Line
    if ($clLine) { Write-Chunked -Prefix 'xformPP|' -Line $clLine -Limit 4600 }
}
}

# 10. cpp4.ii scan with loose regexes, since preprocessed spacing defeats a literal match.
function Write-ReplayCpp4Scan {
    param([string]$KeepBare, [string]$KeepWrap)
foreach ($pair in @(@('bare', $keepBare), @('wrap', $keepWrap))) {
    $side = $pair[0]
    $f = Join-Path $pair[1] 'bias_softmax_impl.cpp4.ii'
    if (-not (Test-Path $f)) { Write-Host "cpp4-scan $side <missing>"; continue }
    $txt = [System.IO.File]::ReadAllText($f)
    foreach ($pat in @('BiasSoftmaxImpl\s*<\s*double', 'BiasSoftmaxImpl\s*<\s*float', '__dadd_rn', 'BiasSoftmaxWarpForward')) {
        Write-Host ("cpp4-scan {0,-4} {1,-38} = {2}" -f $side, $pat, [regex]::Matches($txt, $pat).Count)
    }
}
}

# 11. Replays nvcc.rs's backslash-to-slash rewrite before shlex, which collapses the quotes at the first string define.
function Write-ReplayShlexProbe {
    param([object[]]$PlanLines)
$cpp4Plan = ($planLines | Select-String 'cpp4\.ii' | Select-Object -First 1).Line
if ($cpp4Plan) {
    $mangled = $cpp4Plan.Replace('""', '"')
    $mangled = $mangled.Replace('\\?\', '')
    $mangled = $mangled.Replace('\', '/').Replace(' -E ', ' -P ').Replace(' > ', ' -Fi')
    Set-Content -Path mangled-cpp4.txt -Value $mangled -Encoding utf8
    $py = 'C:/temp/cpython/PCbuild/amd64/python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py -c @"
import shlex, io
line = io.open('mangled-cpp4.txt', encoding='utf-8-sig').read().strip()
line = line[3:] if line.startswith('#$ ') else line
try:
    toks = shlex.split(line)
except ValueError as e:
    print('shlex FAILED:', e); toks = []
print('token count:', len(toks))
hits = [(i, t) for i, t in enumerate(toks) if 'USE_CUDA' in t or 'FILE_NAME' in t or 'VER_STRING' in t]
for i, t in hits: print(f'tok[{i}] len={len(t)}: {t[:160]}')
big = max(toks, key=len, default='')
print('longest token len:', len(big)); print('longest token head:', big[:220])
"@
}
}

function Write-ReplayKeepAnalysis {
    param([string]$WorkDir, [string]$KeepBare, [string]$KeepWrap, [object[]]$PlanLines)
    $keepLog = Join-Path $WorkDir 'sccache-keep.log'
    Write-ReplayIntermediateCounts -KeepBare $KeepBare -KeepWrap $KeepWrap
    Write-ReplayKeepDefinePresence -KeepLog $keepLog
    Write-ReplayTransformedCommands -KeepLog $keepLog
    Write-ReplayCpp4Scan -KeepBare $KeepBare -KeepWrap $KeepWrap
    Write-ReplayShlexProbe -PlanLines $PlanLines
}
Write-ReplayKeepAnalysis -WorkDir $WorkDir -KeepBare $keepBare -KeepWrap $keepWrap -PlanLines $planLines

Write-Host 'probe complete'
exit 0

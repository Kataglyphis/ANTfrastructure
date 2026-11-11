#requires -Version 7.0

function New-UvChainTestObserver {
    param([scriptblock]$CommandCheck)
    $state = [pscustomobject]@{ Uv = [System.Collections.Generic.List[string]]::new(); Log = [System.Collections.Generic.List[string]]::new(); Error = ''; NoSync = '' }
    $runner = {
        param($exe, $arguments)
        $state.Uv.Add(($arguments -join ' '))
        if ($CommandCheck) { & $CommandCheck $exe $arguments }
    }.GetNewClosure()
    $log = { param($message) $state.Log.Add("$message") }.GetNewClosure()
    return [pscustomobject]@{ State = $state; CommandRunner = $runner; Log = $log }
}

Export-ModuleMember -Function New-UvChainTestObserver

function Assert-UvChainTestReplacement {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][int]$CommandCount)
    Assert-Equal '' $State.Error 'no failure'
    Assert-Equal $CommandCount $State.Uv.Count 'replacement command count'
    Assert-Equal '1' $State.NoSync 'holds uv run off the lock after replacing chain packages'
}

Export-ModuleMember -Function Assert-UvChainTestReplacement

function Assert-UvChainTestCommand {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][int]$Index,
        [string[]]$Match = @(), [string[]]$NotMatch = @(), [AllowEmptyString()][string]$Equal)
    $command = $State.Uv[$Index]
    if ($PSBoundParameters.ContainsKey('Equal')) { Assert-Equal $Equal $command }
    foreach ($pattern in $Match) { Assert-Match $pattern $command }
    foreach ($pattern in $NotMatch) { Assert-False ($command -match $pattern) "unexpected /$pattern/ in command $Index" }
}

Export-ModuleMember -Function Assert-UvChainTestCommand

function New-ChainOrtFixture {
    param([Parameter(Mandatory)][string]$Dir, [switch]$NoOrtWheel)
    $venv = Join-Path $Dir 'venv'
    New-Item -ItemType Directory -Force -Path (Join-Path $venv 'Scripts') | Out-Null
    Set-Content -LiteralPath (Join-Path $venv 'Scripts\python.exe') 'x' -Encoding ASCII
    $store = Join-Path $Dir 'store'
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $names = @('tvm-0.25.0-cp314-cp314-win_amd64.whl')
    if (-not $NoOrtWheel) {
        $names += 'onnxruntime-1.30.0-cp314-cp314-win_amd64.whl', 'onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl', 'onnxruntime_extensions-0.14.0-cp39-abi3-win_amd64.whl'
    }
    foreach ($n in $names) { Set-Content -LiteralPath (Join-Path $store $n) 'x' -Encoding ASCII }
    return [pscustomobject]@{ Venv = $venv; Store = $store }
}

Export-ModuleMember -Function New-ChainOrtFixture

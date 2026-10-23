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

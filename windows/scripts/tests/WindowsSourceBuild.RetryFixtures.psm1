#requires -Version 7.0

function Invoke-RecordedRetryFixture {
    param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][scriptblock]$ToolSetup,
        [Parameter(Mandatory)][scriptblock]$Body, [string]$Mode = '', [ValidateRange(0, 2)][int]$Failures = 0,
        [switch]$Stall, [hashtable]$Environment = @{})
    $action = $Body
    Invoke-InTestDir { param($dir)
        $null = & $ToolSetup $dir
        $fixture = [pscustomobject]@{
            Dir = $dir; Log = Join-Path $dir "$Tool.log"; Target = Join-Path $dir 'src'
            StallMarker = Join-Path $dir 'stall.marker'; Calls = @(); Result = $null
        }
        $prefix = 'WBT_' + $Tool.ToUpperInvariant()
        $vars = @{
            PATH = "$dir;$env:PATH"; "${prefix}_LOG" = $fixture.Log; "${prefix}_MODE" = $Mode
            "${prefix}_FAILONCE" = ''; "${prefix}_FAILONCE2" = ''; "${prefix}_STALLMARK" = ''
            "${prefix}_TARGET" = $fixture.Target
        }
        for ($index = 1; $index -le $Failures; $index++) {
            $marker = Join-Path $dir "fail-$index.marker"
            Set-Content -LiteralPath $marker -Value x -Encoding ASCII
            $suffix = if ($index -eq 1) { '' } else { "$index" }
            $vars["${prefix}_FAILONCE$suffix"] = $marker
        }
        if ($Stall) { $vars["${prefix}_STALLMARK"] = $fixture.StallMarker }
        foreach ($key in $Environment.Keys) { $vars[$key] = $Environment[$key] }
        Invoke-WithEnv $vars { $fixture.Result = & $action $fixture }
        $fixture.Calls = @(Get-Content -LiteralPath $fixture.Log)
        return $fixture
    }.GetNewClosure()
}

function Assert-RecordedRetryCalls {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string[]]$Pattern)
    Assert-Equal $Pattern.Count $Fixture.Calls.Count 'recorded retry attempt count'
    for ($index = 0; $index -lt $Pattern.Count; $index++) {
        Assert-Match $Pattern[$index] $Fixture.Calls[$index] "attempt $($index + 1)"
    }
}

Export-ModuleMember -Function Invoke-RecordedRetryFixture, Assert-RecordedRetryCalls

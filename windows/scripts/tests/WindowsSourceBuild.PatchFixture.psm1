#requires -Version 7.0
# File conversion fixtures check byte results and observable streams without compiling upstream projects.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.TextFixtures.psm1') -ErrorAction Stop

function Assert-SourceFileConversion {
    param([Parameter(Mandatory)][Collections.IDictionary]$Case)
    $operation = $Case.Operation
    Invoke-InTestLineDir -LineFiles $Case.Files -Body { param($dir)
        $records = @(& $operation $dir *>&1)
        $counts = @($records | Where-Object { $_ -is [int] })
        Assert-Equal 1 $counts.Count 'one scalar patch count reaches stdout'
        Assert-Equal $Case.ChangedCount $counts[0] ($Case.CountMessage ?? 'every selected import map reaches its profile operation')
        foreach ($relative in $Case.Expected.Keys) {
            Assert-Equal ($Case.Expected[$relative] + [Environment]::NewLine) ([IO.File]::ReadAllText((Join-Path $dir $relative))) `
                ($Case.ResultMessage ?? 'the conversion retains each per-file naming policy')
        }
        if ($Case.DescriptionPattern) { Assert-Match $Case.DescriptionPattern ($records -join '|') 'caller descriptions retain each relative file' }
        $warm = @(& $operation $dir *>&1)
        Assert-Equal 1 $warm.Count 'already-converted inputs remain quiet'
        Assert-Equal 0 $warm[0] 'a repeated import-map pass stays idempotent'
        if ($Case.Body) { & $Case.Body $dir $records }
    }
}

Export-ModuleMember -Function Assert-SourceFileConversion

# PSScriptAnalyzer settings for the Windows build scripts. Deliberately lenient to start:
# the goal is to catch genuinely dangerous patterns (uninitialized vars, incorrect
# comparisons, unreachable code) without drowning a large, working codebase in style
# noise. Tighten over time. Consumed by windows/scripts/Invoke-Lint.ps1.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',            # Write-Host is the intended progress channel in these build logs
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters',
        'PSReviewUnusedParameter',
        'PSUseBOMForUnicodeEncodedFile',
        # Established API surface (Write-SccacheStats, Get-MsvcToolsRoots, ...):
        # renaming exported functions for grammatical pedantry is churn across
        # scripts, tests and external consumers with zero behavior value.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSPlaceOpenBrace           = @{ Enable = $false }
        PSPlaceCloseBrace          = @{ Enable = $false }
        PSUseConsistentIndentation = @{ Enable = $false }
        PSUseConsistentWhitespace  = @{ Enable = $false }
    }
}

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
        'PSUseBOMForUnicodeEncodedFile'
    )
    Rules        = @{
        PSPlaceOpenBrace           = @{ Enable = $false }
        PSPlaceCloseBrace          = @{ Enable = $false }
        PSUseConsistentIndentation = @{ Enable = $false }
        PSUseConsistentWhitespace  = @{ Enable = $false }
    }
}

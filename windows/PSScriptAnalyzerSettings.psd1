# Deliberately lenient: catch dangerous patterns, not style noise, across a large working codebase.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',            # Write-Host is the intended progress channel in these build logs
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters',
        'PSReviewUnusedParameter',
        'PSUseBOMForUnicodeEncodedFile',
        # Renaming established exported functions (Write-SccacheStats, ...) is churn across consumers.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSPlaceOpenBrace           = @{ Enable = $false }
        PSPlaceCloseBrace          = @{ Enable = $false }
        PSUseConsistentIndentation = @{ Enable = $false }
        PSUseConsistentWhitespace  = @{ Enable = $false }
    }
}

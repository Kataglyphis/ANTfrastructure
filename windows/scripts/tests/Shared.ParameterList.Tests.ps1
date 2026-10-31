#requires -Version 7.0
# ConvertTo-ParameterList assembles CMake/docker arg lists, so a regression silently drops or mangles build flags.

Describe 'ConvertTo-ParameterList' {

    foreach ($case in @(
            @{ Name = 'returns an empty array for an empty hashtable'; Arguments = @{ Value = @{} }; Expected = @() }
            @{ Name = 'wraps a single string as a one-element array'; Arguments = @{ Value = 'solo' }; Expected = @('solo') }
            @{ Name = 'passes an all-string array through unchanged'; Arguments = @{ Value = @('a', 'b', 'c') }; Expected = @('a', 'b', 'c') }
            @{ Name = 'stringifies a mixed-type array'; Arguments = @{ Value = @('a', 2, $true) }; Expected = @('a', '2', 'True') }
            @{ Name = 'expands a hashtable: $true switch becomes a bare key'; Arguments = @{ Value = @{ Force = $true } }; Expected = @('-Force') }
            @{ Name = 'omits $false switches entirely'; Arguments = @{ Value = @{ Force = $false } }; Expected = @() }
            @{ Name = 'emits key then value for a scalar hashtable entry'; Arguments = @{ Value = @{ Name = 'build' } }; Expected = @('-Name', 'build') }
            @{ Name = 'honours a custom prefix'; Arguments = @{ Value = @{ D = 'x' }; Prefix = '/' }; Expected = @('/D', 'x') }
            @{ Name = 'repeats the key for each element of an array value'; Arguments = @{ Value = @{ Inc = @('one', 'two') } }; Expected = @('-Inc', 'one', '-Inc', 'two') }
        )) {
        It $case.Name {
            $arguments = $case.Arguments
            $r = @(ConvertTo-ParameterList @arguments)
            Assert-Equal $case.Expected.Count $r.Count
            Assert-Equal ($case.Expected -join '|') ($r -join '|')
        }
    }
}

# Tests for ConvertTo-ParameterList (WindowsScripts.Shared) — turns hashtables/arrays
# into a flat native-argument list. Used to assemble CMake/docker arg lists, so a
# regression silently drops or mangles build flags.

Describe 'ConvertTo-ParameterList' {

    It 'returns an empty array for an empty hashtable' {
        $r = @(ConvertTo-ParameterList -Value @{})
        Assert-Equal 0 $r.Count
    }

    It 'wraps a single string as a one-element array' {
        $r = @(ConvertTo-ParameterList -Value 'solo')
        Assert-Equal 1 $r.Count
        Assert-Equal 'solo' $r[0]
    }

    It 'passes an all-string array through unchanged' {
        $r = @(ConvertTo-ParameterList -Value @('a', 'b', 'c'))
        Assert-Equal 3 $r.Count
        Assert-Equal 'b' $r[1]
    }

    It 'stringifies a mixed-type array' {
        $r = @(ConvertTo-ParameterList -Value @('a', 2, $true))
        Assert-Equal 3 $r.Count
        Assert-Equal '2' $r[1]
    }

    It 'expands a hashtable: $true switch becomes a bare key' {
        $r = @(ConvertTo-ParameterList -Value @{ Force = $true })
        Assert-Equal 1 $r.Count
        Assert-Equal '-Force' $r[0]
    }

    It 'omits $false switches entirely' {
        $r = @(ConvertTo-ParameterList -Value @{ Force = $false })
        Assert-Equal 0 $r.Count
    }

    It 'emits key then value for a scalar hashtable entry' {
        $r = @(ConvertTo-ParameterList -Value @{ Name = 'build' })
        Assert-Equal 2 $r.Count
        Assert-Equal '-Name' $r[0]
        Assert-Equal 'build' $r[1]
    }

    It 'honours a custom prefix' {
        $r = @(ConvertTo-ParameterList -Value @{ D = 'x' } -Prefix '/')
        Assert-Equal '/D' $r[0]
    }

    It 'repeats the key for each element of an array value' {
        $r = @(ConvertTo-ParameterList -Value @{ Inc = @('one', 'two') })
        Assert-Equal 4 $r.Count
        Assert-Equal '-Inc' $r[0]
        Assert-Equal 'one' $r[1]
        Assert-Equal '-Inc' $r[2]
        Assert-Equal 'two' $r[3]
    }
}

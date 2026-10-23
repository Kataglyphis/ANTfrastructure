#requires -Version 7.0
# Does not cover CMake's interpretation of parsed cache values.

Describe 'Get-CmakeCacheEntries' {
    It 'keeps valid, untyped, and unusual entries while ignoring cache comments' {
        $entries = @(Get-CmakeCacheEntries -Text "# CMakeCache.txt`n//Path help`nBOOL_VALUE:BOOL=ON`nPLAIN_VALUE=two=parts`nodd key:TYPE=kept`n leading=ignored")

        Assert-Equal 3 $entries.Count 'three cache entries'
        Assert-Equal 'BOOL_VALUE|BOOL|ON' ('{0}|{1}|{2}' -f $entries[0].Name, $entries[0].Type, $entries[0].Value) 'typed value'
        Assert-Equal 'PLAIN_VALUE||two=parts' ('{0}|{1}|{2}' -f $entries[1].Name, $entries[1].Type, $entries[1].Value) 'untyped value retains equals signs'
        Assert-Equal $null $entries[2].Name 'unusual keys remain visible to raw-line consumers'
        Assert-Equal 'odd key:TYPE=kept' $entries[2].Line 'raw cache entry'
    }

    It 'preserves duplicate entries in order for callers to retain their own overwrite policy' {
        $entries = @(Get-CmakeCacheEntries -Text "SAME:STRING=first`nSAME:STRING=last")

        Assert-Equal 'first|last' (($entries | ForEach-Object Value) -join '|') 'both entries remain ordered'
    }

    It 'returns no entries for empty or comment-only cache text' {
        foreach ($text in '', "# generated`n// help`n") {
            Assert-Equal 0 @(Get-CmakeCacheEntries -Text $text).Count 'no cache values'
        }
    }
}

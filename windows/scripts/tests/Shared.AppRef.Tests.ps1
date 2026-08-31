#requires -Version 7.0
# Tests for Resolve-LatestVersionTag — the ls-remote tag filter/sort behind
# build-buildkit.ps1's -LatestApp final-stage app-ref resolution.

Describe 'Resolve-LatestVersionTag' {

    It 'picks the highest semantic version and strips refs/tags/' {
        $out = @(
            "aaa`trefs/tags/v0.0.9",
            "bbb`trefs/tags/v0.0.27",
            "ccc`trefs/tags/v0.0.10"
        )
        Assert-Equal 'v0.0.27' (Resolve-LatestVersionTag -LsRemoteOutput $out) 'numeric sort, not lexicographic (v0.0.9 < v0.0.10 < v0.0.27)'
    }

    It 'ignores dereference markers and non-version tags' {
        $out = @(
            "aaa`trefs/tags/v1.2.3",
            "aab`trefs/tags/v1.2.3^{}",
            "bbb`trefs/tags/nightly-2026-01-01",
            "ccc`trefs/tags/release-candidate",
            "ddd`trefs/tags/v1.10.0"
        )
        Assert-Equal 'v1.10.0' (Resolve-LatestVersionTag -LsRemoteOutput $out) 'only plain v?N(.N)* tags compete'
    }

    It 'accepts tags without the v prefix' {
        $out = @(
            "aaa`trefs/tags/2.0",
            "bbb`trefs/tags/v1.9.9"
        )
        Assert-Equal '2.0' (Resolve-LatestVersionTag -LsRemoteOutput $out) 'v-less tags are valid and compared numerically'
    }

    It 'returns empty for empty or version-free input (caller falls back to the pin)' {
        Assert-Equal '' (Resolve-LatestVersionTag -LsRemoteOutput @()) 'empty input'
        Assert-Equal '' (Resolve-LatestVersionTag -LsRemoteOutput $null) 'null input'
        Assert-Equal '' (Resolve-LatestVersionTag -LsRemoteOutput @("aaa`trefs/tags/not-a-version")) 'no version-shaped tags'
    }
}

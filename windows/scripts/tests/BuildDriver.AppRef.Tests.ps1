#requires -Version 7.0
# Tests for Resolve-GitRefCommit and Resolve-TorchAppRef (WindowsBuildDriver.Common.psm1):
# versions.env's APP_REF names a branch, and the torch stage builds the COMMIT it points
# at, so the layer moves exactly when the app does. Canned ls-remote text, no network.

$script:AppRefHead = '1111111111111111111111111111111111111111'
$script:AppRefTagObject = '2222222222222222222222222222222222222222'
$script:AppRefPeeled = '3333333333333333333333333333333333333333'

Describe 'Resolve-GitRefCommit' {

    It 'resolves a branch to the commit at its head' {
        $out = @("$($script:AppRefHead)`trefs/heads/develop")
        Assert-Equal $script:AppRefHead (Resolve-GitRefCommit -LsRemoteOutput $out -Ref 'develop') 'the branch head'
    }

    It 'resolves an annotated tag to the commit it peels to, not the tag object' {
        $out = @("$($script:AppRefTagObject)`trefs/tags/v1.0", "$($script:AppRefPeeled)`trefs/tags/v1.0^{}")
        Assert-Equal $script:AppRefPeeled (Resolve-GitRefCommit -LsRemoteOutput $out -Ref 'v1.0') 'a tag object is not a commit git can fetch into a tree'
    }

    It 'lets a branch win over a same-named tag' {
        $out = @("$($script:AppRefTagObject)`trefs/tags/both", "$($script:AppRefHead)`trefs/heads/both")
        Assert-Equal $script:AppRefHead (Resolve-GitRefCommit -LsRemoteOutput $out -Ref 'both') 'tracking a branch is the point of the key'
    }

    It 'returns empty, never throws, for no match or noise' {
        Assert-Equal '' (Resolve-GitRefCommit -LsRemoteOutput @("$($script:AppRefHead)`trefs/heads/main") -Ref 'develop') 'another ref'
        Assert-Equal '' (Resolve-GitRefCommit -LsRemoteOutput @('warning: redirecting', '') -Ref 'develop') 'tab-less lines'
        Assert-Equal '' (Resolve-GitRefCommit -LsRemoteOutput @() -Ref 'develop') 'empty input'
        Assert-Equal '' (Resolve-GitRefCommit -LsRemoteOutput $null -Ref 'develop') 'null input'
    }
}

Describe 'Resolve-TorchAppRef' {

    It 'builds a 40-hex APP_REF as given, without asking the remote' {
        Assert-Equal $script:AppRefPeeled (Resolve-TorchAppRef -VersionTable @{ APP_REF = $script:AppRefPeeled }) 'a commit is already what the layer keys on'
    }
}

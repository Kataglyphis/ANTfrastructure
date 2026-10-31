#requires -Version 7.0
# APP_REF names a branch and the torch stage builds its commit, so the layer moves exactly when the app does.

$script:AppRefHead = '1111111111111111111111111111111111111111'
$script:AppRefTagObject = '2222222222222222222222222222222222222222'
$script:AppRefPeeled = '3333333333333333333333333333333333333333'

Describe 'Resolve-GitRefCommit' {

    foreach ($case in @(
            @{ Name = 'resolves a branch to the commit at its head'; Out = @("$($script:AppRefHead)`trefs/heads/develop"); Ref = 'develop'; Want = $script:AppRefHead; Why = 'the branch head' }
            @{ Name = 'resolves an annotated tag to the commit it peels to, not the tag object'; Out = @("$($script:AppRefTagObject)`trefs/tags/v1.0", "$($script:AppRefPeeled)`trefs/tags/v1.0^{}"); Ref = 'v1.0'; Want = $script:AppRefPeeled; Why = 'a tag object is not a commit git can fetch into a tree' }
            @{ Name = 'lets a branch win over a same-named tag'; Out = @("$($script:AppRefTagObject)`trefs/tags/both", "$($script:AppRefHead)`trefs/heads/both"); Ref = 'both'; Want = $script:AppRefHead; Why = 'tracking a branch is the point of the key' }
        )) {
        It $case.Name {
            Assert-Equal $case.Want (Resolve-GitRefCommit -LsRemoteOutput $case.Out -Ref $case.Ref) $case.Why
        }
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

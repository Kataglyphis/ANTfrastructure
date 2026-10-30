#requires -Version 7.0
# Its own harness-style suite: the Linux mutation shards cannot run the wheel suite's Windows-only cases.

Describe 'Dockerfile.media-builder: the LiteRT RUN keeps uv''s cache off the Bazel cache mount' {
    It 'points UV_CACHE_DIR at a container-local directory, never under C:\bzl-repo-cache (mutation)' {
        $stage = (Get-TestDockerfileStagesFromPath -Path (Join-Path (Get-RepoRoot) 'windows\Dockerfile.media-builder') -JoinContinuations -IgnoreComments).ByName['media-litert-built']
        $runs = @($stage.Lines | Where-Object { $_ -match '^RUN\s' -and $_ -match 'Build-LitertWheelBazel\.ps1' })
        Assert-Equal 1 $runs.Count 'one RUN builds the LiteRT wheel'
        $cache = [regex]::Match($runs[0], "UV_CACHE_DIR = '(?<dir>[^']+)'").Groups['dir'].Value
        Assert-True ([bool]$cache) 'that RUN sets UV_CACHE_DIR'
        Assert-False ($cache -like 'C:\bzl-repo-cache*') "uv's renames into a filled cache mount fail with os error 3: $cache"
    }
}

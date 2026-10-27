#requires -Version 7.0
# Harness-style so the Linux mutation shards, which carry no Pester, can prove the per-level hit line.
Describe 'sccache per-level hit evidence' {
  It 'names each level''s hits, misses and backfills, so a chain log shows which level served it' {
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' -FunctionName Format-SccacheLevelHits -Body {
      $levels = '[{"name":"L0 (webdav)","hits":3,"misses":7,"backfills_from":0,"backfills_to":5},{"name":"L1 (s3)","hits":5,"misses":2,"backfills_from":5,"backfills_to":0}]' | ConvertFrom-Json
      Assert-Equal 'L0 (webdav): 3 hit(s), 7 miss(es), backfills_from 0, backfills_to 5; L1 (s3): 5 hit(s), 2 miss(es), backfills_from 5, backfills_to 0' (Format-MutSccacheLevelHits -Levels $levels)
    }
  }

  It 'writes the per-level line to stderr, which a clipped step log keeps, once the drain ends' {
    $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1'))
    Assert-Match '(?s)function Wait-SccacheUploadDrain.*?\[Console\]::Error\.WriteLine\("sccache-levels\| \$\(Format-SccacheLevelHits -Levels \$levels\)"\).*?every upload done' $text
  }
}

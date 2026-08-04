# Tests for the warm/materialize handoff transport (Export-BuildHandoff /
# Import-BuildHandoff, WindowsSourceBuild.Common.psm1). The transport carries
# heavy-build artifacts out of never-finalized WARM solves over WebDAV (see
# docs/windows-builds.md § BuildKit/containerd lane). Tests run the FULL
# round trip offline: curl.exe speaks file:// for both PUT and GET, so a temp
# directory stands in for the dufs server.

Describe 'Export/Import-BuildHandoff round trip' {

    It 'exports the CreationTime delta and imports it back after deletion' {
        Invoke-InTestDir { param($dir)
            $server = Join-Path $dir 'srv'
            New-Item -ItemType Directory -Path (Join-Path $server 'bkhandoff') -Force | Out-Null
            $endpoint = 'file:///' + ($server -replace '\\', '/')

            $root = Join-Path $dir 'rootA'
            New-Item -ItemType Directory -Path (Join-Path $root 'sub') -Force | Out-Null
            $oldFile = Join-Path $root 'old.txt'
            Set-Content $oldFile 'ancient'
            $past = (Get-Date).AddDays(-2)
            [IO.File]::SetCreationTime($oldFile, $past)
            [IO.File]::SetLastWriteTime($oldFile, $past)
            $newFile = Join-Path $root 'sub\new.txt'
            Set-Content $newFile 'fresh'

            Export-BuildHandoff -Since (Get-Date).AddMinutes(-5) -Name 'wbt' -Endpoint $endpoint -Roots @($root)
            Assert-True (Test-Path (Join-Path $server 'bkhandoff\wbt.tar')) 'tar landed on the server'
            Assert-Equal 0 $LASTEXITCODE 'export clears the ambient exit code'

            # Materialize: delete the delta file, import must restore it at the
            # ORIGINAL absolute path (tar entries are relative to C:\).
            Remove-Item $newFile -Force
            Import-BuildHandoff -Name 'wbt' -Endpoint $endpoint
            Assert-True (Test-Path $newFile) 'import restored the delta file'
            Assert-Equal 'fresh' (Get-Content $newFile -Raw).Trim() 'content survived the round trip'
            Assert-Equal 0 $LASTEXITCODE 'import clears the ambient exit code'

            # The pre-Since file must NOT be in the tar: delete it, re-import,
            # and it must stay gone.
            Remove-Item $oldFile -Force
            Import-BuildHandoff -Name 'wbt' -Endpoint $endpoint
            Assert-False (Test-Path $oldFile) 'files older than -Since are excluded from the handoff'
        }
    }

    It 'throws when there is nothing to hand off' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'emptyRoot'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Assert-Throws {
                Export-BuildHandoff -Since (Get-Date).AddMinutes(5) -Name 'wbt' -Endpoint 'file:///C:/nowhere' -Roots @($root)
            } 'an empty delta must fail loudly, not upload an empty tar'
        }
    }

    It 'throws without an endpoint (env unset)' {
        $prev = $env:SCCACHE_WEBDAV_ENDPOINT
        try {
            Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue
            Assert-Throws { Export-BuildHandoff -Since (Get-Date) -Name 'wbt' } 'export must fail fast without a transport endpoint'
            Assert-Throws { Import-BuildHandoff -Name 'wbt' } 'import must fail fast without a transport endpoint'
        } finally {
            if ($null -ne $prev) { $env:SCCACHE_WEBDAV_ENDPOINT = $prev }
        }
    }

    It 'throws when the named handoff does not exist on the server' {
        Invoke-InTestDir { param($dir)
            $server = Join-Path $dir 'srv'
            New-Item -ItemType Directory -Path (Join-Path $server 'bkhandoff') -Force | Out-Null
            $endpoint = 'file:///' + ($server -replace '\\', '/')
            Assert-Throws {
                Import-BuildHandoff -Name 'never-warmed' -Endpoint $endpoint
            } 'a missing warm-solve handoff must fail the materialize step loudly'
        }
    }
}

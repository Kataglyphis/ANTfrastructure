#requires -Version 7.0
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

    It 'recreates the missing parent directory chain when the whole subtree is gone' {
        Invoke-InTestDir { param($dir)
            # Pins the bsdtar workaround in Import-BuildHandoff: the tar holds
            # FILE entries only, and bsdtar's Windows long-path mode does NOT
            # create missing parent chains — the import must pre-create every
            # directory itself. The round-trip case above deletes only files
            # (sub\ survives), so it can never catch a regression here.
            $server = Join-Path $dir 'srv'
            New-Item -ItemType Directory -Path (Join-Path $server 'bkhandoff') -Force | Out-Null
            $endpoint = 'file:///' + ($server -replace '\\', '/')

            $root = Join-Path $dir 'rootB'
            $deepFile    = Join-Path $root 'sub\deep\nested.txt'
            $shallowFile = Join-Path $root 'sub\shallow.txt'
            New-Item -ItemType Directory -Path (Join-Path $root 'sub\deep') -Force | Out-Null
            Set-Content $deepFile 'deep-payload'
            Set-Content $shallowFile 'shallow-payload'

            Export-BuildHandoff -Since (Get-Date).AddMinutes(-5) -Name 'wbt-tree' -Endpoint $endpoint -Roots @($root)

            # Delete the WHOLE subtree — a fresh materialize container has no
            # C:\runtime at all, so no parent of any tar entry exists.
            Remove-Item $root -Recurse -Force
            Assert-False (Test-Path $root) 'precondition: the entire root subtree is gone'

            Import-BuildHandoff -Name 'wbt-tree' -Endpoint $endpoint
            Assert-True (Test-Path $deepFile) 'import recreated the multi-level parent chain for the deep file'
            Assert-Equal 'deep-payload' (Get-Content $deepFile -Raw).Trim() 'deep file content survived'
            Assert-True (Test-Path $shallowFile) 'sibling at a shallower depth was restored too'
            Assert-Equal 0 $LASTEXITCODE 'import clears the ambient exit code'
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

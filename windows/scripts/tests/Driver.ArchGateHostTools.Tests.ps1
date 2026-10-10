#requires -Version 7.0
# The cross lane's host-tool pattern replaces the merge Dockerfile's default; a dropped alternative failed the arm64 gate on 26 pure-wheel launchers (2026-10-10).

Describe 'Build-Buildkit: the cross arch gate keeps the merge default host tools' {
    It 'repeats every alternative of the Dockerfile ARCH_GATE_HOST_TOOLS default' {
        $root = Get-RepoRoot
        $docker = Get-Content -Raw -LiteralPath (Join-Path $root 'windows\Dockerfile.media-merge-builder')
        $driver = Get-Content -Raw -LiteralPath (Join-Path $root 'windows\Build-Buildkit.ps1')
        Assert-True ($docker -match '(?m)^ARG ARCH_GATE_HOST_TOOLS="([^"]+)"') 'the Dockerfile declares a default'
        $default = $Matches[1]
        Assert-True ($driver -match "\`$archArgs\['ARCH_GATE_HOST_TOOLS'\] = '([^']+)'") 'the driver sets the cross pattern'
        $cross = $Matches[1]
        $missing = @($default -split '\|(?![^(]*\))' | Where-Object { -not $cross.Contains($_) })
        Assert-Equal '' ($missing -join ' ') 'every Dockerfile alternative is in the cross pattern'
    }

    It 'skips the launchers of a pure wheel and keeps a real target binary in scope' {
        $driver = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')
        $null = $driver -match "\`$archArgs\['ARCH_GATE_HOST_TOOLS'\] = '([^']+)'"
        $pattern = $Matches[1]
        foreach ($p in 'C:\t\3-pip-26.2.1-py3-none-any\pip\_vendor\distlib\t32.exe', 'C:\t\5-setuptools-84.0.0-py3-none-any\setuptools\cli-64.exe',
            'C:\t\5-setuptools-84.0.0-py3-none-any\setuptools\gui.exe') {
            Assert-Match $pattern $p "a pure wheel's launcher is a host tool: $p"
        }
        foreach ($p in 'C:\runtime\onnxruntime\bin\onnxruntime.dll', 'C:\t\7-numpy-2.5.3-cp314-cp314-win_arm64\numpy\_core\_multiarray_umath.pyd') {
            Assert-False ($p -match $pattern) "a shipped target binary stays in scope: $p"
        }
    }
}

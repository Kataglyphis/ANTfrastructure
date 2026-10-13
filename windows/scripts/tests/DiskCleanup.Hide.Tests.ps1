#requires -Version 7.0
# cleanup-disk-space's hide mode must take exactly the entries under its roots off PATH, through GITHUB_ENV, and delete nothing.

$script:actionDir = Join-Path (Get-RepoRoot) '.github\actions\cleanup-disk-space'
$script:hideScript = Join-Path $script:actionDir 'Hide-CleanupRoots.ps1'

function Invoke-Hide([string]$Dir, [string[]]$Roots, [string]$PathValue, [switch]$NoEnvFile) {
    $envFile = Join-Path $Dir 'github_env.txt'
    Set-Content -LiteralPath $envFile -Value ''
    $file = if ($NoEnvFile) { '' } else { $envFile }
    $out = & pwsh -NoProfile -Command "& '$script:hideScript' -Roots @($(($Roots | ForEach-Object { "'$_'" }) -join ',')) -PathValue '$PathValue' -EnvFile '$file'" 2>&1 | Out-String
    $line = @(Get-Content -LiteralPath $envFile | Where-Object { $_ -like 'PATH=*' })
    [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE; Lines = $line; Path = if ($line.Count) { $line[-1].Substring(5) } else { $null } }
}

Describe 'cleanup-disk-space: hide mode' {
    It 'takes the entries under a root off PATH, keeps the rest in order and deletes nothing' {
        Invoke-InTestDir {
            param($d)
            $strawberry = New-Item -ItemType Directory -Force -Path (Join-Path $d 'Strawberry\c\bin')
            $git = New-Item -ItemType Directory -Force -Path (Join-Path $d 'Git\cmd')
            $roots = @((Join-Path $d 'Strawberry'), (Join-Path $d 'CMake'))
            $path = "$($git.FullName);$($strawberry.FullName);$d\CMake\bin\;C:\Windows\System32"
            $r = Invoke-Hide $d $roots $path
            Assert-Equal 0 $r.Exit
            Assert-Equal 1 $r.Lines.Count 'one PATH line reaches GITHUB_ENV'
            Assert-Equal "$($git.FullName);C:\Windows\System32" $r.Path
            Assert-Match '2 of 4 PATH entries' $r.Out
            Assert-True (Test-Path -LiteralPath $strawberry.FullName) 'hide deletes nothing'
        }
    }

    It 'matches a wildcard root, and never a sibling that shares its prefix' {
        Invoke-InTestDir {
            param($d)
            $roots = @("$d\hostedtoolcache\Python\*\x86", "$d\tools\boost")
            $path = "$d\hostedtoolcache\Python\3.14.0\x86;$d\hostedtoolcache\Python\3.14.0\x64;$d\tools\boost2\bin;$d\tools\boost"
            $r = Invoke-Hide $d $roots $path
            Assert-Equal 0 $r.Exit
            Assert-Equal "$d\hostedtoolcache\Python\3.14.0\x64;$d\tools\boost2\bin" $r.Path
        }
    }

    It 'expands a PATH entry that still names a variable before comparing it' {
        Invoke-InTestDir {
            param($d)
            $r = Invoke-WithEnv @{ ANTF_HIDE_PROBE = "$d\LLVM" } {
                Invoke-Hide $d @("$d\LLVM") "%ANTF_HIDE_PROBE%\bin;$d\keep"
            }
            Assert-Equal "$d\keep" $r.Path
        }
    }

    It 'fails without GITHUB_ENV rather than hide nothing silently' {
        Invoke-InTestDir {
            param($d)
            $r = Invoke-Hide $d @("$d\x") "$d\x\bin" -NoEnvFile
            Assert-True ($r.Exit -ne 0) 'a missing GITHUB_ENV is an error'
            Assert-Match 'GITHUB_ENV is not set' $r.Out
        }
    }

    It 'is what the cleanup runs for mode hide, over both of its removal lists' {
        $action = Get-Content -LiteralPath (Join-Path $script:actionDir 'action.yml') -Raw
        Assert-Match "'foreground', 'background', 'wait', 'hide'" $action 'the mode check accepts hide'
        Assert-Match "Hide-CleanupRoots\.ps1'\) -Roots \(\`$removeFirst \+ \`$removeLast\)" $action
        Assert-Match 'foreach \(\$path in \$removeFirst\)' $action 'the deletions read the same first list'
        Assert-Match 'foreach \(\$path in \$removeLast\)' $action 'the deletions read the same last list'
    }
}

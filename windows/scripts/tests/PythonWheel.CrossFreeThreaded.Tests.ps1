#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the build itself, which needs :winarm64's two free-threaded trees and VS's ARM64 tools (proved there, CON75).

Describe 'the arm64 cross lane''s free-threaded wheel (CON75)' {

    BeforeAll {
        $script:pythonDir = Join-Path (Get-RepoRoot) 'windows\scripts\python'
        $script:buildText = [IO.File]::ReadAllText((Join-Path $script:pythonDir 'New-CrossFreeThreadedWheel.ps1'))
        $script:packagingText = [IO.File]::ReadAllText((Join-Path $script:pythonDir 'Invoke-CiPackaging.ps1'))
        $script:workflowText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) '.github\workflows\container-ci-windows.yml'))
        $script:crossText = (Get-Command Invoke-CrossWheelBuild).ScriptBlock.ToString()
    }

    It 'runs in a child process of the packaging driver, which writes the kit beside the arm64 bundle' {
        Assert-Match "Invoke-SiblingScript 'New-CrossFreeThreadedWheel\.ps1' @\('-RepoRoot', \`$repoRoot, '-OutDir', \(Join-Path \`$laneDir 'free-threaded'\)" $script:packagingText `
            'a child, so the VS cross environment ends with it; beside the bundle, never in dist\, where Select-PythonAppWheel would refuse it'
        Assert-Match '\$laneDir = Join-Path \$repoRoot "dist\\windows-\$\(Get-WindowsPackageArch -Arch \$arch\)"' $script:packagingText 'the arm64 lane''s product directory'
    }

    It 'names the target for every build_ext and bdist_wheel instance, and builds without isolation in the pinned venv' {
        Assert-Match "Enter-VsDevCmdEnvironment -Arch \`$arch" $script:buildText 'VS''s cross tools'
        Assert-Match "New-FreeThreadedBuildPython -GilPython \`$gil -VenvDir \(Join-Path \`$work 'venv'\) -Package \`$requires" $script:buildText 'EXT_SUFFIX pinned to the target'
        Assert-Match 'Invoke-CrossWheelBuild -Python \$venv\.Exe -Source \$RepoRoot -LibDir \$target\.LibDir -AbiTag \(Get-FreeThreadedAbiTag\)' $script:buildText 'the shared cross build'
        Assert-Match "WriteAllLines\(\`$cfg, \[string\[\]\]@\('\[build_ext\]', `"plat_name = \`$\(\`$tag -replace '_', '-'\)`", `"library_dirs = \`$LibDir`"" $script:crossText `
            'the target libs reach the relink that bdist_wheel starts too'
        Assert-Match "'\[bdist_wheel\]', `"plat_name = \`$tag`"" $script:crossText 'the wheel''s platform tag'
        Assert-Match '\$env:DIST_EXTRA_CONFIG = \$cfg' $script:crossText 'setuptools reads it for every command'
        Assert-Match 'uv build --wheel --no-build-isolation --python \$Python' $script:crossText 'the pinned venv runs the backend'
    }

    It 'gates the wheel before it packs the kit' {
        $build = $script:buildText.IndexOf('Invoke-CrossWheelBuild -Python')
        $pack = $script:buildText.IndexOf("Copy-Item -LiteralPath `$wheel.FullName -Destination `$OutDir")
        Assert-True ($build -gt 0 -and $pack -gt $build) 'nothing ungated reaches the device'
        Assert-Match 'Get-FreeThreadedWheelFinding -Path \$wheel\.FullName -PlatformTag \$tag' $script:crossText 'the tags'
        Assert-Match 'Get-FreeThreadedWheelImportFinding -Path \$wheel\.FullName -AbiTag \$AbiTag' $script:crossText 'the python3XYt.dll imports'
        Assert-Match 'Assert-WheelTargetArch -WheelPath \$wheel\.FullName' $script:crossText 'every PE member the target''s'
        foreach ($file in 'free-threaded-wheel.py', 'WindowsPythonWheel.Common.psm1', 'Test-FreeThreadedWheel.ps1') {
            Assert-True $script:buildText.Contains($file) "the kit carries $file"
        }
    }

    It 'proves the kit on the device from the arm64 run job, and passes a product without one' {
        Assert-Match "name: Prove the free-threaded wheel natively" $script:workflowText 'a step of the run job'
        Assert-Match "free-threaded\\Test-FreeThreadedWheel\.ps1" $script:workflowText 'the kit''s own entry point'
        Assert-Match "This product carries no free-threaded wheel\.'; return" $script:workflowText 'no kit, no failure'
    }

    It 'the device script refuses a kit without its interpreter' {
        Invoke-InTestDir { param($d)
            Copy-Item -LiteralPath (Join-Path $script:pythonDir 'Test-FreeThreadedWheel.ps1') -Destination $d
            Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Destination $d
            Assert-Throws { & (Join-Path $d 'Test-FreeThreadedWheel.ps1') } -MessagePattern 'no free-threaded interpreter \(python3\.\*t\.exe\)'
        }
    }
}

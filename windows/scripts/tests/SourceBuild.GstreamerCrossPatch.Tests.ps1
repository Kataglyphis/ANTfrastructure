#requires -Version 7.0
# The actual cross-patch dispatch runs against source snippets; upstream fetching and Meson execution are not covered.

Import-Module (Join-Path $PSScriptRoot 'WindowsMedia.WiringFixture.psm1') -DisableNameChecking

Describe 'GStreamer cross source patch dispatch' {
    It 'patches both real call sites, remains idempotent, skips absent files and fails each present-file drift' {
        $commands = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-GstreamerFromSource.ps1' -Name Invoke-VerifiedSourceFilePatch)
        $blocks = @($commands | ForEach-Object { Get-MediaTestEnclosingIf -Node $_ -ConditionPattern '^\$script:GstCross$' } | Select-Object -Unique)
        Assert-Equal 1 $blocks.Count 'one cross-only dispatch owns both patches'
        $apply = [scriptblock]::Create('param($gstSrcDir); $script:GstCross = $true; $script:GstTargetArch = ''arm64''; ' + $blocks[0].Extent.Text)
        Invoke-InTestDir -Files @{
            'subprojects/gst-plugins-base/meson.build' = "have_sse = cc.has_argument(sse_args)`nhave_sse2 = cc.has_argument(sse2_args)`n"
            'subprojects/gst-plugins-bad/gst-libs/gst/vulkan/meson.build' = "if build_machine.cpu_family() == 'x86_64'`n  vulkan_lib_dir = join_paths(vulkan_root, 'Lib')`nendif`n"
        } -Body { param($dir)
            $state = New-TestCallState @{ Root = $dir; Apply = $apply }
            Invoke-WithTestFunction -Name log -FixtureState $state -Definition { param($message) $State.Calls.Add($message) } -Body { param($state)
                $base = Join-Path $state.Root 'subprojects/gst-plugins-base/meson.build'
                $vulkan = Join-Path $state.Root 'subprojects/gst-plugins-bad/gst-libs/gst/vulkan/meson.build'
                & $state.Apply $state.Root
                $baseText = [IO.File]::ReadAllText($base); $vulkanText = [IO.File]::ReadAllText($vulkan)
                Assert-Equal 2 ([regex]::Matches($baseText, "and host_machine.cpu_family\(\) in \['x86', 'x86_64'\]")).Count
                Assert-Match "if host_machine.cpu_family\(\) == 'aarch64'" $vulkanText
                Assert-Match "vulkan_root, 'Lib-ARM64'" $vulkanText
                Assert-Match "elif build_machine.cpu_family\(\) == 'x86_64'" $vulkanText
                Assert-Equal 2 $state.Calls.Count
                Assert-Match 'Patched gst-plugins-base' $state.Calls[0]
                Assert-Match 'Patched gst-plugins-bad: Vulkan lib dir -> Lib-ARM64' $state.Calls[1]
                $state.Calls.Clear()
                & $state.Apply $state.Root
                Assert-Equal $baseText ([IO.File]::ReadAllText($base))
                Assert-Equal $vulkanText ([IO.File]::ReadAllText($vulkan))
                Assert-Equal 2 @($state.Calls | Where-Object { $_ -match 'already applied' }).Count
                [IO.File]::WriteAllText($base, 'changed upstream')
                Assert-Throws { & $state.Apply $state.Root } -MessagePattern 'have_sse/have_sse2 guard did not apply'
                [IO.File]::WriteAllText($base, $baseText)
                [IO.File]::WriteAllText($vulkan, 'changed upstream')
                Assert-Throws { & $state.Apply $state.Root } -MessagePattern 'lib-dir fix did not apply'
                Remove-Item -LiteralPath $base, $vulkan
                $state.Calls.Clear()
                & $state.Apply $state.Root
                Assert-Equal 2 @($state.Calls | Where-Object { $_ -match '^NOTE:.*not found - skipping' }).Count
            }
        }.GetNewClosure()
    }
}

#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Build-GstreamerFromSource.ps1's Get-GstGdkPixbufMesonArgs (BACKLOG CON28): the amd64 merge builds
# the gdkpixbuf plugin, `enabled` so a lost dependency fails meson setup, and the cross lane passes
# nothing. NOT covered: meson, or gdk-pixbuf's own build.

Describe 'Get-GstGdkPixbufMesonArgs (amd64 only)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-GstreamerFromSource.ps1' -FunctionName 'Get-GstGdkPixbufMesonArgs')

    It 'enables the plugin on the native lane, with gdk-pixbuf''s man pages and tests off' {
        $a = @(Get-GstGdkPixbufMesonArgs)
        Assert-True ($a -contains '-Dgst-plugins-good:gdk-pixbuf=enabled') 'never auto'
        Assert-True ($a -contains '-Dgdk-pixbuf:man=false') 'the image has no rst2man'
        Assert-True ($a -contains '-Dgdk-pixbuf:tests=false') 'its tests ship nothing'
    }

    It 'passes nothing on the cross lane, which has no build-machine glib-compile-resources' {
        Assert-Equal 0 @(Get-GstGdkPixbufMesonArgs -Cross).Count 'the arm64 command line is unchanged'
    }

    It 'rides on the meson setup line' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-GstreamerFromSource.ps1')
        Assert-Match '\+ @\(Get-GstGdkPixbufMesonArgs -Cross:\$script:GstCross\)' $src 'part of $setupArgs'
    }
}

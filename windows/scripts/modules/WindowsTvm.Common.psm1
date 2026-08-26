#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# TVM-specific facts that no other component shares.
#
# WHY THIS IS ITS OWN MODULE — CACHE BOUNDARY, NOT TASTE, AND IT IS THE POINT
# OF THE #134 WAVE.
# Before #134 there were exactly six module homes on the media lane: the
# `buildmods` stage's .psm1 set, which is the import closure of
# WindowsSourceBuild.Common and is mounted into ALL media/merge RUNs. Anything
# put there re-keyed the ~75 min ONNX branch, the OpenCV branch and the FFmpeg
# branch to change a TVM constant. So TVM-only helpers had no choice but to live
# inside build-tvm-from-source.ps1, where they were stage-local and cheap but
# reachable by tests only through the script's AST.
#
# Dockerfile.media-builder now derives `FROM buildmods AS tvmmods` and adds this
# file, and ONLY the `media-tvm-built` RUN mounts that stage. media-tvm runs
# parallel to media-core, so a TVM-private module costs nothing on the long
# pole. Editing this file re-runs the TVM branch and nothing else — that is the
# property BuildKit.ModuleClosure.Tests.ps1 exists to keep.
#
# Therefore: do NOT add this module to `buildmods` itself, and do not mount
# `tvmmods` into any RUN other than media-tvm-built. Adding a second consumer
# means the code belongs in buildmods and the cache win is gone.
#
# DELIBERATELY DEPENDENCY-FREE: no Import-Module. It is mounted alongside the
# buildmods six, so Shared is available if a future function needs it — but
# taking that dependency here would be the first step back toward the closure
# this module exists to escape.

Set-StrictMode -Version Latest

# The vendored tvm-ffi's own version: the nearest v* tag of the submodule
# checkout (PEP 440-normalised: v0.1.13-post3 -> 0.1.13.post3), else the lower
# bound TVM's pyproject demands (apache-tvm-ffi>=X) -- the version that makes
# the two assembled wheels resolve against each other.
# Pure function (fixture test SourceBuild.TvmAssembledWheel.Tests.ps1).
function Get-VendoredTvmFfiVersion {
    param(
        [string]$DescribeOutput = '',
        [string]$TvmPyprojectText = ''
    )
    $d = "$DescribeOutput".Trim()
    if ($d -match '^v?(\d+(?:\.\d+)*)(?:[-.]?(post\d+|rc\d+|a\d+|b\d+))?$') {
        $v = $Matches[1]
        if ($Matches[2]) { $v += '.' + $Matches[2] }
        return $v
    }
    $m = [regex]::Match($TvmPyprojectText, 'apache-tvm-ffi\s*>=\s*([0-9][0-9A-Za-z.+!-]*)')
    if ($m.Success) { return $m.Groups[1].Value }
    throw 'Get-VendoredTvmFfiVersion: neither a v* tag on the tvm-ffi submodule nor an apache-tvm-ffi>= bound in TVM''s pyproject.toml'
}

Export-ModuleMember -Function Get-VendoredTvmFfiVersion

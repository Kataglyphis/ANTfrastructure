#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Per lane, the global smoke floor must neither exceed the section floors nor sit so far below them that it is inert.

Describe 'smoke gate: the global floor is calibrated against the section floors' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $s = Join-Path $root 'scripts\build\Test-Container.ps1'
        if (-not (Test-Path $s)) { throw "smoke test not found: $s" }
        $block = [regex]::Match((Get-Content -Raw $s), '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        # '<sec>' = @{ Gpu = n; Cpu = n; Arm64 = n }: groups 2/3/4 keep the order the assertions rely on.
        $script:floorTriples = [regex]::Matches($block, "'(\d+)'\s*=\s*@\{\s*Gpu\s*=\s*(\d+);\s*Cpu\s*=\s*(\d+);\s*Arm64\s*=\s*(\d+)\s*\}")
        $script:driver = Get-Content -Raw (Join-Path $root 'Build-Buildkit.ps1')
    }

    It 'section floors parse and cover all three lanes' {
        Assert-True ($script:floorTriples.Count -ge 20) "expected the full three-column section floor table, parsed $($script:floorTriples.Count) entries"
        # A section entry without an Arm64 key means one section silently has no arm64 floor.
        $s = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\build\Test-Container.ps1'
        $block = [regex]::Match((Get-Content -Raw $s), '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        $entries = @([regex]::Matches($block, "'(\d+)'\s*=\s*@\{[^}]*\}"))
        $incomplete = @($entries | Where-Object { $_.Value -notmatch 'Gpu\s*=' -or $_.Value -notmatch 'Cpu\s*=' -or $_.Value -notmatch 'Arm64\s*=' })
        Assert-Equal 0 $incomplete.Count "every section must carry Gpu, Cpu and Arm64 floors (incomplete: $(($incomplete | ForEach-Object { $_.Value }) -join ' | '))"
        Assert-Equal $entries.Count $script:floorTriples.Count 'every entry parses in the canonical Gpu/Cpu/Arm64 order'
    }

    It 'the GPU and CPU floors the driver sends match their section sums' {
        $gpuSum = ($script:floorTriples | ForEach-Object { [int]$_.Groups[2].Value } | Measure-Object -Sum).Sum
        $cpuSum = ($script:floorTriples | ForEach-Object { [int]$_.Groups[3].Value } | Measure-Object -Sum).Sum

        $gpuFloor = [int][regex]::Match($script:driver, '\$effectiveMinPassed\s*=\s*(\d+)').Groups[1].Value
        $cpuFloor = [int][regex]::Match($script:driver, '\[int\]\$SmokeMinPassed\s*=\s*(\d+)').Groups[1].Value

        Assert-True ($gpuFloor -gt 0) 'the GPU lane floor is gone from Build-Buildkit.ps1'
        # A run sitting exactly at every section floor is legitimate, so never above the section sum.
        Assert-True ($gpuFloor -le $gpuSum) "GPU global floor $gpuFloor exceeds the sum of the GPU section floors ($gpuSum)"
        Assert-True ($cpuFloor -le $cpuSum) "CPU global floor $cpuFloor exceeds the sum of the CPU section floors ($cpuSum)"
        # ...and must stay within reach of them, or it never fires.
        Assert-True ($gpuFloor -ge [int]($gpuSum * 0.9)) "GPU global floor $gpuFloor is inert against a section sum of $gpuSum"
        Assert-True ($cpuFloor -ge [int]($cpuSum * 0.9)) "CPU global floor $cpuFloor is inert against a section sum of $cpuSum"
    }

    It 'the ARM64 floor the driver sends matches the arm64 section sum' {
        $armSum = ($script:floorTriples | ForEach-Object { [int]$_.Groups[4].Value } | Measure-Object -Sum).Sum
        $armFloor = [int][regex]::Match($script:driver, '\$armMinPassed\s*=\s*(\d+)').Groups[1].Value

        Assert-True ($armFloor -gt 0) 'the arm64 lane floor ($armMinPassed) is gone from Build-Buildkit.ps1'
        Assert-True ($armFloor -le $armSum) "arm64 global floor $armFloor exceeds the sum of the arm64 section floors ($armSum)"
        Assert-True ($armFloor -ge [int]($armSum * 0.9)) "arm64 global floor $armFloor is inert against a section sum of $armSum"
    }

    It 'payload sections floor at 0 on arm64 and stay 0 — never "fixed" by a skip' {
        # Payload sections cannot pass on an x64 host, so they floor at 0; a host section at 0 forfeits coverage.
        $payload = @('7', '8', '9', '10', '11', '12', '13', '17', '18', '20', '21', '22')
        $hostSections = @('1', '2', '3', '4', '5', '6', '14', '15', '16', '19', '23', '25')
        foreach ($t in $script:floorTriples) {
            $sec = $t.Groups[1].Value
            $arm = [int]$t.Groups[4].Value
            if ($payload -contains $sec) {
                Assert-Equal 0 $arm "section $sec executes the payload; its arm64 floor must be 0"
            } elseif ($hostSections -contains $sec) {
                Assert-True ($arm -gt 0) "section $sec is host-toolchain work and must carry a nonzero arm64 floor"
            }
        }
    }
}

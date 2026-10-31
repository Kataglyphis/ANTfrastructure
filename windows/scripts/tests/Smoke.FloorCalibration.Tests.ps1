#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Per lane, the global smoke floor must neither exceed the section floors nor sit so far below them that it is inert.

Describe 'smoke gate: the global floor is calibrated against the section floors' {

    BeforeAll {
        $script:smokeText = (Get-TestScriptAst -ScriptPath 'windows/scripts/build/Test-Container.ps1').Extent.Text
        $script:floorBlock = [regex]::Match($script:smokeText, '(?s)\$sectionFloors = @\{(.+?)\n\}').Groups[1].Value
        # '<sec>' = @{ Gpu = n; Cpu = n; Arm64 = n }: groups 2/3/4 keep the order the assertions rely on.
        $script:floorTriples = [regex]::Matches($script:floorBlock, "'(\d+)'\s*=\s*@\{\s*Gpu\s*=\s*(\d+);\s*Cpu\s*=\s*(\d+);\s*Arm64\s*=\s*(\d+)\s*\}")
        $script:driver = (Get-TestScriptAst -ScriptPath 'windows/Build-Buildkit.ps1').Extent.Text

        function Assert-LaneFloorCalibrated {
            param([string]$Lane, [int]$Column, [string]$Pattern, [string]$GoneMessage)
            $sum = ($script:floorTriples | ForEach-Object { [int]$_.Groups[$Column].Value } | Measure-Object -Sum).Sum
            $floor = [int][regex]::Match($script:driver, $Pattern).Groups[1].Value
            if ($GoneMessage) { Assert-True ($floor -gt 0) $GoneMessage }
            # A run sitting exactly at every section floor is legitimate, so never above the section sum.
            Assert-True ($floor -le $sum) "$Lane global floor $floor exceeds the sum of the $Lane section floors ($sum)"
            # ...and must stay within reach of them, or it never fires.
            Assert-True ($floor -ge [int]($sum * 0.9)) "$Lane global floor $floor is inert against a section sum of $sum"
        }
    }

    It 'section floors parse and cover all three lanes' {
        Assert-True ($script:floorTriples.Count -ge 20) "expected the full three-column section floor table, parsed $($script:floorTriples.Count) entries"
        # A section entry without an Arm64 key means one section silently has no arm64 floor.
        $entries = @([regex]::Matches($script:floorBlock, "'(\d+)'\s*=\s*@\{[^}]*\}"))
        $incomplete = @($entries | Where-Object { $_.Value -notmatch 'Gpu\s*=' -or $_.Value -notmatch 'Cpu\s*=' -or $_.Value -notmatch 'Arm64\s*=' })
        Assert-Equal 0 $incomplete.Count "every section must carry Gpu, Cpu and Arm64 floors (incomplete: $(($incomplete | ForEach-Object { $_.Value }) -join ' | '))"
        Assert-Equal $entries.Count $script:floorTriples.Count 'every entry parses in the canonical Gpu/Cpu/Arm64 order'
    }

    It 'the GPU and CPU floors the driver sends match their section sums' {
        Assert-LaneFloorCalibrated -Lane GPU -Column 2 -Pattern '\$effectiveMinPassed\s*=\s*(\d+)' -GoneMessage 'the GPU lane floor is gone from Build-Buildkit.ps1'
        Assert-LaneFloorCalibrated -Lane CPU -Column 3 -Pattern '\[int\]\$SmokeMinPassed\s*=\s*(\d+)'
    }

    It 'the ARM64 floor the driver sends matches the arm64 section sum' {
        Assert-LaneFloorCalibrated -Lane arm64 -Column 4 -Pattern '\$armMinPassed\s*=\s*(\d+)' -GoneMessage 'the arm64 lane floor ($armMinPassed) is gone from Build-Buildkit.ps1'
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

#requires -Version 7.0
# A gap or overlap in the ranges only shows up as a hash mismatch after a multi-minute preseed download.

Describe 'Get-ByteRangeSplit' {

    It 'covers 0..Length-1 exactly: contiguous, no overlap, the last range ends at Length-1' {
        foreach ($case in @(@{ L = 263284967; P = 32 }, @{ L = 100; P = 7 }, @{ L = 5; P = 5 }, @{ L = 1; P = 32 }, @{ L = 64; P = 1 })) {
            $ranges = @(Get-ByteRangeSplit -Length $case.L -Parts $case.P)
            Assert-Equal 0 $ranges[0].From "L=$($case.L) P=$($case.P): the first range starts at 0"
            Assert-Equal ($case.L - 1) $ranges[-1].To "L=$($case.L) P=$($case.P): the last range ends at Length-1"
            for ($i = 1; $i -lt $ranges.Count; $i++) {
                Assert-Equal ($ranges[$i - 1].To + 1) $ranges[$i].From "L=$($case.L) P=$($case.P): range $i follows range $($i - 1) with no gap or overlap"
            }
            $sum = ($ranges | ForEach-Object { $_.To - $_.From + 1 } | Measure-Object -Sum).Sum
            Assert-Equal $case.L $sum "L=$($case.L) P=$($case.P): the sizes add up to the length"
            Assert-True ($ranges.Count -le $case.P) "L=$($case.L) P=$($case.P): never more ranges than asked for"
        }
    }

    It 'refuses a length that has no bytes to split' {
        Assert-Throws { Get-ByteRangeSplit -Length 0 -Parts 4 } -MessagePattern 'length must be positive'
    }
}

#requires -Version 7.0
# Tests for Get-BuildJobCount — the memory-scaled parallelism math. A regression here
# either serializes builds (slow) or over-subscribes a memory-capped container (OOM /
# deadlock — the exact failure mode that made onnx-genai's full-core build risky).

Describe 'Get-BuildJobCount' {

    It 'BUILD_JOBS overrides everything (explicit numeric)' {
        Invoke-WithEnv @{ BUILD_JOBS = '7'; MEMORY_LIMIT_GB = '4' } {
            Assert-Equal 7 (Get-BuildJobCount)
        }
    }

    It 'ignores a non-numeric BUILD_JOBS and falls through to the memory math' {
        Invoke-WithEnv @{ BUILD_JOBS = 'abc'; MEMORY_LIMIT_GB = '1' } {
            $j = Get-BuildJobCount -MemGBPerJob 4
            Assert-Equal 2 $j 'non-numeric override ignored; tiny mem floors to 2'
        }
    }

    It 'enforces a floor of 2 jobs when memory is tiny' {
        Invoke-WithEnv @{ BUILD_JOBS = ''; MEMORY_LIMIT_GB = '1' } {
            Assert-Equal 2 (Get-BuildJobCount -MemGBPerJob 4)
        }
    }

    It 'caps at core count when memory is abundant' {
        Invoke-WithEnv @{ BUILD_JOBS = ''; MEMORY_LIMIT_GB = '1000000' } {
            Assert-Equal ([Environment]::ProcessorCount) (Get-BuildJobCount -MemGBPerJob 4)
        }
    }

    It 'scales down as MemGBPerJob rises (heavier TUs get fewer jobs)' {
        Invoke-WithEnv @{ BUILD_JOBS = ''; MEMORY_LIMIT_GB = '16' } {
            $light = Get-BuildJobCount -MemGBPerJob 4
            $heavy = Get-BuildJobCount -MemGBPerJob 8
            Assert-True ($heavy -le $light) "heavier per-job memory must not increase job count ($heavy vs $light)"
        }
    }

    It 'derives min(cores, mem/perJob) when that lands between the floor and the cap' {
        $cores = [Environment]::ProcessorCount
        if ($cores -ge 4) {
            Invoke-WithEnv @{ BUILD_JOBS = ''; MEMORY_LIMIT_GB = '12' } {
                # 12 / 4 = 3, which is >=2 (floor) and <= cores(>=4): expect exactly 3.
                Assert-Equal 3 (Get-BuildJobCount -MemGBPerJob 4)
            }
        } else {
            # Low-core host: the cap dominates; assert it never exceeds cores.
            Invoke-WithEnv @{ BUILD_JOBS = ''; MEMORY_LIMIT_GB = '12' } {
                Assert-True ((Get-BuildJobCount -MemGBPerJob 4) -le $cores)
            }
        }
    }
}

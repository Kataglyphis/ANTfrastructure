#requires -Version 7.0
# The codec .pc rewrite FFmpeg's configure link test reads; no real codec build.

Describe 'Add-CodecPcSystemLib (x265 4.2 static lib needs advapi32)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-FfmpegCodecs.ps1' -FunctionName 'Add-CodecPcSystemLib')

    # Runs Add-CodecPcSystemLib -Name advapi32 on a .pc holding $Text; returns the file afterwards, LF-joined.
    function Invoke-OnPc([string]$Text, [int]$Times = 1) {
        Invoke-InTestDir { param($root)
            $pc = Join-Path $root 'x265.pc'
            [System.IO.File]::WriteAllText($pc, $Text)
            for ($n = 0; $n -lt $Times; $n++) { Add-CodecPcSystemLib -Pc $pc -Name 'advapi32' | Out-Null }
            [System.IO.File]::ReadAllText($pc) -replace "`r`n", "`n"
        }
    }

    It 'appends the missing system lib to Libs: once, and leaves every other line alone' {
        # x265 4.2's generated x265.pc, trimmed to the lines that matter here.
        $pc = "prefix=C:/runtime/ffmpeg-codecs`nName: x265`nLibs: -L`${libdir} -lx265`nLibs.private: -lc++`n"
        $want = $pc.Replace('-lx265', '-lx265 -ladvapi32')
        Assert-Equal $want (Invoke-OnPc $pc -Times 2) 'appended exactly once across two runs; Libs.private untouched'
    }

    It 'treats only the whole -l<name> as present (a longer name is not it)' {
        Assert-Equal "Libs: -lx265 -ladvapi32x -ladvapi32`n" (Invoke-OnPc "Libs: -lx265 -ladvapi32x`n") 'a prefix match does not count'
    }

    It 'refuses a .pc without exactly one Libs: line' {
        Assert-Throws { Invoke-OnPc "Name: x265`n" } -MessagePattern 'has 0 Libs: line'
        Assert-Throws { Invoke-OnPc "Libs: -lx265`nLibs: -lx265`n" } -MessagePattern 'has 2 Libs: line'
    }
}

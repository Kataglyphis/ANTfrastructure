#requires -Version 7.0
# KleidiAI on arm64: the trusted deps.txt row, the patched ASM_MARMASM rule and the preprocess-then-armasm64 wrapper.

$script:ortScript = 'windows\scripts\build\Build-OnnxFromSource.ps1'

Describe 'Get-OrtKleidiaiDepsEntry' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ortScript -FunctionName 'Get-OrtDepsRow', 'Get-OrtKleidiaiDepsEntry')
    $script:row = 'kleidiai;https://github.com/ARM-software/kleidiai/archive/refs/tags/v1.20.0.tar.gz;6895e72b3d5cf1173358164cb3d64c9d7d33cc84'

    It 'reads the one kleidiai row (the real v1.30.0 line), not the qmx fork beside it' {
        $e = Get-OrtKleidiaiDepsEntry -DepsLine @('dawn;https://x;0000000000000000000000000000000000000000', $script:row,
            'kleidiai-qmx;https://github.com/qualcomm/kleidiai/archive/2f10c9a8.zip;5e855730a2d69057a569f43dd7532db3b2d2a05c')
        Assert-Equal 'https://github.com/ARM-software/kleidiai/archive/refs/tags/v1.20.0.tar.gz' $e.Url
        Assert-Equal '6895e72b3d5cf1173358164cb3d64c9d7d33cc84' $e.Sha1
    }

    It 'refuses a missing or duplicated row, a foreign URL and a non-SHA1 pin (mutation)' {
        Assert-Throws { Get-OrtKleidiaiDepsEntry -DepsLine @('dawn;u;s') } -MessagePattern "0 'kleidiai;' rows"
        Assert-Throws { Get-OrtKleidiaiDepsEntry -DepsLine @($script:row, $script:row) } -MessagePattern "2 'kleidiai;' rows"
        Assert-Throws { Get-OrtKleidiaiDepsEntry -DepsLine @('kleidiai;https://evil.example/kai.tar.gz;6895e72b3d5cf1173358164cb3d64c9d7d33cc84') } -MessagePattern 'not an ARM-software/kleidiai release tag'
        Assert-Throws { Get-OrtKleidiaiDepsEntry -DepsLine @('kleidiai;https://github.com/ARM-software/kleidiai/archive/refs/tags/v1.20.0.tar.gz;abc') } -MessagePattern 'not a SHA1'
    }
}

Describe 'Edit-KleidiaiMarmasmRule' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ortScript -FunctionName 'Edit-KleidiaiMarmasmRule')
    # KleidiAI v1.20.0's lines 13-17, the anchor and its neighbours.
    $script:cml = "project(KleidiAI)`n`nif(MSVC)`n    enable_language(ASM_MARMASM)`nelse()`n    enable_language(ASM)`nendif()`n"

    It 'sets the rule on the line right after enable_language(ASM_MARMASM), indented alike, forward slashes' {
        $out = Edit-KleidiaiMarmasmRule -CMakeText $script:cml -WrapperPath 'C:\temp\kleidiai\src\kai-armasm.cmd'
        $lines = $out -split "`n"
        $at = [array]::IndexOf($lines, '    enable_language(ASM_MARMASM)')
        Assert-Equal '    set(CMAKE_ASM_MARMASM_COMPILE_OBJECT "C:/temp/kleidiai/src/kai-armasm.cmd <SOURCE> <OBJECT>")' $lines[$at + 1]
        Assert-Equal 'else()' $lines[$at + 2] 'nothing else moves'
        Assert-Equal ($script:cml.Length + $lines[$at + 1].Length + 1) $out.Length 'exactly one line added'
    }

    It 'keeps CRLF files CRLF' {
        $crlf = $script:cml -replace "`n", "`r`n"
        $out = Edit-KleidiaiMarmasmRule -CMakeText $crlf -WrapperPath 'C:\w.cmd'
        Assert-Match "enable_language\(ASM_MARMASM\)`r`n    set\(CMAKE_ASM_MARMASM_COMPILE_OBJECT" $out
        Assert-Equal 0 ([regex]::Matches($out, "(?<!`r)`n").Count) 'no bare LF introduced'
    }

    It 'refuses a file with no anchor, two anchors, or a rule already set (mutation)' {
        Assert-Throws { Edit-KleidiaiMarmasmRule -CMakeText "project(x)`nenable_language(ASM)`n" -WrapperPath 'C:\w.cmd' } -MessagePattern 'has 0 enable_language\(ASM_MARMASM\)'
        Assert-Throws { Edit-KleidiaiMarmasmRule -CMakeText ($script:cml + $script:cml) -WrapperPath 'C:\w.cmd' } -MessagePattern 'has 2 enable_language\(ASM_MARMASM\)'
        $once = Edit-KleidiaiMarmasmRule -CMakeText $script:cml -WrapperPath 'C:\w.cmd'
        Assert-Throws { Edit-KleidiaiMarmasmRule -CMakeText $once -WrapperPath 'C:\w.cmd' } -MessagePattern 'already sets CMAKE_ASM_MARMASM_COMPILE_OBJECT'
    }
}

Describe 'Get-KleidiaiArmasmWrapper' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:ortScript -FunctionName 'Get-KleidiaiArmasmWrapper')

    It 'preprocesses with /P /EP /TC /U__clang__ for the target, then assembles with armasm64, CRLF, failing fast' {
        $cmd = Get-KleidiaiArmasmWrapper -Triple 'aarch64-pc-windows-msvc'
        Assert-Match '(?m)^clang-cl --target=aarch64-pc-windows-msvc /nologo /P /EP /TC /U__clang__ "/Fi%~2\.i" "%~1" \|\| exit /b 1\r$' $cmd
        Assert-Match '(?m)^armasm64 -nologo "%~2\.i" -o "%~2" \|\| exit /b 1\r$' $cmd
        Assert-Equal 0 ([regex]::Matches($cmd, "(?<!`r)`n").Count) 'cmd.exe script: CRLF only'
        Assert-False ($cmd -match '/arch') 'no /arch reaches armasm64 (A2029)'
    }
}

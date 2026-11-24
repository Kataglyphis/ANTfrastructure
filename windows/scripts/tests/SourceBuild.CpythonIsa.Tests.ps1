#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Grades CPython's per-file MSBuild wiring; native compiler execution and runtime dispatch need separate proof.

$propsPath = Join-Path (Get-RepoRoot) 'windows/scripts/build/cpython-Directory.Build.props'
$script:isaProps = [xml](Get-Content -LiteralPath $propsPath -Raw)
$script:isaNs = [Xml.XmlNamespaceManager]::new($script:isaProps.NameTable)
$script:isaNs.AddNamespace('m', 'http://schemas.microsoft.com/developer/msbuild/2003')
$script:isaTarget = $script:isaProps.SelectSingleNode('/m:Project/m:Target', $script:isaNs)

Describe 'CPython per-file ISA floor' {
    It 'retains ClangCL and applies the floor after project item metadata is known' {
        $toolset = $script:isaProps.SelectSingleNode('/m:Project/m:PropertyGroup/m:PlatformToolset', $script:isaNs)
        Assert-Equal 'ClangCL' $toolset.InnerText
        Assert-NotNull $script:isaTarget 'late target required'
        Assert-Equal 'ClCompile' $script:isaTarget.GetAttribute('BeforeTargets')
        Assert-Equal 1 $script:isaProps.SelectNodes('/m:Project/m:Target', $script:isaNs).Count
        Assert-Equal 0 $script:isaProps.SelectNodes('/m:Project/m:ItemDefinitionGroup', $script:isaNs).Count 'early defaults override upstream per-file /arch'
    }

    It 'leaves ARM64 and other toolsets outside the x64 ClangCL floor' {
        Assert-Equal '''$(Platform)'' == ''x64'' and ''$(PlatformToolset)'' == ''ClangCL''' $script:isaTarget.GetAttribute('Condition')
    }

    It 'updates every existing compile item without adding, selecting or removing source files' {
        $item = $script:isaTarget.SelectSingleNode('m:ItemGroup/m:ClCompile', $script:isaNs)
        Assert-NotNull $item 'existing compile items required'
        Assert-Equal 0 $item.Attributes.Count 'no Include/Remove/Update file selection'
        Assert-Equal 2 $item.SelectNodes('m:AdditionalOptions', $script:isaNs).Count
        Assert-Equal 2 $item.ChildNodes.Count 'no replacement of upstream ISA or dispatch metadata'
    }

    foreach ($selection in @(
        @{ Name = 'keeps v3 on ordinary files with inherited options'; Index = 0; Operator = '!='; Floor = 'v3' },
        @{ Name = 'retains AVX512 v4 and inherited VNNI/VPCLMUL options'; Index = 1; Operator = '=='; Floor = 'v4' }
    )) {
        It $selection.Name {
            $option = $script:isaTarget.SelectNodes('m:ItemGroup/m:ClCompile/m:AdditionalOptions', $script:isaNs)[$selection.Index]
            Assert-Equal ("'%(ClCompile.EnableEnhancedInstructionSet)' {0} 'AdvancedVectorExtensions512'" -f $selection.Operator) $option.GetAttribute('Condition')
            Assert-Equal ('/clang:-march=x86-64-{0} %(ClCompile.AdditionalOptions)' -f $selection.Floor) $option.InnerText
        }
    }
}

#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A Python app as a relocatable folder: the image's CPython, the locked wheels, chain ORT, launchers; see docs/python-app-bundles.md § What the builders do

Set-StrictMode -Version Latest

# Guarded, never -Force: a forced nested import unloads the caller's top-level copy.
foreach ($sibling in 'WindowsOrtPayload.Common', 'WindowsCrossBundle.Common') {
    if (-not (Get-Module -Name $sibling)) { Import-Module (Join-Path $PSScriptRoot "$sibling.psm1") -DisableNameChecking }
}

$script:LauncherSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'python\app-launcher\launcher.c'

function Get-PythonAppConfig {
    <#
    .SYNOPSIS
        Reads a consumer's packaging/app.json and refuses one that lacks a key every bundle needs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No app config at $Path" }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $missing = @('name', 'id', 'distribution', 'extras', 'data_env', 'data_dir', 'self_test' | Where-Object { -not $config.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "$Path lacks: $($missing -join ', ')" }
    return $config
}

function Resolve-PythonAppPath {
    <#
    .SYNOPSIS
        -Path as given when rooted, else under -RepoRoot: app.json and the scripts' defaults are repo-relative.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RepoRoot,
        [Parameter(Mandatory, Position = 1)][string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $RepoRoot $Path
}

function New-PythonAppRuntime {
    <#
    .SYNOPSIS
        Lays the image's source-built CPython out as a standalone install in -Destination, with CPython's own PC\layout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$Destination
    )

    $python = Join-Path $BuildDir 'python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "No built CPython at $python" }
    $layout = Join-Path $SourceDir 'PC\layout'
    if (-not (Test-Path -LiteralPath $layout -PathType Container)) { throw "No PC\layout in ${SourceDir}: the CPython source tree is incomplete" }
    # Tests, IDLE and Tk have no place in an app; pip stays out, since uv installs from outside.
    & $python $layout --source $SourceDir --build $BuildDir --copy $Destination --include-stable --include-venv --precompile
    if ($LASTEXITCODE -ne 0) { throw "PC\layout failed (exit $LASTEXITCODE)" }
    $runtimePython = Join-Path $Destination 'python.exe'
    if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) { throw "PC\layout left no python.exe in $Destination" }
    # PC\layout copies the image's own site-packages (chain wheels, cv2 bindings); an app starts from its lock alone.
    $sitePackages = Join-Path $Destination 'Lib\site-packages'
    Get-ChildItem -LiteralPath $sitePackages -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'README.txt' } | Remove-Item -Recurse -Force
    return $runtimePython
}

function Get-PythonAbiTag {
    <#
    .SYNOPSIS
        The ABI tag -Python's binary wheels carry: cp314 for a GIL build, cp314t for a free-threaded one.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Python)
    $tag = & $Python -c "import sys, sysconfig; print('cp%d%d%s' % (sys.version_info[0], sys.version_info[1], 't' if sysconfig.get_config_var('Py_GIL_DISABLED') else ''))"
    if ($LASTEXITCODE -ne 0 -or -not $tag) { throw "$Python could not report its ABI tag (exit $LASTEXITCODE)" }
    return "$tag".Trim()
}

function Select-PythonAppWheel {
    <#
    .SYNOPSIS
        The app's win_amd64 wheel for -AbiTag (or abi3), else its pure wheel; binaries for another ABI alone are an error, not a fallback.
    #>
    [OutputType([IO.FileInfo])]
    param(
        [Parameter(Mandatory)][IO.FileInfo[]]$Wheels,
        [Parameter(Mandatory)][string]$AbiTag
    )
    $binary = @($Wheels | Where-Object { $_.Name -match '-win_amd64\.whl$' })
    $match = @($binary | Where-Object { $_.Name -match "-($([regex]::Escape($AbiTag))|abi3)-win_amd64\.whl$" })
    if ($match.Count -gt 0) { return $match[0] }
    if ($binary.Count -gt 0) { throw "No $AbiTag wheel, only $(($binary | ForEach-Object Name) -join ', '); build it with the bundle's interpreter (uv build --python X.Y+gil)" }
    $pure = @($Wheels | Where-Object { $_.Name -match '-none-any\.whl$' })
    if ($pure.Count -gt 0) { return $pure[0] }
    throw "No win_amd64 or none-any wheel among $(($Wheels | ForEach-Object Name) -join ', ')"
}

# Throws with -What when uv fails, so no step can forget $LASTEXITCODE.
function Invoke-AppUv {
    param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][string[]]$Arguments)
    & uv @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

# Uninstalls every distribution in -Python whose name matches -Pattern.
function Remove-AppDistribution {
    param([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Pattern)
    $names = @(& uv pip list --python $Python --format json | ConvertFrom-Json | Where-Object { $_.name -match $Pattern } | ForEach-Object { $_.name })
    if ($names.Count -gt 0) { Invoke-AppUv -What "removing $($names -join ', ')" -Arguments (@('pip', 'uninstall', '--python', $Python) + $names) }
}

function Install-PythonAppPackage {
    <#
    .SYNOPSIS
        Installs the locked dependencies, the app wheel and the chain ORT wheel into the runtime interpreter.
    .DESCRIPTION
        The dependencies come from uv.lock with their hashes; the app wheel goes in without dependencies; then
        every PyPI ONNX Runtime is swapped for the chain wheel, the only ORT the family ships.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AppWheel,
        [Parameter(Mandatory)][string[]]$Extras,
        [Parameter(Mandatory)][string]$OrtWheel,
        [Parameter(Mandatory)][string]$WorkDir
    )

    $requirements = Join-Path $WorkDir 'requirements.lock.txt'
    $extraArgs = @($Extras | ForEach-Object { '--extra', $_ })
    Push-Location $RepoRoot
    try {
        Invoke-AppUv -What 'uv export' -Arguments (@('export', '--locked', '--no-dev', '--no-emit-project', '--format', 'requirements.txt') + $extraArgs + @('--output-file', $requirements))
    } finally { Pop-Location }

    Invoke-AppUv -What 'installing the locked dependencies' -Arguments @('pip', 'install', '--python', $Python, '--compile-bytecode', '--requirement', $requirements)
    Invoke-AppUv -What "installing $AppWheel" -Arguments @('pip', 'install', '--python', $Python, '--compile-bytecode', '--no-deps', $AppWheel)
    # onnxruntime-genai is a package of its own, not an ORT build; G6 still proves every ORT binary in the tree.
    Remove-AppDistribution -Python $Python -Pattern '^onnxruntime($|[-_](?!genai))'
    Invoke-AppUv -What "installing the chain ORT wheel $OrtWheel" -Arguments @('pip', 'install', '--python', $Python, '--compile-bytecode', '--no-index', '--no-deps', $OrtWheel)
}

function Copy-ChainOpenCvPackage {
    <#
    .SYNOPSIS
        Copies the image's cv2 into -SitePackages and points its loader at the DLLs it imports; returns the DLLs or dirs.
    .DESCRIPTION
        The image's own sitecustomize.py registers its DLL homes, and neither a venv nor a bundle runs it, so cv2's config
        must name them. A bundle copies the import closure into cv2\bin; -ReferenceImage (a CI venv inside the image)
        names the image dirs that closure came from instead. The .pyd is found through the loader's LOADER_DIR either way.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SitePackages,
        [string]$Source = 'C:\temp\cpython\Lib\site-packages\cv2',
        [string]$RuntimeRoot = 'C:\runtime',
        [switch]$ReferenceImage,
        # Bundle dirs that already hold part of the closure (the chain ORT's capi): searched first, named in config, never copied.
        [string[]]$SharedDirectory = @()
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Source '__init__.py') -PathType Leaf)) { throw "No chain cv2 at $Source; the image predates it" }
    # The loader's config dirs, the chain ORT opencv_dnn links, then every image runtime dir on PATH (FFmpeg has its own).
    $sourceConfig = Get-Content -LiteralPath (Join-Path $Source 'config.py') -Raw
    $search = @(
        [regex]::Matches($sourceConfig, "os\.path\.join\('([^']+)',\s*'([^']+)'\)") | ForEach-Object { Join-Path $_.Groups[1].Value $_.Groups[2].Value }
        if ($env:ONNX_ROOT) { Join-Path $env:ONNX_ROOT 'bin' }
        $env:PATH -split ';' | Where-Object { $_ -and $_.StartsWith("$RuntimeRoot\", [StringComparison]::OrdinalIgnoreCase) }
        Join-Path $RuntimeRoot 'bin'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath } | Select-Object -Unique

    $dest = Join-Path $SitePackages 'cv2'
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force
    Get-ChildItem -LiteralPath $dest -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
    $pyd = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Filter 'cv2*.pyd')
    if ($pyd.Count -ne 1) { throw "Expected one cv2*.pyd under $dest, found $($pyd.Count)" }

    if ($ReferenceImage) {
        $closure = @(Get-PeImportClosure -Path $pyd[0].FullName -SearchDirectory $search -Arch amd64)
        $used = @($closure | ForEach-Object { Split-Path $_ -Parent }) | Select-Object -Unique
        $result = @($search | Where-Object { $used -contains $_ })
        $paths = @($result | ForEach-Object { "    r'$_'," })
    } else {
        $shared = @($SharedDirectory | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
        $closure = @(Get-PeImportClosure -Path $pyd[0].FullName -SearchDirectory (@($shared) + $search) -Arch amd64)
        $bin = Join-Path $dest 'bin'
        $null = New-Item -ItemType Directory -Force -Path $bin
        $result = @(foreach ($source in $closure) {
                if ($shared -contains (Split-Path $source -Parent)) { continue }
                $target = Join-Path $bin (Split-Path $source -Leaf)
                Copy-Item -LiteralPath $source -Destination $target -Force
                $target
            })
        $paths = @("    os.path.join(LOADER_DIR, 'bin'),") +
            @($shared | ForEach-Object { "    os.path.normpath(os.path.join(LOADER_DIR, r'$([IO.Path]::GetRelativePath($dest, $_))'))," })
    }
    Set-Content -LiteralPath (Join-Path $dest 'config.py') -Encoding utf8NoBOM -Value (@('import os', '', 'BINARIES_PATHS = [') + $paths + '] + BINARIES_PATHS')
    $pydDir = [IO.Path]::GetRelativePath($dest, $pyd[0].DirectoryName).Replace('\', '/')
    foreach ($versioned in Get-ChildItem -LiteralPath $dest -File -Filter 'config-3*.py') {
        Set-Content -LiteralPath $versioned.FullName -Encoding utf8NoBOM -Value "PYTHON_EXTENSIONS_PATHS = [os.path.join(LOADER_DIR, '$pydDir')] + PYTHON_EXTENSIONS_PATHS"
    }
    return $result
}

function Install-PythonAppChainOpenCv {
    <#
    .SYNOPSIS
        Swaps a PyPI OpenCV in the runtime for the image's own cv2, with its DLL closure in cv2\bin; returns the copies.
    .DESCRIPTION
        PyPI's cv2.pyd imports Media Foundation, which Server Core and Windows N lack; the image's build uses
        DirectShow and FFmpeg.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$SitePackages,
        [string]$Source = 'C:\temp\cpython\Lib\site-packages\cv2',
        [string]$RuntimeRoot = 'C:\runtime'
    )

    Remove-AppDistribution -Python $Python -Pattern '^opencv(-contrib)?-python(-headless)?$'
    # opencv_dnn imports onnxruntime.dll: it loads the bundle's chain ORT rather than shipping a second copy.
    $copied = @(Copy-ChainOpenCvPackage -SitePackages $SitePackages -Source $Source -RuntimeRoot $RuntimeRoot -SharedDirectory (Join-Path $SitePackages 'onnxruntime\capi'))
    # The launchers pass -B, so bytecode the bundle does not ship is recompiled on every start.
    & $Python -m compileall -q (Join-Path $SitePackages 'cv2')
    if ($LASTEXITCODE -ne 0) { throw "compiling the chain cv2 package failed (exit $LASTEXITCODE)" }
    return $copied
}

function Get-PythonAppEntryPoint {
    <#
    .SYNOPSIS
        The console scripts of an installed distribution, name -> 'module:function', read from its entry_points.txt.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$SitePackages,
        [Parameter(Mandatory)][string]$Distribution
    )

    $normalized = ($Distribution -replace '[-_.]+', '_').ToLowerInvariant()
    $info = @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter '*.dist-info' |
        Where-Object { (($_.Name -replace '-[^-]+\.dist-info$', '') -replace '[-_.]+', '_').ToLowerInvariant() -eq $normalized })
    if ($info.Count -ne 1) { throw "Expected one $Distribution dist-info in $SitePackages, found $($info.Count)" }
    $file = Join-Path $info[0].FullName 'entry_points.txt'
    $scripts = [ordered]@{}
    if (-not (Test-Path -LiteralPath $file)) { return $scripts }
    $section = ''
    foreach ($line in Get-Content -LiteralPath $file) {
        if ($line -match '^\s*\[(?<s>[^\]]+)\]\s*$') { $section = $Matches['s']; continue }
        if ($section -ne 'console_scripts' -or $line -notmatch '^\s*(?<n>[^=\s]+)\s*=\s*(?<t>[\w.]+:[\w.]+)\s*$') { continue }
        $scripts[$Matches['n']] = $Matches['t']
    }
    return $scripts
}

function New-PythonAppLauncher {
    <#
    .SYNOPSIS
        Compiles launcher.c into -Destination\<Name>.exe for one 'module:function' entry point.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$EntryPoint,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$DataEnv,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$WorkDir
    )

    if ($EntryPoint -notmatch '^(?<m>[\w.]+):(?<f>\w+)$') { throw "Entry point '$EntryPoint' is not 'module:function'" }
    # A forced-include header, so no define has to survive PowerShell and clang-cl quoting.
    $header = Join-Path $WorkDir "$Name.entry.h"
    $module = $Matches['m']
    $function = $Matches['f']
    $cDataDir = $DataDir.Replace('/', '\').Replace('\', '\\')
    @(
        "#define ENTRY_MODULE L`"$module`""
        "#define ENTRY_FUNC L`"$function`""
        "#define DATA_ENV L`"$DataEnv`""
        "#define DATA_SUBDIR L`"$cDataDir`""
    ) | Set-Content -LiteralPath $header -Encoding ascii
    $exe = Join-Path $Destination "$Name.exe"
    $obj = Join-Path $WorkDir "$Name.obj"
    # /MT: the launcher sits beside runtime\, not in it, so it cannot lean on the VC++ DLLs the runtime carries.
    & clang-cl /nologo /O2 /MT /W3 /FI $header "/Fo$obj" "/Fe$exe" $script:LauncherSource /link /SUBSYSTEM:CONSOLE
    if ($LASTEXITCODE -ne 0) { throw "clang-cl could not build the $Name launcher (exit $LASTEXITCODE)" }
    return $exe
}

function Copy-PythonAppRuntimeClosure {
    <#
    .SYNOPSIS
        Copies the VC++ runtime DLLs every native file in -Runtime imports into -Runtime, beside python.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string[]]$SearchDirectory
    )

    $native = @(Get-ChildItem -LiteralPath $Runtime -Recurse -File -Include '*.pyd', '*.dll', '*.exe' | ForEach-Object { $_.FullName })
    return Copy-PeImportClosure -Path $native -SearchDirectory $SearchDirectory -Destination $Runtime -Arch amd64
}

function Invoke-PythonAppSelfTest {
    <#
    .SYNOPSIS
        Runs the app's self-test through its launcher and refuses anything but exit 0 with a JSON report saying ok.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][string[]]$Command,
        # The report's onnxruntime_module must lie under it: an installed app must not load another copy of ORT.
        [string]$Root = ''
    )

    $exe = Join-Path $Bundle "$($Command[0]).exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "No launcher $exe for the self-test" }
    $rest = @($Command | Select-Object -Skip 1)
    # stderr is shown, never parsed: ORT prints EP errors there (DirectML on a host without a GPU).
    $stdout = @(& $exe @rest 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  stderr: $_" } else { "$_" }
        })
    $code = $LASTEXITCODE
    $text = $stdout -join [Environment]::NewLine
    Write-Host $text
    if ($code -ne 0) { throw "self-test '$($Command -join ' ')' exited $code" }
    # The report is the last block from a bare '{' line to a bare '}' line; ORT's fallback notice has braces of its own.
    $lines = @($text -split "`r?`n")
    $end = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -ceq '}') { $end = $i; break } }
    $start = -1
    for ($i = $end; $i -ge 0; $i--) { if ($lines[$i] -ceq '{') { $start = $i; break } }
    if ($start -lt 0 -or $end -lt $start) { throw "self-test '$($Command -join ' ')' printed no JSON report" }
    $report = ($lines[$start..$end] -join "`n") | ConvertFrom-Json -AsHashtable
    if (-not $report['ok']) { throw "self-test '$($Command -join ' ')' did not report ok" }
    $module = [string]$report['onnxruntime_module']
    if ($Root -and $module -and -not $module.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "The self-test loaded ONNX Runtime from $module, outside $Root"
    }
    return $report
}

function ConvertTo-PythonAppIcon {
    <#
    .SYNOPSIS
        Wraps a PNG as a one-image .ico, which MSI shortcuts and Add/Remove Programs need; Windows reads PNG frames.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $png = [IO.File]::ReadAllBytes($PngPath)
    if ($png.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($png, 1, 3) -cne 'PNG') { throw "$PngPath is not a PNG" }
    # IHDR's width and height are big-endian; an .ico entry stores 256 as 0.
    $width = ([int]$png[16] -shl 24) -bor ([int]$png[17] -shl 16) -bor ([int]$png[18] -shl 8) -bor [int]$png[19]
    $height = ([int]$png[20] -shl 24) -bor ([int]$png[21] -shl 16) -bor ([int]$png[22] -shl 8) -bor [int]$png[23]
    if ($width -gt 256 -or $height -gt 256) { throw "$PngPath is ${width}x${height}; an .ico image is at most 256x256" }
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]($width % 256)); $writer.Write([byte]($height % 256)); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
    $writer.Write($png)
    $writer.Flush()
    [IO.File]::WriteAllBytes($Destination, $stream.ToArray())
    return $Destination
}

# WiX 4.0.6 takes no File directly under a Directory and has no <Files> harvesting: one Component per file, ids counted.
function Add-WxsTree {
    param([Text.StringBuilder]$Tree, [Text.StringBuilder]$Files, [IO.DirectoryInfo]$Directory, [string]$DirectoryId, [int]$Depth, [hashtable]$Counter)
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory.FullName -File | Sort-Object Name)) {
        $Counter.n++
        $null = $Files.AppendLine("      <Component Id=`"c$($Counter.n)`" Directory=`"$DirectoryId`"><File Id=`"f$($Counter.n)`" Source=`"$([Security.SecurityElement]::Escape($file.FullName))`" /></Component>")
    }
    $pad = ' ' * (2 * $Depth)
    foreach ($sub in @(Get-ChildItem -LiteralPath $Directory.FullName -Directory | Sort-Object Name)) {
        $Counter.n++
        $id = "d$($Counter.n)"
        $null = $Tree.AppendLine("$pad<Directory Id=`"$id`" Name=`"$([Security.SecurityElement]::Escape($sub.Name))`">")
        Add-WxsTree -Tree $Tree -Files $Files -Directory $sub -DirectoryId $id -Depth ($Depth + 1) -Counter $Counter
        $null = $Tree.AppendLine("$pad</Directory>")
    }
}

# Text for an installer manifest's attributes and elements.
function Protect-PythonAppXml([string]$Text) { return [Security.SecurityElement]::Escape($Text) }

# What every installer shows: gui_script (else the first script) and the description (else the name).
function Get-PythonAppShown {
    param([Parameter(Mandatory)][hashtable]$App)
    return [pscustomobject]@{
        Gui         = if ($App.ContainsKey('gui_script') -and $App['gui_script']) { $App['gui_script'] } else { @($App['scripts'])[0] }
        Description = if ($App.ContainsKey('description')) { $App['description'] } else { $App['name'] }
    }
}

function New-PythonAppWxs {
    <#
    .SYNOPSIS
        WiX 4 source for a per-machine MSI of -Bundle: every file, a Start menu shortcut to gui_script, the folder on PATH.
    .DESCRIPTION
        A major upgrade keyed on app.json's msi_upgrade_code replaces any older version; the CLIs reach PATH through a
        system Environment entry that the uninstall removes again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$IconPath,
        [Parameter(Mandatory)][string]$Destination
    )

    foreach ($key in 'msi_upgrade_code', 'publisher') {
        if (-not $App.ContainsKey($key) -or -not $App[$key]) { throw "app.json needs '$key' for an MSI" }
    }
    if ($Version -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,5}$') { throw "MSI versions are major.minor.build (255.255.65535); '$Version' is not" }
    $name = $App['name']
    # MSI cannot install below MAX_PATH; measured against the default install dir.
    $installRoot = "C:\Program Files\$name\"
    $longest = Get-ChildItem -LiteralPath $Bundle -Recurse -File | ForEach-Object { $_.FullName.Substring($Bundle.TrimEnd('\').Length + 1) } |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($longest -and ($installRoot.Length + $longest.Length) -ge 260) { throw "$installRoot$longest is $($installRoot.Length + $longest.Length) characters; MSI stops at 259" }

    $shown = Get-PythonAppShown -App $App
    $gui = $shown.Gui
    $description = $shown.Description
    $key = "Software\$($App['publisher'])\$name"
    $tree = [Text.StringBuilder]::new()
    $files = [Text.StringBuilder]::new()
    Add-WxsTree -Tree $tree -Files $files -Directory (Get-Item -LiteralPath $Bundle) -DirectoryId 'INSTALLFOLDER' -Depth 4 -Counter @{ n = 0 }
    $homepage = if ($App.ContainsKey('homepage')) { "`n    <Property Id=`"ARPURLINFOABOUT`" Value=`"$(Protect-PythonAppXml $App['homepage'])`" />" } else { '' }
    $wxs = @"
<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="$(Protect-PythonAppXml $name)" Manufacturer="$(Protect-PythonAppXml $App['publisher'])" Version="$Version" UpgradeCode="$($App['msi_upgrade_code'])" Scope="perMachine">
    <MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="app.ico" SourceFile="$(Protect-PythonAppXml $IconPath)" />
    <Property Id="ARPPRODUCTICON" Value="app.ico" />$homepage
    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="$(Protect-PythonAppXml $name)">
$($tree.ToString().TrimEnd())
        <Component Id="PathEntry">
          <Environment Id="PathEntry" Name="PATH" Value="[INSTALLFOLDER]" Action="set" Part="last" System="yes" Permanent="no" />
          <RegistryValue Root="HKLM" Key="$(Protect-PythonAppXml $key)" Name="PathEntry" Type="integer" Value="1" KeyPath="yes" />
        </Component>
      </Directory>
    </StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder">
      <Component Id="StartMenuShortcut">
        <Shortcut Id="AppShortcut" Name="$(Protect-PythonAppXml $name)" Description="$(Protect-PythonAppXml $description)" Target="[INSTALLFOLDER]$(Protect-PythonAppXml $gui).exe" WorkingDirectory="INSTALLFOLDER" Icon="app.ico" />
        <RegistryValue Root="HKLM" Key="$(Protect-PythonAppXml $key)" Name="StartMenuShortcut" Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </StandardDirectory>
    <ComponentGroup Id="AppFiles">
$($files.ToString().TrimEnd())
    </ComponentGroup>
    <Feature Id="Main" Title="$(Protect-PythonAppXml $name)">
      <ComponentGroupRef Id="AppFiles" />
      <ComponentRef Id="PathEntry" />
      <ComponentRef Id="StartMenuShortcut" />
    </Feature>
  </Package>
</Wix>
"@
    Set-Content -LiteralPath $Destination -Value $wxs -Encoding utf8NoBOM
    return $Destination
}

function New-PythonAppSigningCertificate {
    <#
    .SYNOPSIS
        A throwaway code-signing certificate for -Subject, made in memory and written as .pfx and .cer; returns its thumbprint.
    .DESCRIPTION
        No certificate store is touched, so a developer's run leaves nothing behind. The .pfx is unprotected: delete it once signed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][string]$CerPath
    )

    $x509 = 'Security.Cryptography.X509Certificates'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = New-Object "$x509.CertificateRequest" $Subject, $rsa, ([Security.Cryptography.HashAlgorithmName]::SHA256), ([Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add((New-Object "$x509.X509BasicConstraintsExtension" $false, $false, 0, $true))
        $request.CertificateExtensions.Add((New-Object "$x509.X509KeyUsageExtension" ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature), $true))
        $codeSigning = [Security.Cryptography.OidCollection]::new()
        $null = $codeSigning.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
        $request.CertificateExtensions.Add((New-Object "$x509.X509EnhancedKeyUsageExtension" $codeSigning, $false))
        $now = [DateTimeOffset]::UtcNow
        $cert = $request.CreateSelfSigned($now.AddDays(-1), $now.AddYears(1))
        [IO.File]::WriteAllBytes($PfxPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx))
        [IO.File]::WriteAllBytes($CerPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        return $cert.Thumbprint
    } finally {
        $rsa.Dispose()
    }
}

function New-PythonAppAppxManifest {
    <#
    .SYNOPSIS
        AppxManifest.xml for an MSIX of the bundle: one full-trust console app per script, each with an execution alias.
    .DESCRIPTION
        The aliases put the scripts on PATH as the MSI's PATH entry does; only gui_script appears in the Start menu.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Destination
    )

    if ($Version -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$') { throw "MSIX versions here are major.minor.build, with .0 appended; '$Version' is not" }
    # The manifest's Publisher must equal the signing certificate's subject; a DN special character would need escaping in both.
    if ($Publisher -notmatch '^CN=[A-Za-z0-9 ._-]+$') { throw "MSIX publisher '$Publisher' must be CN= plus letters, digits, space, '.', '_' or '-'" }
    $identity = (@($App['publisher'], $App['name']) | ForEach-Object { $_ -replace '[^A-Za-z0-9]', '' }) -join '.'
    if ($identity.Length -lt 3 -or $identity.Length -gt 50) { throw "MSIX identity '$identity' must be 3 to 50 characters" }
    $name = $App['name']
    $shown = Get-PythonAppShown -App $App
    $about = Protect-PythonAppXml $shown.Description
    $seen = @{}
    $apps = foreach ($script in @($App['scripts'])) {
        $id = $script -replace '[^A-Za-z0-9]', ''
        if ($id -notmatch '^[A-Za-z]' -or $seen.ContainsKey($id)) { throw "Script '$script' gives MSIX application id '$id', which is not a unique id starting with a letter" }
        $seen[$id] = $true
        $isGui = $script -eq $shown.Gui
        $display = Protect-PythonAppXml $(if ($isGui) { $name } else { $script })
        $listed = if ($isGui) { '' } else { ' AppListEntry="none"' }
        $exe = Protect-PythonAppXml "$script.exe"
        @"
    <Application Id="$id" Executable="$exe" EntryPoint="Windows.FullTrustApplication" desktop4:Subsystem="console" desktop4:SupportsMultipleInstances="true">
      <uap:VisualElements DisplayName="$display" Description="$about" BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png"$listed />
      <Extensions>
        <uap3:Extension Category="windows.appExecutionAlias" Executable="$exe" EntryPoint="Windows.FullTrustApplication">
          <uap3:AppExecutionAlias>
            <desktop:ExecutionAlias Alias="$exe" />
          </uap3:AppExecutionAlias>
        </uap3:Extension>
      </Extensions>
    </Application>
"@
    }
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3"
  xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/windows10"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap3 desktop desktop4 rescap">
  <Identity Name="$identity" Publisher="$(Protect-PythonAppXml $Publisher)" Version="$Version.0" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>$(Protect-PythonAppXml $name)</DisplayName>
    <PublisherDisplayName>$(Protect-PythonAppXml $App['publisher'])</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
    <Description>$about</Description>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
$(($apps -join "`n").TrimEnd())
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@
    Set-Content -LiteralPath $Destination -Value $manifest -Encoding utf8NoBOM
    return $Destination
}

Export-ModuleMember -Function Get-PythonAppConfig, Resolve-PythonAppPath, New-PythonAppRuntime, Get-PythonAbiTag, Select-PythonAppWheel, Install-PythonAppPackage, Copy-ChainOpenCvPackage, Install-PythonAppChainOpenCv, Get-PythonAppEntryPoint,
    New-PythonAppLauncher, Copy-PythonAppRuntimeClosure, Invoke-PythonAppSelfTest, ConvertTo-PythonAppIcon, New-PythonAppWxs,
    New-PythonAppSigningCertificate, New-PythonAppAppxManifest

param(
    [string]$TempDir       = 'C:\temp'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Admin-Check

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Bitte PowerShell als Administrator ausführen.'; exit 1
}

function Dump-InstallerLogs {
    param([string]$TempDir)


    Write-Host "`n=== Installer log files in $TempDir ===`n"
    Get-ChildItem $TempDir -Filter '*vs_installer.log' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "----- $($_.Name) (full) -----"
    Get-Content $_.FullName -Raw
    }


    Get-ChildItem $TempDir -Filter '*_errors.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host "----- $($_.Name) (full) -----"
    Get-Content $_.FullName -Raw
    }


    Get-ChildItem $TempDir -Filter 'dd_setup_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host "----- $($_.Name) (tail 500) -----"
    Get-Content $_.FullName -Tail 500
    }


    Write-Host "`n----- Quick search for common error patterns in dd_* logs -----"
    Get-ChildItem $TempDir -Filter 'dd_*' -ErrorAction SilentlyContinue | Select-String -Pattern 'error|failed|exception|0x[0-9A-Fa-f]+' -CaseSensitive:$false | Select-Object Filename,LineNumber,Line | ForEach-Object {
    Write-Host "[$($_.Filename):$($_.LineNumber)] $($_.Line)"
    }


    Write-Host "`n----- Disk space (C:) -----"
    Get-PSDrive C | Select-Object Used,Free,Root


    Write-Host "`n----- Network quick-check -----"
    try { Test-Connection -ComputerName www.microsoft.com -Count 1 -ErrorAction Stop | Select-Object Address,ResponseTime } catch { Write-Host "Network check failed: $($_.Exception.Message)" }
}

# TLS 1.2 sicherstellen (für Downloads)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Temp-Verzeichnis vorbereiten

# ensure we run the installer with the temp dir we control
$env:TEMP = $TempDir
$env:TMP  = $TempDir

Write-Host "Using TEMP=$env:TEMP for installer temporary files and logs."
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$installer = Join-Path $TempDir 'vs_buildtools.exe'
$installerLog = Join-Path $TempDir 'vs_installer.log'

# Optionale ENV-Variablen analog Dockerfile

try {
    Write-Host 'Lade Visual Studio Build Tools Installer...'
    $downloaded = $false
    try {
        Write-Host 'Versuch mit curl.exe (eigener DNS-Resolver)...'
        & curl.exe -fsSL --retry 3 'https://aka.ms/vs/stable/vs_buildtools.exe' -o $installer
        if ($LASTEXITCODE -eq 0 -and (Test-Path $installer)) { $downloaded = $true; Write-Host 'curl erfolgreich.' }
    } catch { Write-Host "curl fehlgeschlagen: $($_.Exception.Message)" }
    if (-not $downloaded) {
        try {
            Write-Host 'Fallback BITS...'
            Start-BitsTransfer -Source 'https://aka.ms/vs/stable/vs_buildtools.exe' -Destination $installer -ErrorAction Stop
            Write-Host 'BITS erfolgreich.'; $downloaded = $true
        } catch { Write-Host "BITS fehlgeschlagen: $($_.Exception.Message)" }
    }
    if (-not $downloaded) {
        try {
            Write-Host 'Fallback Invoke-WebRequest...'
            Invoke-WebRequest -Uri 'https://aka.ms/vs/stable/vs_buildtools.exe' -OutFile $installer
            $downloaded = $true
        } catch { Write-Host "Invoke-WebRequest fehlgeschlagen: $($_.Exception.Message)" }
    }
    if (-not $downloaded) { throw 'VS Build Tools Download fehlgeschlagen.' }

    $args = @(
        '--quiet',
        '--wait', '--norestart', '--nocache',

        # Workloads

        '--add', 'Microsoft.VisualStudio.Workload.MSBuildTools',              # Core MSBuild toolset
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',                   # C++ desktop build tools
        #'--add', 'Microsoft.VisualStudio.Workload.AzureBuildTools',          # Azure development build tools
        #'--add', 'Microsoft.VisualStudio.Workload.UniversalBuildTools',       # UWP build tools
        #'--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools', # .NET desktop build tools

        # Core Build Components

        '--add', 'Microsoft.Component.MSBuild',                              # MSBuild compiler
        '--add', 'Microsoft.VisualStudio.Component.CoreBuildTools',          # Core build utilities
        # '--add', 'Microsoft.VisualStudio.Component.TextTemplating',        # T4 text template engine
        
        # Windows SDK & Native Desktop

        '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',      # Windows 11 SDK (26100)
        # '--add','Microsoft.VisualStudio.Workload.NativeDesktop',           # only for full GUI functionality 
                                                                             # NOT for CICD

        # LLVM/Clang

        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.Clang',           # Clang compiler for Windows
        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',    # Clang-cl toolset

        # VC++ Analysis & Tools
        
        '--add', 'Microsoft.VisualStudio.Component.VC.ASAN',                 # AddressSanitizer (memory debugging)
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',        # CMake tools for Windows
        
        # VC++ Core
        
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreBuildTools',       # C++ core build tools
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreIde',              # C++ core IDE features
        # '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'         # MSVC v143 compiler (x86/x64)
        # '--add', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest',   # C++ redistributable
        
        # VC++ Libraries
        
        # '--add', 'Microsoft.VisualStudio.Component.VC.ATL',                 # Active Template Library
        # '--add', 'Microsoft.VisualStudio.Component.VC.ATLMFC',              # MFC library support
        # '--add', 'Microsoft.VisualStudio.Component.VC.CLI.Support'          # C++/CLI support
        
        
        # .NET
        '--add','Microsoft.NetCore.Component.SDK',                            # .NET SDK (dotnet tools)
        '--add','Microsoft.VisualStudio.Component.NuGet.BuildTools'           # NuGet Package Manager / restore tools
        # '--add', 'Microsoft.VisualStudio.Component.Roslyn.Compiler',        # C#/VB managed compiler
        # '--add', 'Microsoft.VisualStudio.Component.Roslyn.LanguageServices' # C#/VB language services

    )

    Write-Host "Starte Installation der Visual Studio Build Tools ..."
    try {
        $proc = Start-Process -FilePath $installer -ArgumentList $args -Wait -NoNewWindow -PassThru
    }
    catch {
        Write-Host "Start-Process Exception: $($_.Exception.Message)"
        Dump-InstallerLogs -TempDir $TempDir
        throw
    }

    Write-Host "Installer ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Host 'Installation ist fehlgeschlagen — gebe Logs aus:'
        Dump-InstallerLogs -TempDir $TempDir
        throw "Build Tools Setup fehlgeschlagen (ExitCode $($proc.ExitCode))."
    }

    if ($proc.ExitCode -eq 3010) {
        Write-Warning 'Installation abgeschlossen. Ein Neustart ist erforderlich (ExitCode 3010).'
    } else {
        Write-Host 'Installation erfolgreich.'
    }

    if (Test-Path 'C:\Program Files\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat') {
        Write-Host 'VsDevCmd gefunden.'
    } elseif (Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat') {
        Write-Host 'VsDevCmd (x86) gefunden Pfad anpassen.'
    } else {
        Write-Host 'VsDevCmd nicht gefunden — gebe Logs aus.'
        Dump-InstallerLogs -TempDir $TempDir
        throw 'VS Build Tools nicht installiert Prüfe dd_bootstrapper*.log und dd_setup_*.log unter %TEMP%.'
    }
}
finally {
    # Clean up any lingering VS installer processes
    Get-Process -Name '*vs_installer*', '*vs_buildtools*', '*vs_setup*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'Cleaned up lingering VS installer processes'

    # Wenn im Fehlerfall noch der Installer existiert, lasse ihn zur Analyse bestehen.
    if ($proc -and ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010)) {
    Write-Host "Installer wurde nicht gelöscht (zur Fehleranalyse bleibt $installer bestehen)."
    }
}
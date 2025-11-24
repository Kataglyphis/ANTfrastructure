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
    Invoke-WebRequest -Uri 'https://aka.ms/vs/stable/vs_buildtools.exe' -OutFile $installer

    $args = @(
        '--quiet',
        '--wait','--norestart','--nocache',
        '--add','Microsoft.VisualStudio.Workload.AzureBuildTools',
        '--add','Microsoft.Component.MSBuild',
        '--add','Microsoft.VisualStudio.Component.CoreBuildTools',
        '--add','Microsoft.VisualStudio.Component.Roslyn.Compiler',
        '--add','Microsoft.VisualStudio.Component.Roslyn.LanguageServices',
        '--add','Microsoft.VisualStudio.Component.TextTemplating',
        '--add','Microsoft.VisualStudio.Component.VC.ASAN',
        '--add','Microsoft.VisualStudio.Component.VC.ATL',
        '--add','Microsoft.VisualStudio.Component.VC.ATLMFC',
        '--add','Microsoft.VisualStudio.Component.VC.CLI.Support',
        '--add','Microsoft.VisualStudio.Component.VC.CMake.Project',
        '--add','Microsoft.VisualStudio.Component.VC.CoreBuildTools',
        '--add','Microsoft.VisualStudio.Component.VC.CoreIde',
        '--add','Microsoft.VisualStudio.Component.VC.Redist.14.Latest',
        '--add','Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add','Microsoft.VisualStudio.Component.Windows11SDK.22621',
        '--add','Microsoft.VisualStudio.Component.Windows11SDK.26100',
        '--add','Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core',
        '--add','Microsoft.VisualStudio.Component.Llvm.ClangToolset',
        '--add','Microsoft.VisualStudio.Component.VC.Llvm.Clang',
        '--add','Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',
        '--add','Microsoft.VisualStudio.Workload.MSBuildTools',
        '--add','Microsoft.VisualStudio.Workload.UniversalBuildTools',
        '--add','Microsoft.VisualStudio.Workload.VCTools',
        '--add','Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools'
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
    # Wenn im Fehlerfall noch der Installer existiert, lasse ihn zur Analyse bestehen.
    if ($proc -and ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010)) {
    Write-Host "Installer wurde nicht gelöscht (zur Fehleranalyse bleibt $installer bestehen)."
    }
}
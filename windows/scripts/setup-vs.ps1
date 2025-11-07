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

# TLS 1.2 sicherstellen (für Downloads)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Temp-Verzeichnis vorbereiten

New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$installer = Join-Path $TempDir 'vs_buildtools.exe'

# Optionale ENV-Variablen analog Dockerfile

try {
    Write-Host 'Lade Visual Studio Build Tools Installer...'
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $installer

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
        '--add','Microsoft.VisualStudio.Component.Windows10SDK',
        '--add','Microsoft.VisualStudio.Component.Windows11SDK.26100',
        '--add','Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core',
        '--add','Microsoft.VisualStudio.Component.Llvm.ClangToolset',
        '--add','Microsoft.VisualStudio.Workload.MSBuildTools',
        '--add','Microsoft.VisualStudio.Workload.UniversalBuildTools',
        '--add','Microsoft.VisualStudio.Workload.VCTools',
        '--add','Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
        '--remove','Microsoft.VisualStudio.Component.Windows10SDK.10240',
        '--remove','Microsoft.VisualStudio.Component.Windows10SDK.10586',
        '--remove','Microsoft.VisualStudio.Component.Windows10SDK.14393',
        '--remove','Microsoft.VisualStudio.Component.Windows81SDK'
    )

    Write-Host "Starte Installation der Visual Studio Build Tools ..."
    $proc = Start-Process -FilePath $installer -ArgumentList $args -Wait -NoNewWindow -PassThru

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "Build Tools Setup fehlgeschlagen (ExitCode $($proc.ExitCode))."
    }

    if ($proc.ExitCode -eq 3010) {
        Write-Warning 'Installation abgeschlossen. Ein Neustart ist erforderlich (ExitCode 3010).'
    } else {
        Write-Host 'Installation erfolgreich.'
    }

    if (Test-Path 'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat') {
      Write-Host 'VsDevCmd gefunden.'
    } elseif (Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat') {
      Write-Host 'VsDevCmd (x86) gefunden – Pfad anpassen.'
    } else {
      Get-ChildItem $env:TEMP -Filter 'dd_*' -ErrorAction SilentlyContinue |% { $_.FullName }
      throw 'VS Build Tools nicht installiert – Prüfe dd_bootstrapper*.log und dd_setup_*.log unter %TEMP%.'
    }
}
finally {
    if (Test-Path $installer) { Remove-Item $installer -Force }
}
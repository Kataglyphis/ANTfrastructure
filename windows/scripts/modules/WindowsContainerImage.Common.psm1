Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Resolve-ContainerImageValue {
    param(
        [AllowEmptyString()]
        [string]$Value = '',
        [string]$EnvironmentVariable = '',
        [AllowEmptyString()]
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            return $environmentValue
        }
    }

    return $DefaultValue
}

function Initialize-ContainerImageTempDirectory {
    param(
        [string]$TempDir = 'C:\temp'
    )

    return (Resolve-DirectoryPath -Path $TempDir)
}

function Resolve-ContainerDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-DirectoryPath -Path $Path)
}

function Resolve-ContainerNormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-NormalizedPath -Path $Path)
}

function Assert-ContainerPathExists {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = $Path,

        [ValidateSet('Any', 'Leaf', 'Container')]
        [string]$PathType = 'Any'
    )

    $pathExists = switch ($PathType) {
        'Leaf' { Test-Path -LiteralPath $Path -PathType Leaf }
        'Container' { Test-Path -LiteralPath $Path -PathType Container }
        default { Test-Path -LiteralPath $Path }
    }

    if (-not $pathExists) {
        throw "${Description} not found at ${Path}"
    }

    return $Path
}

function Assert-ContainerCommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command not found on PATH: $Name"
    }

    return $command.Source
}

Export-ModuleMember -Function @(
    'Resolve-ContainerImageValue',
    'Initialize-ContainerImageTempDirectory',
    'Resolve-ContainerDirectoryPath',
    'Resolve-ContainerNormalizedPath',
    'Assert-ContainerPathExists',
    'Assert-ContainerCommandAvailable'
)

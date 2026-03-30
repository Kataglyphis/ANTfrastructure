Set-StrictMode -Version Latest

function Resolve-DirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -Path $Path).Path
}

function Resolve-WorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        return (Resolve-Path -Path $Path -ErrorAction Stop).Path
    } catch {
        Write-Host "Workspace path doesn't exist, creating: $Path"
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        return (Resolve-Path -Path $Path -ErrorAction Stop).Path
    }
}

function New-Timestamp {
    param(
        [string]$Format = 'yyyyMMdd-HHmmss'
    )

    return (Get-Date).ToString($Format)
}

function New-TimestampedFilePath {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$Prefix,
        [Parameter(Mandatory)]
        [string]$Suffix,
        [string]$TimestampFormat = 'yyyyMMdd-HHmmss'
    )

    $resolvedDirectory = Resolve-DirectoryPath -Path $Directory
    $timestamp = New-Timestamp -Format $TimestampFormat
    return (Join-Path $resolvedDirectory "$Prefix-$timestamp$Suffix")
}

function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $sanitizedRelative = $RelativePath -replace '/', '\\'
    $combinedPath = Join-Path $BasePath $sanitizedRelative
    return [System.IO.Path]::GetFullPath($combinedPath)
}

function ConvertTo-ParameterList {
    param(
        [object]$Value
    )

    # Return a flat array of objects suitable for Start-Process -ArgumentList.
    # Previously the function used a leading comma which wrapped arrays inside
    # another array (producing nested arrays like [object[]] inside an array),
    # causing callers to get a single element that was itself an array. That
    # resulted in incorrect argument passing to external processes and
    # unexpected parsing of parameters (notably passwords containing special
    # characters). Return a plain object[] in all cases.

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        # Ensure we return a flat array of strings. Start-Process -ArgumentList
        # expects string[]; returning object[] or nested arrays can cause
        # incorrect argument passing (notably when passwords contain special
        # characters such as ; | : /). Coerce every element to string.
        return @($Value | ForEach-Object { [string]$_ })
    }

    return @([string]$Value)
}

Export-ModuleMember -Function @(
    'Resolve-DirectoryPath',
    'Resolve-WorkspacePath',
    'New-Timestamp',
    'New-TimestampedFilePath',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList'
)

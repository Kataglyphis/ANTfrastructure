# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
#requires -Version 7.0

Set-StrictMode -Version Latest

$script:AdminRefusal = 'Installation and administrative privileges required!'

function Get-RustDeskExe {
    <# .SYNOPSIS The installed rustdesk.exe; the portable build refuses every CLI call below. #>
    param([string]$InstallDir = (Join-Path $env:ProgramFiles 'RustDesk'))
    $exe = Join-Path $InstallDir 'rustdesk.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "rustdesk.exe not found at $exe (run Install-RustDesk.ps1)" }
    return $exe
}

function Get-RustDeskConfigDir {
    <# .SYNOPSIS The service's config directory and the desktop user's copy. #>
    return [pscustomobject]@{
        Service = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
        User    = Join-Path $env:APPDATA 'RustDesk\config'
    }
}

function Invoke-RustDeskCli {
    <# .SYNOPSIS Runs one rustdesk.exe CLI call and returns its trimmed output. #>
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$ArgumentList)
    # A GUI-subsystem exe is only waited for, and only prints, when its output is piped.
    $output = (& $Exe @ArgumentList 2>&1 | Out-String).Trim()
    if ($output -eq $script:AdminRefusal) { throw "rustdesk.exe $($ArgumentList[0]): $output" }
    return $output
}

function Get-RustDeskOption {
    <# .SYNOPSIS Reads one option from the service's config; an unset option reads empty. #>
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Name)
    return Invoke-RustDeskCli -Exe $Exe -ArgumentList @('--option', $Name)
}

function Set-RustDeskOption {
    <# .SYNOPSIS Sets one option and fails unless the service reads the new value back. #>
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $null = Invoke-RustDeskCli -Exe $Exe -ArgumentList @('--option', $Name, $Value)
    $actual = Get-RustDeskOption -Exe $Exe -Name $Name
    if ($actual -ne $Value) { throw "RustDesk option '$Name' reads '$actual' after setting '$Value'" }
}

function Set-RustDeskPermanentPassword {
    <# .SYNOPSIS Sets the permanent password; only the CLI's 'Done!' counts as success. #>
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][securestring]$Password)
    $plain = [Net.NetworkCredential]::new('', $Password).Password
    if ([string]::IsNullOrEmpty($plain)) { throw 'The RustDesk password must not be empty' }
    # The CLI takes the password as an argument, so it is in the process list while the call runs.
    $output = Invoke-RustDeskCli -Exe $Exe -ArgumentList @('--password', $plain)
    if ($output -ne 'Done!') { throw "rustdesk.exe --password did not confirm: $($output.Replace($plain, '***'))" }
}

function Test-RustDeskSessionOpen {
    <# .SYNOPSIS True while a remote session is open, i.e. a connection manager (--cm) runs. #>
    param([object[]]$Process = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'"))
    return [bool](@($Process | Where-Object { "$($_.CommandLine)" -match '\s--cm(\s|-|$)' }).Count)
}

function Test-RustDeskListening {
    <# .SYNOPSIS True when a RustDesk process, not another program, listens on the TCP port. #>
    param([Parameter(Mandatory)][int]$Port)
    foreach ($listener in @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)) {
        $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($owner -and $owner.ProcessName -eq 'RustDesk') { return $true }
    }
    return $false
}

function Wait-RustDeskListener {
    <# .SYNOPSIS Polls Test-RustDeskListening until it holds or the timeout passes. #>
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-RustDeskListening -Port $Port) { return $true }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Backup-RustDeskConfig {
    <# .SYNOPSIS Copies the service and user config directories that exist; returns the names copied. #>
    param([Parameter(Mandatory)][string]$Destination, [object]$ConfigDir = (Get-RustDeskConfigDir))
    $copied = [Collections.Generic.List[string]]::new()
    foreach ($name in 'Service', 'User') {
        $source = $ConfigDir.$name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $target = Join-Path $Destination $name.ToLowerInvariant()
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
        $copied.Add($name.ToLowerInvariant())
    }
    return @($copied)
}

function Get-RustDeskLanAddress {
    <# .SYNOPSIS The IPv4 addresses on connected interfaces with a default gateway, the ones a LAN client can reach. #>
    return @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object { $_.IPv4Address.IPAddress })
}

Export-ModuleMember -Function 'Get-RustDeskExe', 'Get-RustDeskConfigDir', 'Invoke-RustDeskCli', 'Get-RustDeskOption',
    'Set-RustDeskOption', 'Set-RustDeskPermanentPassword', 'Test-RustDeskSessionOpen', 'Test-RustDeskListening',
    'Wait-RustDeskListener', 'Backup-RustDeskConfig', 'Get-RustDeskLanAddress'

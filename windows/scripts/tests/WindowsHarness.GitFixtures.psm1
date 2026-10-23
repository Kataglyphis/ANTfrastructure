#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -DisableNameChecking -ErrorAction Stop

function Invoke-TestGitCommand {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$ArgumentList)
    $output = @(& git -C $Path @ArgumentList 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Fixture git $($ArgumentList -join ' ') failed with exit ${code}: $($output -join [Environment]::NewLine)" }
    $output
}

function Set-TestGitIdentity {
    param([Parameter(Mandatory)][string]$Path, [string]$UserName = 'Fixture', [string]$UserEmail = 'fixture@example.invalid')
    $null = Invoke-TestGitCommand -Path $Path -ArgumentList @('config', '--local', 'user.email', $UserEmail)
    $null = Invoke-TestGitCommand -Path $Path -ArgumentList @('config', '--local', 'user.name', $UserName)
}

function New-TestGitRepository {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$InitialBranch = 'main',
        [string]$UserName = 'Fixture', [string]$UserEmail = 'fixture@example.invalid')
    $root = [IO.Directory]::CreateDirectory($Path).FullName
    $arguments = @('init', '--quiet')
    if ($InitialBranch) { $arguments += "--initial-branch=$InitialBranch" }
    $null = Invoke-TestGitCommand -Path $root -ArgumentList $arguments
    Set-TestGitIdentity -Path $root -UserName $UserName -UserEmail $UserEmail
    return $root
}

function Add-TestGitCommit {
    param([Parameter(Mandatory)][string]$Path, [Collections.IDictionary]$Files = @{}, [string]$Message = 'fixture')
    Write-TestFileTree -Root $Path -Files $Files
    $null = Invoke-TestGitCommand -Path $Path -ArgumentList @('add', '-A')
    $null = Invoke-TestGitCommand -Path $Path -ArgumentList @('commit', '--quiet', '-m', $Message)
}

Export-ModuleMember -Function Invoke-TestGitCommand, Set-TestGitIdentity, New-TestGitRepository, Add-TestGitCommit

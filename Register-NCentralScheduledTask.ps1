#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Registers an hourly Windows Scheduled Task that runs the N-central
    Maintenance Window Sync script.

.DESCRIPTION
    Creates a task under \NCentral\ named "MaintenanceWindowSync" that:
      - Runs every hour, starting 5 minutes after registration.
      - Executes under the SYSTEM account (no interactive login needed).
      - Logs output to %ProgramData%\NCentralSync\TaskOutput.log.
    Run this script once from an elevated PowerShell prompt.

.PARAMETER ScriptPath
    Full path to NCentral-MaintenanceWindowSync.ps1.
    Defaults to the folder containing this registration script.

.PARAMETER RunAsUser
    The user account the task will run under.
    Defaults to 'SYSTEM'. To use a specific service account supply
    'DOMAIN\svc-ncentral' — you will be prompted for the password.

.EXAMPLE
    .\Register-NCentralScheduledTask.ps1
    .\Register-NCentralScheduledTask.ps1 -RunAsUser 'CPFLEXPACK\svc-ncentral'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'NCentral-MaintenanceWindowSync.ps1'),
    [string]$RunAsUser  = 'SYSTEM',
    [string]$TaskFolder = '\NCentral\',
    [string]$TaskName   = 'MaintenanceWindowSync'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}

$logDir = "$env:ProgramData\NCentralSync"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host "Created log directory: $logDir"
}

# Build the action — PowerShell with bypass so no signing is required on
# a managed workstation. Remove -ExecutionPolicy Bypass if your GPO permits.
$psExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$argStr = "-NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" >> `"$logDir\TaskOutput.log`" 2>&1"

$action  = New-ScheduledTaskAction -Execute $psExe -Argument $argStr

# Trigger: hourly, indefinitely, starting 5 minutes from now
$startAt = (Get-Date).AddMinutes(5)
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Hours 1) `
               -Once -At $startAt -RepetitionDuration ([TimeSpan]::MaxValue)

# Principal
if ($RunAsUser -eq 'SYSTEM') {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $cred      = Get-Credential -UserName $RunAsUser -Message "Password for scheduled task account"
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Password -RunLevel Highest
}

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit  (New-TimeSpan -Hours 1) `
    -MultipleInstances   IgnoreNew `
    -RestartCount        3 `
    -RestartInterval     (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description "Hourly N-central maintenance window sync → Excel → SharePoint"

# Register (replace if already exists)
$existingTask = Get-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Replacing existing task '$TaskFolder$TaskName'…"
    Unregister-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -Confirm:$false
}

if ($RunAsUser -eq 'SYSTEM') {
    Register-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -InputObject $task | Out-Null
} else {
    Register-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -InputObject $task `
        -User $RunAsUser -Password $cred.GetNetworkCredential().Password | Out-Null
}

Write-Host "Scheduled task registered: $TaskFolder$TaskName"
Write-Host "  Script  : $ScriptPath"
Write-Host "  Account : $RunAsUser"
Write-Host "  Schedule: Every 1 hour, starting $($startAt.ToString('yyyy-MM-dd HH:mm'))"
Write-Host "  Log     : $logDir\TaskOutput.log"
Write-Host ""
Write-Host "To run immediately:"
Write-Host "  Start-ScheduledTask -TaskPath '$TaskFolder' -TaskName '$TaskName'"

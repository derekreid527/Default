#Requires -Version 5.1

<#
.SYNOPSIS
    Installs all PowerShell modules required by the N-central Maintenance Window Sync.

.DESCRIPTION
    Installs (or updates) ImportExcel and PnP.PowerShell for the current user,
    then verifies each module loads correctly.  Run this once before first use.
    An internet connection to the PowerShell Gallery is required.

.NOTES
    PnP.PowerShell requires .NET 4.7.2+ on Windows PowerShell 5.1.
    If you are behind a proxy, set:
        [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    before running this script.
#>

[CmdletBinding()]
param(
    [switch]$Force   # Re-install even if module is already present
)

$ErrorActionPreference = 'Stop'

$modules = @(
    @{ Name='ImportExcel';    MinVersion='7.8.0' },
    @{ Name='PnP.PowerShell'; MinVersion='2.3.0' }
)

# Ensure PSGallery is trusted so installs don't prompt
$galleryPolicy = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if ($galleryPolicy -and $galleryPolicy.InstallationPolicy -ne 'Trusted') {
    Write-Host "Trusting PSGallery repository…"
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

foreach ($m in $modules) {
    $name       = $m.Name
    $minVersion = [version]$m.MinVersion

    $installed = Get-Module -Name $name -ListAvailable |
                    Sort-Object Version -Descending |
                    Select-Object -First 1

    if ($installed -and $installed.Version -ge $minVersion -and -not $Force) {
        Write-Host "[OK]  $name $($installed.Version) already installed." -ForegroundColor Green
        continue
    }

    Write-Host "Installing $name (>= $minVersion)…" -ForegroundColor Yellow
    try {
        Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        $new = Get-Module -Name $name -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        Write-Host "[OK]  $name $($new.Version) installed." -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $name installation failed: $_" -ForegroundColor Red
    }
}

# Verify modules load
Write-Host "`nVerifying modules load correctly…"
foreach ($m in $modules) {
    try {
        Import-Module $m.Name -ErrorAction Stop
        Write-Host "[OK]  $($m.Name) loaded." -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] $($m.Name) failed to load: $_" -ForegroundColor Red
    }
}

Write-Host "`nDone. Next steps:"
Write-Host "  1. Store your N-central JWT token in Credential Manager:"
Write-Host "       cmdkey /generic:NCentralAPI /user:svc-ncentral /pass:<your-jwt-token>"
Write-Host "  2. Test API endpoints:"
Write-Host "       .\Test-NCentralEndpoints.ps1"
Write-Host "  3. Run the sync manually (skip SharePoint to verify Excel output first):"
Write-Host "       .\NCentral-MaintenanceWindowSync.ps1 -SkipSharePointUpload -VerboseLog"
Write-Host "  4. Register the hourly scheduled task (run as admin):"
Write-Host "       .\Register-NCentralScheduledTask.ps1"

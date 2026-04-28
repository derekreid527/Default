#Requires -Version 5.1

<#
.SYNOPSIS
    Probes the N-central REST API to discover which endpoints are live and what
    data they return. Run this interactively before the first scheduled execution
    to confirm correct endpoint mappings for your N-central version.

.DESCRIPTION
    The script:
      1. Reads the JWT token from Windows Credential Manager (target: NCentralAPI).
      2. Attempts every known endpoint pattern for org units, scheduled tasks,
         device groups, and patch approval rules.
      3. Prints a colour-coded summary: green = success, red = failure.
      4. Dumps the first item of each successful response so you can inspect
         field names and map them to the Excel schema.
      5. Saves a full report to NCentralEndpointProbe.json in the current folder.

.EXAMPLE
    .\Test-NCentralEndpoints.ps1
    .\Test-NCentralEndpoints.ps1 -NCentralBaseUrl 'https://ncod157.n-able.com' -SampleOrgUnitId 123
#>

[CmdletBinding()]
param(
    [string]$NCentralBaseUrl   = 'https://ncod157.n-able.com',
    [string]$CredentialTarget  = 'NCentralAPI',
    [string]$ReportPath        = '.\NCentralEndpointProbe.json',
    # Optionally supply a known org unit / customer ID to skip the auto-discovery step.
    [string]$SampleOrgUnitId   = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'   # We handle errors manually here

###############################################################################
# Helpers
###############################################################################

function Write-Result {
    param([bool]$Success, [string]$Label, [string]$Detail = '')
    $color  = if ($Success) { 'Green' } else { 'Red' }
    $symbol = if ($Success) { '[OK]  ' } else { '[FAIL]' }
    Write-Host "$symbol $Label" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

function Get-CredentialManagerSecret {
    param([string]$Target)
    if (-not ([System.Management.Automation.PSTypeName]'CredManagerProbe').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CredManagerProbe {
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredRead(string target, uint type, uint reserved, out IntPtr credPtr);
    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob;
        public uint Persist; public uint AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string[] Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr))
            throw new Exception("Credential '" + target + "' not found.");
        try {
            var c = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            string pw = c.CredentialBlobSize > 0
                ? Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2)
                : string.Empty;
            return new string[] { c.UserName ?? string.Empty, pw };
        } finally { CredFree(ptr); }
    }
}
'@ -ErrorAction Stop
    }
    $p = [CredManagerProbe]::Read($Target)
    return [PSCustomObject]@{ Username = $p[0]; Password = $p[1] }
}

function Invoke-Probe {
    param([string]$Uri, [string]$Token)
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    try {
        $resp = Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get `
                    -TimeoutSec 20 -ErrorAction Stop
        return [PSCustomObject]@{ Success=$true; StatusCode=200; Body=$resp; Error=$null }
    } catch {
        $code = $_.Exception.Response?.StatusCode?.value__ ?? 0
        return [PSCustomObject]@{ Success=$false; StatusCode=$code; Body=$null; Error=$_.Exception.Message }
    }
}

function Show-SampleFields {
    param($Body)
    # Extract the first data item and show its field names
    $item = $null
    if ($null -ne $Body.data -and $Body.data.Count -gt 0) {
        $item = $Body.data[0]
    } elseif ($Body -is [array] -and $Body.Count -gt 0) {
        $item = $Body[0]
    } elseif ($Body -isnot [array]) {
        $item = $Body
    }
    if ($null -eq $item) { return "(empty response)" }

    $fields = $item.PSObject.Properties.Name
    $preview = $item | ConvertTo-Json -Depth 2 -Compress
    return "Fields: $($fields -join ', ')  |  First item: $($preview.Substring(0, [Math]::Min(200, $preview.Length)))…"
}

###############################################################################
# Main probe logic
###############################################################################

Write-Host "`nN-central API Endpoint Discovery" -ForegroundColor Cyan
Write-Host "Base URL : $NCentralBaseUrl" -ForegroundColor Cyan
Write-Host "Target   : $CredentialTarget`n" -ForegroundColor Cyan

$report = [ordered]@{ BaseUrl=$NCentralBaseUrl; Timestamp=(Get-Date -Format 'o'); Results=@() }

# 1. Retrieve token
try {
    $cred  = Get-CredentialManagerSecret -Target $CredentialTarget
    $token = $cred.Password
    Write-Result -Success $true -Label "Credential Manager read" -Detail "User: $($cred.Username), Token length: $($token.Length)"
} catch {
    Write-Result -Success $false -Label "Credential Manager read" -Detail $_
    Write-Host "`nCannot continue without a valid token. Store one with:" -ForegroundColor Yellow
    Write-Host "  cmdkey /generic:$CredentialTarget /user:svc-ncentral /pass:<jwt-token>`n"
    exit 1
}

$base = $NCentralBaseUrl.TrimEnd('/')

# 2. Swagger / OpenAPI discovery (informational)
Write-Host "`n--- Swagger / API discovery ---" -ForegroundColor Yellow
foreach ($swaggerPath in @('/swagger/index.html', '/swagger/v1/swagger.json', '/api', '/api/swagger')) {
    $uri  = "$base$swaggerPath"
    $res  = Invoke-Probe -Uri $uri -Token $token
    Write-Result -Success $res.Success -Label $uri -Detail "HTTP $($res.StatusCode)"
    $report.Results += [ordered]@{ Category='Swagger'; Endpoint=$uri; Success=$res.Success; StatusCode=$res.StatusCode }
}

# 3. Org unit endpoints
Write-Host "`n--- Org Unit / Customer endpoints ---" -ForegroundColor Yellow
$orgEndpoints = @(
    '/api/org-units',
    '/api/org-units?pageNumber=1&pageSize=10',
    '/api/customers',
    '/api/service-orgs',
    '/api/v1/org-units'
)

$workingOrgEndpoint = $null
$firstOrgUnit       = $null

foreach ($ep in $orgEndpoints) {
    $uri = "$base$ep"
    $res = Invoke-Probe -Uri $uri -Token $token
    $detail = if ($res.Success) { Show-SampleFields -Body $res.Body } else { "HTTP $($res.StatusCode): $($res.Error)" }
    Write-Result -Success $res.Success -Label $ep -Detail $detail
    $report.Results += [ordered]@{ Category='OrgUnits'; Endpoint=$ep; Success=$res.Success; StatusCode=$res.StatusCode; SampleFields=$detail }

    if ($res.Success -and -not $workingOrgEndpoint) {
        $workingOrgEndpoint = $ep
        # Extract first org unit ID for downstream tests
        if ($null -ne $res.Body.data -and $res.Body.data.Count -gt 0) {
            $firstOrgUnit = $res.Body.data[0]
        } elseif ($res.Body -is [array] -and $res.Body.Count -gt 0) {
            $firstOrgUnit = $res.Body[0]
        }
    }
}

# Determine a sample org unit ID for per-unit endpoint probing
if ($SampleOrgUnitId) {
    $probeId = $SampleOrgUnitId
    Write-Host "`nUsing supplied sample org unit ID: $probeId" -ForegroundColor Cyan
} elseif ($firstOrgUnit) {
    $probeId = $firstOrgUnit.orgUnitId ?? $firstOrgUnit.customerId ?? $firstOrgUnit.id ?? ''
    $probeName = $firstOrgUnit.orgUnitName ?? $firstOrgUnit.name ?? $firstOrgUnit.customerName ?? '(unknown)'
    Write-Host "`nUsing first discovered org unit: '$probeName' (id=$probeId)" -ForegroundColor Cyan
} else {
    $probeId = '1'
    Write-Host "`nNo org unit found automatically; using placeholder id=1. Supply -SampleOrgUnitId for accurate results." -ForegroundColor Yellow
}

# 4. Scheduled task / maintenance window endpoints
Write-Host "`n--- Scheduled Task / Maintenance Window endpoints (id=$probeId) ---" -ForegroundColor Yellow
$taskEndpoints = @(
    "/api/org-units/$probeId/scheduled-tasks",
    "/api/org-units/$probeId/scheduled-tasks?pageNumber=1&pageSize=10",
    "/api/org-units/$probeId/maintenance-windows",
    "/api/customers/$probeId/scheduled-tasks",
    "/api/customers/$probeId/maintenance-windows",
    "/api/service-orgs/$probeId/scheduled-tasks",
    "/api/scheduled-tasks?orgUnitId=$probeId",
    "/api/maintenance-windows?orgUnitId=$probeId",
    "/api/v1/org-units/$probeId/scheduled-tasks"
)

foreach ($ep in $taskEndpoints) {
    $uri = "$base$ep"
    $res = Invoke-Probe -Uri $uri -Token $token
    $detail = if ($res.Success) { Show-SampleFields -Body $res.Body } else { "HTTP $($res.StatusCode): $($res.Error)" }
    Write-Result -Success $res.Success -Label $ep -Detail $detail
    $report.Results += [ordered]@{ Category='ScheduledTasks'; Endpoint=$ep; Success=$res.Success; StatusCode=$res.StatusCode; SampleFields=$detail }
}

# 5. Device group endpoints
Write-Host "`n--- Device Group endpoints (id=$probeId) ---" -ForegroundColor Yellow
$dgEndpoints = @(
    "/api/org-units/$probeId/device-groups",
    "/api/customers/$probeId/device-groups",
    "/api/device-groups?orgUnitId=$probeId",
    "/api/v1/org-units/$probeId/device-groups"
)

foreach ($ep in $dgEndpoints) {
    $uri = "$base$ep"
    $res = Invoke-Probe -Uri $uri -Token $token
    $detail = if ($res.Success) { Show-SampleFields -Body $res.Body } else { "HTTP $($res.StatusCode): $($res.Error)" }
    Write-Result -Success $res.Success -Label $ep -Detail $detail
    $report.Results += [ordered]@{ Category='DeviceGroups'; Endpoint=$ep; Success=$res.Success; StatusCode=$res.StatusCode; SampleFields=$detail }
}

# 6. Patch approval endpoints
Write-Host "`n--- Patch Approval Rule endpoints ---" -ForegroundColor Yellow
$patchEndpoints = @(
    '/api/patch-approval-policies',
    '/api/patch-management/approval-policies',
    '/api/patch-approvals',
    "/api/org-units/$probeId/patch-approval-policies",
    "/api/org-units/$probeId/patch-management/approval-policies",
    "/api/customers/$probeId/patch-approval-policies"
)

foreach ($ep in $patchEndpoints) {
    $uri = "$base$ep"
    $res = Invoke-Probe -Uri $uri -Token $token
    $detail = if ($res.Success) { Show-SampleFields -Body $res.Body } else { "HTTP $($res.StatusCode): $($res.Error)" }
    Write-Result -Success $res.Success -Label $ep -Detail $detail
    $report.Results += [ordered]@{ Category='PatchApproval'; Endpoint=$ep; Success=$res.Success; StatusCode=$res.StatusCode; SampleFields=$detail }
}

# 7. Save report
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
Write-Host "`nFull probe report saved: $ReportPath" -ForegroundColor Cyan

# 8. Summary
$successes = $report.Results | Where-Object { $_.Success }
$failures  = $report.Results | Where-Object { -not $_.Success }
Write-Host "`n===== Summary =====" -ForegroundColor Cyan
Write-Host "Working endpoints : $($successes.Count)" -ForegroundColor Green
Write-Host "Failed endpoints  : $($failures.Count)"  -ForegroundColor Red

if ($successes.Count -gt 0) {
    Write-Host "`nWorking endpoints to update in NCentral-MaintenanceWindowSync.ps1:" -ForegroundColor Yellow
    $successes | Group-Object Category | ForEach-Object {
        Write-Host "  [$($_.Name)]" -ForegroundColor White
        $_.Group | ForEach-Object { Write-Host "    $($_.Endpoint)" -ForegroundColor Green }
    }
}

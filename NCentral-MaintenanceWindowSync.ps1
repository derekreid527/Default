#Requires -Version 5.1

<#
.SYNOPSIS
    Syncs N-central maintenance window data to a formatted Excel report in SharePoint.
.DESCRIPTION
    1. Retrieves a JWT bearer token from Windows Credential Manager (target: NCentralAPI).
    2. Queries the N-central REST API for org units, device groups, maintenance windows,
       and patch approval rules across the configured sites.
    3. Builds NCentral_MaintenanceWindows.xlsx with per-site tabs, an All Sites tab,
       a Patch Approval Rules tab, and a Legend tab.
    4. Uploads the workbook to SharePoint via PnP.PowerShell.
    Designed to run hourly via Windows Task Scheduler.

.NOTES
    Prerequisites:
        Install-Module ImportExcel      -Scope CurrentUser -Force
        Install-Module PnP.PowerShell   -Scope CurrentUser -Force
    Store JWT token in Credential Manager:
        cmdkey /generic:NCentralAPI /user:svc-ncentral /pass:<jwt-token>
    Run the script interactively once to cache SharePoint credentials before
    scheduling it.
#>

[CmdletBinding()]
param(
    [string]$NCentralBaseUrl     = 'https://ncod157.n-able.com',
    [string]$CredentialTarget    = 'NCentralAPI',
    [string]$OutputPath          = "$env:TEMP\NCentral_MaintenanceWindows.xlsx",
    [string]$SharePointUrl       = 'https://cpflexpack.sharepoint.com/sites/IT',
    [string]$SharePointFolder    = 'Security Governance/Audits/Patch Management',
    [string]$LogPath             = "$env:ProgramData\NCentralSync\NCentralSync.log",
    [switch]$SkipSharePointUpload,
    [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Site filter — script will pull data for org units whose names contain any
# of these tokens (case-insensitive). Adjust to match your exact org unit
# names in N-central.
# ---------------------------------------------------------------------------
$SiteTokens = @('CPA', 'CPBR', 'CPBU', 'CPL', 'CPN', 'CPX', 'CPY', 'FDL')

# ---------------------------------------------------------------------------
# Type → color mapping (EPPlus ARGB hex strings, no leading #)
# ---------------------------------------------------------------------------
$TypeColors = @{
    'Detection'    = 'FFFFFF00'   # Yellow
    'Installation' = 'FF92D050'   # Green
    'Pre-Download' = 'FFFFC000'   # Orange
    'Reboot'       = 'FF7030A0'   # Purple
}

# Excel column order
$ExcelColumns = @('Site', 'DeviceGroup', 'MaintenanceName', 'LastModifiedBy',
                  'LastModifiedTime', 'Type', 'Schedule')

$ColumnHeaders = @{
    Site             = 'Site'
    DeviceGroup      = 'Device Group'
    MaintenanceName  = 'Maintenance Window Name'
    LastModifiedBy   = 'Last Modified By'
    LastModifiedTime = 'Last Modified Time'
    Type             = 'Type'
    Schedule         = 'Schedule'
}

###############################################################################
# Logging
###############################################################################

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DEBUG')]$Level = 'INFO')
    if ($Level -eq 'DEBUG' -and -not $VerboseLog) { return }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"
    Write-Host $line
    try {
        $dir = Split-Path $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { <# non-fatal #> }
}

###############################################################################
# Windows Credential Manager
###############################################################################

function Get-CredentialManagerSecret {
    param([string]$Target)

    # Load the WinAPI inline type if not already loaded
    if (-not ([System.Management.Automation.PSTypeName]'CredManager').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CredManager {
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredRead(string target, uint type, uint reserved, out IntPtr credPtr);

    [DllImport("advapi32.dll", SetLastError=true)]
    private static extern void CredFree(IntPtr cred);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct CREDENTIAL {
        public uint  Flags;
        public uint  Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint  CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint  Persist;
        public uint  AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string[] Read(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr))
            throw new Exception("Credential '" + target + "' not found in Windows Credential Manager. " +
                                "Run: cmdkey /generic:" + target + " /user:<user> /pass:<jwt-token>");
        try {
            var c = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            string password = c.CredentialBlobSize > 0
                ? Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2)
                : string.Empty;
            return new string[] { c.UserName ?? string.Empty, password };
        } finally {
            CredFree(ptr);
        }
    }
}
'@ -ErrorAction Stop
    }

    $parts = [CredManager]::Read($Target)
    return [PSCustomObject]@{ Username = $parts[0]; Password = $parts[1] }
}

###############################################################################
# N-central REST API helpers
###############################################################################

function Invoke-NCentralAPI {
    param(
        [string]$Endpoint,
        [string]$Token,
        [hashtable]$Query = @{}
    )

    $uri = $NCentralBaseUrl.TrimEnd('/') + '/' + $Endpoint.TrimStart('/')

    $qstring = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&'
    if ($qstring) { $uri += "?$qstring" }

    $headers = @{
        Authorization  = "Bearer $Token"
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }

    Write-Log "GET $uri" -Level DEBUG

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        return $response
    } catch {
        $statusCode = $_.Exception.Response?.StatusCode?.value__ ?? 'N/A'
        Write-Log "API call failed [$statusCode]: $uri — $($_.Exception.Message)" -Level WARN
        throw
    }
}

function Get-NCentralPagedData {
    <#
        Iterates through paginated N-central API responses.
        Handles both { data: [], pageDetails: {} } and bare array responses.
    #>
    param(
        [string]$Endpoint,
        [string]$Token,
        [hashtable]$ExtraQuery = @{},
        [int]$PageSize = 100
    )

    $allItems = [System.Collections.Generic.List[object]]::new()
    $pageNum  = 1

    do {
        $query = @{ pageNumber = "$pageNum"; pageSize = "$PageSize" } + $ExtraQuery
        try {
            $resp = Invoke-NCentralAPI -Endpoint $Endpoint -Token $Token -Query $query
        } catch {
            Write-Log "Paged fetch failed on page $pageNum of $Endpoint" -Level WARN
            break
        }

        # Support both wrapped { data } and bare array responses
        if ($null -ne $resp.data) {
            $items = $resp.data
            $total = $resp.pageDetails?.totalPages ?? 1
        } elseif ($resp -is [array]) {
            $items = $resp
            $total = 1
        } else {
            $items = @($resp)
            $total = 1
        }

        foreach ($item in $items) { $allItems.Add($item) }

        Write-Log "  Page $pageNum/$total — fetched $($items.Count) items from $Endpoint" -Level DEBUG
        $pageNum++
    } while ($pageNum -le $total)

    return $allItems
}

###############################################################################
# N-central data retrieval
###############################################################################

function Get-OrgUnits {
    param([string]$Token)

    Write-Log "Fetching org units…"
    $units = Get-NCentralPagedData -Endpoint '/api/org-units' -Token $Token
    Write-Log "  Found $($units.Count) org units total."
    return $units
}

function Get-SiteOrgUnits {
    param([object[]]$AllUnits)

    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($unit in $AllUnits) {
        $name = ($unit.orgUnitName ?? $unit.name ?? $unit.customerName ?? '') -as [string]
        foreach ($token in $SiteTokens) {
            if ($name -and $name.ToUpper().Contains($token.ToUpper())) {
                $matched.Add([PSCustomObject]@{
                    Id   = $unit.orgUnitId ?? $unit.customerId ?? $unit.id
                    Name = $name
                    Type = $unit.orgUnitType ?? $unit.type ?? 'Unknown'
                })
                break
            }
        }
    }
    Write-Log "Matched $($matched.Count) org units for configured sites."
    return $matched
}

function Get-MaintenanceWindowsForUnit {
    param([string]$Token, $Unit)

    $id = $Unit.Id
    Write-Log "Fetching maintenance windows for '$($Unit.Name)' (id=$id)…"

    # Try endpoint patterns in order — first success wins
    $endpointPatterns = @(
        "/api/org-units/$id/scheduled-tasks",
        "/api/customers/$id/scheduled-tasks",
        "/api/org-units/$id/maintenance-windows",
        "/api/customers/$id/maintenance-windows",
        "/api/scheduled-tasks?orgUnitId=$id"
    )

    $raw = $null
    foreach ($ep in $endpointPatterns) {
        try {
            $raw = Get-NCentralPagedData -Endpoint $ep -Token $Token
            Write-Log "  Endpoint succeeded: $ep (${$raw.Count} items)" -Level DEBUG
            break
        } catch {
            Write-Log "  Endpoint failed: $ep" -Level DEBUG
        }
    }

    if ($null -eq $raw) {
        Write-Log "  No working endpoint found for '$($Unit.Name)'" -Level WARN
        return @()
    }

    # Filter to maintenance-window type tasks only
    $mwItems = $raw | Where-Object {
        $t = ($_.taskType ?? $_.type ?? $_.scheduledTaskType ?? '') -as [string]
        -not $t -or $t -match 'Maintenance|Window|MW'
    }

    Write-Log "  $($mwItems.Count) maintenance window records for '$($Unit.Name)'."
    return $mwItems
}

function Get-DeviceGroupsForUnit {
    param([string]$Token, $Unit)

    $id = $Unit.Id
    $endpointPatterns = @(
        "/api/org-units/$id/device-groups",
        "/api/customers/$id/device-groups",
        "/api/device-groups?orgUnitId=$id"
    )

    foreach ($ep in $endpointPatterns) {
        try {
            $groups = Get-NCentralPagedData -Endpoint $ep -Token $Token
            Write-Log "  Device groups endpoint succeeded: $ep" -Level DEBUG
            # Build a lookup id→name
            $lookup = @{}
            foreach ($g in $groups) {
                $gid   = $g.deviceGroupId ?? $g.groupId ?? $g.id ?? ''
                $gname = $g.deviceGroupName ?? $g.groupName ?? $g.name ?? "Group-$gid"
                if ($gid) { $lookup["$gid"] = $gname }
            }
            return $lookup
        } catch {
            Write-Log "  Device group endpoint failed: $ep" -Level DEBUG
        }
    }
    return @{}
}

function Get-PatchApprovalRules {
    param([string]$Token, [object[]]$SiteUnits)

    Write-Log "Fetching patch approval rules…"
    $allRules = [System.Collections.Generic.List[PSCustomObject]]::new()

    $globalPatterns = @(
        '/api/patch-approval-policies',
        '/api/patch-management/approval-policies',
        '/api/patch-approvals'
    )

    foreach ($ep in $globalPatterns) {
        try {
            $rules = Get-NCentralPagedData -Endpoint $ep -Token $Token
            foreach ($r in $rules) { $allRules.Add($r) }
            Write-Log "  Global patch approval endpoint succeeded: $ep ($($rules.Count) rules)" -Level DEBUG
            break
        } catch {
            Write-Log "  Global patch approval endpoint failed: $ep" -Level DEBUG
        }
    }

    # Also try per-unit endpoints
    foreach ($unit in $SiteUnits) {
        $id = $unit.Id
        $unitPatterns = @(
            "/api/org-units/$id/patch-approval-policies",
            "/api/org-units/$id/patch-management/approval-policies",
            "/api/customers/$id/patch-approval-policies"
        )
        foreach ($ep in $unitPatterns) {
            try {
                $rules = Get-NCentralPagedData -Endpoint $ep -Token $Token
                foreach ($r in $rules) {
                    # Tag with site name if not already present
                    if (-not $r.PSObject.Properties['siteName']) {
                        $r | Add-Member -NotePropertyName 'siteName' -NotePropertyValue $unit.Name -Force
                    }
                    $allRules.Add($r)
                }
                Write-Log "  Per-unit patch approval succeeded: $ep ($($rules.Count) rules)" -Level DEBUG
                break
            } catch {
                Write-Log "  Per-unit patch approval failed: $ep" -Level DEBUG
            }
        }
    }

    Write-Log "Total patch approval rules fetched: $($allRules.Count)"
    return $allRules
}

###############################################################################
# Data normalization
###############################################################################

function ConvertTo-ScheduleString {
    param($Task)

    # Try to build a human-readable schedule from whatever fields exist
    $parts = [System.Collections.Generic.List[string]]::new()

    $freq     = $Task.scheduleType ?? $Task.frequency ?? $Task.recurrenceType ?? ''
    $day      = $Task.dayOfWeek    ?? $Task.scheduledDay ?? ''
    $start    = $Task.startTime    ?? $Task.scheduledTime ?? ''
    $duration = $Task.durationHours ?? $Task.duration ?? ''
    $dom      = $Task.dayOfMonth   ?? ''

    if ($freq)     { $parts.Add($freq) }
    if ($dom)      { $parts.Add("day $dom") }
    if ($day)      { $parts.Add("on $day") }
    if ($start)    { $parts.Add("at $start") }
    if ($duration) { $parts.Add("for $duration h") }

    if ($parts.Count -eq 0) {
        # Fallback: serialize whatever schedule sub-object exists
        $sched = $Task.schedule ?? $Task.scheduleDetails ?? $null
        if ($sched) {
            return ($sched | ConvertTo-Json -Compress -Depth 3)
        }
        return 'N/A'
    }

    return $parts -join ' '
}

function ConvertTo-MWType {
    param($Task)

    $raw = $Task.taskType ?? $Task.maintenanceType ?? $Task.type ?? $Task.scheduledTaskType ?? ''
    $raw = "$raw"

    if ($raw -match 'Detect')      { return 'Detection' }
    if ($raw -match 'Install')     { return 'Installation' }
    if ($raw -match 'Pre.?Down')   { return 'Pre-Download' }
    if ($raw -match 'Reboot|Boot') { return 'Reboot' }

    return if ($raw) { $raw } else { 'Unknown' }
}

function Build-MWRow {
    param($Task, [string]$SiteName, [hashtable]$DeviceGroupLookup)

    $dgId   = $Task.deviceGroupId ?? $Task.groupId ?? ''
    $dgName = if ($dgId -and $DeviceGroupLookup.ContainsKey("$dgId")) {
        $DeviceGroupLookup["$dgId"]
    } else {
        $Task.deviceGroupName ?? $Task.groupName ?? ($dgId ? "id:$dgId" : 'All Devices')
    }

    $modTime = $Task.lastModifiedTime ?? $Task.lastModified ?? $Task.modifiedDate ?? ''
    if ($modTime) {
        try { $modTime = ([datetime]$modTime).ToString('yyyy-MM-dd HH:mm') } catch {}
    }

    return [PSCustomObject]@{
        Site             = $SiteName
        DeviceGroup      = $dgName
        MaintenanceName  = $Task.taskName ?? $Task.name ?? $Task.maintenanceName ?? 'Unnamed'
        LastModifiedBy   = $Task.lastModifiedBy ?? $Task.modifiedBy ?? 'N/A'
        LastModifiedTime = $modTime
        Type             = ConvertTo-MWType -Task $Task
        Schedule         = ConvertTo-ScheduleString -Task $Task
    }
}

###############################################################################
# Excel report builder
###############################################################################

function New-ExcelReport {
    param(
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[PSCustomObject]]]$DataBySite,
        [object[]]$PatchApprovalRules,
        [string]$FilePath
    )

    if (Test-Path $FilePath) { Remove-Item $FilePath -Force }

    # -------------------------------------------------------------------------
    # Helper: write one site worksheet
    # -------------------------------------------------------------------------
    function Write-SiteSheet {
        param([string]$SheetName, [PSCustomObject[]]$Rows, [bool]$IsFirstSheet)

        if ($Rows.Count -eq 0) {
            $placeholder = [PSCustomObject]@{
                Site=''; DeviceGroup=''; MaintenanceName='No data found';
                LastModifiedBy=''; LastModifiedTime=''; Type=''; Schedule=''
            }
            $Rows = @($placeholder)
        }

        $excelParams = @{
            Path          = $FilePath
            WorksheetName = $SheetName
            AutoFilter    = $true
            AutoSize      = $true
            FreezeTopRow  = $true
            TableName     = "tbl_$($SheetName -replace '[^A-Za-z0-9]','')"
            TableStyle    = 'Medium2'
            Append        = (-not $IsFirstSheet)
            PassThru      = $true
        }

        $excel = $Rows | Select-Object @(
            @{N=$ColumnHeaders.Site;             E={$_.Site}},
            @{N=$ColumnHeaders.DeviceGroup;      E={$_.DeviceGroup}},
            @{N=$ColumnHeaders.MaintenanceName;  E={$_.MaintenanceName}},
            @{N=$ColumnHeaders.LastModifiedBy;   E={$_.LastModifiedBy}},
            @{N=$ColumnHeaders.LastModifiedTime; E={$_.LastModifiedTime}},
            @{N=$ColumnHeaders.Type;             E={$_.Type}},
            @{N=$ColumnHeaders.Schedule;         E={$_.Schedule}}
        ) | Export-Excel @excelParams

        # Apply Type column color coding via EPPlus
        $ws       = $excel.Workbook.Worksheets[$SheetName]
        $typeCol  = 6   # Column F (1-based): Type
        $lastRow  = $ws.Dimension?.End?.Row ?? 1

        for ($r = 2; $r -le $lastRow; $r++) {
            $cell     = $ws.Cells[$r, $typeCol]
            $typeVal  = "$($cell.Value)"
            $argb     = $TypeColors[$typeVal]
            if ($argb) {
                $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $cell.Style.Fill.BackgroundColor.SetColor(
                    [System.Drawing.ColorTranslator]::FromHtml("#$($argb.Substring(2))")
                )
            }
        }

        return $excel
    }

    # -------------------------------------------------------------------------
    # Per-site sheets
    # -------------------------------------------------------------------------
    Write-Log "Building Excel workbook: $FilePath"
    $excelPkg = $null
    $isFirst  = $true

    foreach ($site in $SiteTokens) {
        $rows = if ($DataBySite.ContainsKey($site)) { $DataBySite[$site].ToArray() } else { @() }
        Write-Log "  Writing sheet '$site' ($($rows.Count) rows)…"
        $excelPkg = Write-SiteSheet -SheetName $site -Rows $rows -IsFirstSheet $isFirst
        $isFirst  = $false
    }

    # -------------------------------------------------------------------------
    # All Sites sheet
    # -------------------------------------------------------------------------
    Write-Log "  Writing 'All Sites' sheet…"
    $allRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($list in $DataBySite.Values) { foreach ($r in $list) { $allRows.Add($r) } }
    $excelPkg = Write-SiteSheet -SheetName 'All Sites' -Rows $allRows.ToArray() -IsFirstSheet $false

    # -------------------------------------------------------------------------
    # Patch Approval Rules sheet
    # -------------------------------------------------------------------------
    Write-Log "  Writing 'Patch Approval Rules' sheet…"
    if ($PatchApprovalRules.Count -gt 0) {
        $excelPkg = $PatchApprovalRules | Export-Excel -Path $FilePath -WorksheetName 'Patch Approval Rules' `
            -AutoFilter -AutoSize -FreezeTopRow -TableStyle Medium2 -Append -PassThru
    } else {
        $placeholder = [PSCustomObject]@{ Note = 'No patch approval rules returned by API.' }
        $excelPkg = $placeholder | Export-Excel -Path $FilePath -WorksheetName 'Patch Approval Rules' `
            -AutoSize -Append -PassThru
    }

    # -------------------------------------------------------------------------
    # Legend sheet
    # -------------------------------------------------------------------------
    Write-Log "  Writing 'Legend' sheet…"
    $legendData = @(
        [PSCustomObject]@{ Type='Detection';    Color='Yellow';  Description='Detects available patches without installing them.' },
        [PSCustomObject]@{ Type='Installation'; Color='Green';   Description='Installs approved patches on target devices.' },
        [PSCustomObject]@{ Type='Pre-Download'; Color='Orange';  Description='Downloads patches in advance of the install window.' },
        [PSCustomObject]@{ Type='Reboot';       Color='Purple';  Description='Reboots devices after patch installation.' }
    )

    $excelPkg = $legendData | Export-Excel -Path $FilePath -WorksheetName 'Legend' `
        -AutoSize -FreezeTopRow -Append -PassThru

    $legendWs  = $excelPkg.Workbook.Worksheets['Legend']
    $colorMap  = @{ Yellow='FFFFFF00'; Green='FF92D050'; Orange='FFFFC000'; Purple='FF7030A0' }
    for ($r = 2; $r -le 5; $r++) {
        $colorName = "$($legendWs.Cells[$r, 2].Value)"
        $argb      = $colorMap[$colorName]
        if ($argb) {
            $c = $legendWs.Cells[$r, 1]
            $c.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $c.Style.Fill.BackgroundColor.SetColor(
                [System.Drawing.ColorTranslator]::FromHtml("#$($argb.Substring(2))")
            )
        }
    }

    # Reorder sheets: sites first, then All Sites, Patch Approval Rules, Legend
    $wb            = $excelPkg.Workbook
    $desiredOrder  = $SiteTokens + @('All Sites', 'Patch Approval Rules', 'Legend')
    $pos           = 1
    foreach ($name in $desiredOrder) {
        $ws = $wb.Worksheets[$name]
        if ($ws) { $wb.Worksheets.MoveToStart($name); }   # move to front iteratively
    }
    # Re-sort to correct position using index
    for ($i = 0; $i -lt $desiredOrder.Count; $i++) {
        $ws = $wb.Worksheets[$desiredOrder[$i]]
        if ($ws) {
            try { $wb.Worksheets.MoveBefore($desiredOrder[$i], $desiredOrder[$i+1]) } catch {}
        }
    }

    Close-ExcelPackage $excelPkg -Show:$false
    Write-Log "Excel workbook written: $FilePath"
}

###############################################################################
# SharePoint upload
###############################################################################

function Upload-ToSharePoint {
    param([string]$FilePath)

    Write-Log "Connecting to SharePoint: $SharePointUrl"
    try {
        Connect-PnPOnline -Url $SharePointUrl -Interactive -ErrorAction Stop
    } catch {
        Write-Log "SharePoint connection failed: $_" -Level ERROR
        throw
    }

    $fileName   = Split-Path $FilePath -Leaf
    $targetPath = "Shared Documents/$SharePointFolder/$fileName"

    Write-Log "Uploading '$fileName' to '$($SharePointFolder)'…"
    try {
        Add-PnPFile -Path $FilePath -Folder "Shared Documents/$SharePointFolder" -ErrorAction Stop | Out-Null
        Write-Log "Upload complete: $targetPath"
    } catch {
        Write-Log "Upload failed: $_" -Level ERROR
        throw
    }
}

###############################################################################
# Main
###############################################################################

try {
    Write-Log "===== N-central Maintenance Window Sync started ====="
    Write-Log "N-central URL : $NCentralBaseUrl"
    Write-Log "Output path   : $OutputPath"

    # 1. Get JWT token
    Write-Log "Retrieving JWT token from Credential Manager (target: $CredentialTarget)…"
    $cred  = Get-CredentialManagerSecret -Target $CredentialTarget
    $token = $cred.Password
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "JWT token is empty. Update the '$CredentialTarget' credential in Windows Credential Manager."
    }
    Write-Log "Token retrieved for user: $($cred.Username)"

    # 2. Fetch all org units and match to configured sites
    $allUnits  = Get-OrgUnits -Token $token
    $siteUnits = Get-SiteOrgUnits -AllUnits $allUnits

    if ($siteUnits.Count -eq 0) {
        Write-Log "No matching org units found for site tokens: $($SiteTokens -join ', ')" -Level WARN
        Write-Log "Available org unit names:" -Level WARN
        $allUnits | ForEach-Object {
            $n = $_.orgUnitName ?? $_.name ?? $_.customerName ?? '(no name)'
            Write-Log "  $n" -Level WARN
        }
    }

    # 3. Fetch maintenance windows and device groups per site
    $dataBySite = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[PSCustomObject]]]::new()
    foreach ($token2 in $SiteTokens) { $dataBySite[$token2] = [System.Collections.Generic.List[PSCustomObject]]::new() }

    foreach ($unit in $siteUnits) {
        $dgLookup = Get-DeviceGroupsForUnit -Token $token -Unit $unit
        $mwTasks  = Get-MaintenanceWindowsForUnit -Token $token -Unit $unit

        # Determine which site bucket this unit belongs to
        $bucket = $SiteTokens | Where-Object { $unit.Name.ToUpper().Contains($_.ToUpper()) } | Select-Object -First 1
        if (-not $bucket) { $bucket = $unit.Name }

        if (-not $dataBySite.ContainsKey($bucket)) {
            $dataBySite[$bucket] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }

        foreach ($task in $mwTasks) {
            $row = Build-MWRow -Task $task -SiteName $unit.Name -DeviceGroupLookup $dgLookup
            $dataBySite[$bucket].Add($row)
        }
    }

    # 4. Fetch patch approval rules
    $patchRules = Get-PatchApprovalRules -Token $token -SiteUnits $siteUnits

    # 5. Build Excel report
    New-ExcelReport -DataBySite $dataBySite -PatchApprovalRules $patchRules -FilePath $OutputPath

    # 6. Upload to SharePoint
    if (-not $SkipSharePointUpload) {
        Upload-ToSharePoint -FilePath $OutputPath
    } else {
        Write-Log "SharePoint upload skipped (-SkipSharePointUpload)."
    }

    Write-Log "===== Sync completed successfully ====="

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

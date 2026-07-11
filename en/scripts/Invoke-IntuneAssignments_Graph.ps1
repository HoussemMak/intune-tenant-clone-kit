#Requires -Version 7.0
<#
.SYNOPSIS
    ZERO-TOUCH migration of Intune ASSIGNMENTS (groups + assignments) SOURCE -> TARGET.
    Modern, 100% non-interactive port of the 3 legacy scripts:
      - Export-IntuneAssignmentsAndGroups_MSGraphLegacy.ps1
      - Import-IntuneGroups_MSGraphLegacy.ps1
      - Set-IntuneAssignments_MSGraphLegacy.ps1
    into a single script based on Microsoft.Graph.Authentication + Invoke-MgGraphRequest.

.DESCRIPTION
    Replaces the deprecated Microsoft.Graph.Intune module (interactive Connect-MSGraph) with an
    app-only CERTIFICATE connection identical to the rest of the kit (Connect-GraphForIntuneAutomation,
    INTUNE_AUTO_* environment variables). NO Read-Host, NO sign-in popup.

    Three phases, chainable via -Phase All:
      Export  (SOURCE, read-only)      -> assignments-map.json, groups-catalog.json,
                                           filters-catalog.json, manifest-assignments.json
      Groups  (TARGET, write)          -> recreates missing groups, writes groups-idmap.json
      Assign  (TARGET, write)          -> remaps by NAME (groups + filters) and POST .../{id}/assign

    PREVIEW by default: without -Execute, no writes (groups/assignments are only
    simulated and logged). Add -Execute to apply.

    Safeguards: refuses to write if the TARGET context == SOURCE tenant of the export.

.PARAMETER SourceTenantId
    GUID of the SOURCE tenant (read). Required for the Export phase.

.PARAMETER TargetTenantId
    GUID of the TARGET tenant (write). Required for Groups/Assign.

.PARAMETER Phase
    Export | Groups | Assign | All (default All).

.PARAMETER AssignmentsPath
    Assignments_* working folder (contains the .json files). Created if the Export phase runs.
    If absent: created under -WorkRoot for Export/All, otherwise reuses the most recent one.

.PARAMETER WorkRoot
    Root where the Assignments_* folder is created/searched (default .\IntuneExport_Assignments).

.PARAMETER Execute
    Real write. Absent = PREVIEW (no POST).

.PARAMETER StaticOnlyGroups
    Recreates dynamic groups as empty STATIC (ignores membershipRule) - safer in a sandbox.

.PARAMETER AllowPartialInclusionsOnly
    Assign phase, fail-closed relaxation. Allows POSTing an object whose ONLY unresolved targets are
    INCLUSION groups (the resolved subset is same-or-narrower in scope). Unresolved EXCLUSIONS or
    FILTERS always BLOCK the object unconditionally (a partial /assign would broaden scope). A target
    is never applied without its filter. Off by default (strict fail-closed).

.PARAMETER OnlyFamilies
    Limits the Assign phase to certain families (e.g. 01_DeviceConfigurations).

.PARAMETER LogPath
    CSV log (Family,Name,Status,Reason). Default under the Assignments_* folder.

.NOTES
    App-only auth expected via environment variables (set by the orchestrator):
      INTUNE_AUTO_SOURCE_TENANT_ID / INTUNE_AUTO_SOURCE_CLIENT_ID / INTUNE_AUTO_SOURCE_CERT_THUMBPRINT
      INTUNE_AUTO_TARGET_TENANT_ID / INTUNE_AUTO_TARGET_CLIENT_ID / INTUNE_AUTO_TARGET_CERT_THUMBPRINT
    Required application permissions (admin consent):
      SOURCE : DeviceManagement*.Read.All, Group.Read.All, Organization.Read.All
      TARGET : DeviceManagement*.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All
#>
[CmdletBinding()]
param(
    [string]$SourceTenantId,
    [string]$TargetTenantId,
    [ValidateSet('Export','Groups','Assign','All')][string]$Phase = 'All',
    [string]$AssignmentsPath,
    [string]$WorkRoot = (Join-Path (Get-Location) 'IntuneExport_Assignments'),
    [switch]$Execute,
    [switch]$StaticOnlyGroups,
    [switch]$AllowPartialInclusionsOnly,
    [string[]]$OnlyFamilies,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$GraphBase = 'https://graph.microsoft.com/beta'
$script:Log = New-Object System.Collections.Generic.List[object]

# Families carrying assignments (same endpoints as the configuration export).
$AssignableCatalog = @(
    @{ Folder='01_DeviceConfigurations';  Path='deviceManagement/deviceConfigurations';               DisplayProp='displayName' }
    @{ Folder='02_ConfigurationPolicies'; Path='deviceManagement/configurationPolicies';              DisplayProp='name'        }
    @{ Folder='03_CompliancePolicies';    Path='deviceManagement/deviceCompliancePolicies';           DisplayProp='displayName' }
    @{ Folder='04_ScriptsPowerShell';     Path='deviceManagement/deviceManagementScripts';            DisplayProp='displayName' }
    @{ Folder='05_ScriptsShell';          Path='deviceManagement/deviceShellScripts';                 DisplayProp='displayName' }
    @{ Folder='06_Remediations';          Path='deviceManagement/deviceHealthScripts';                DisplayProp='displayName' }
    @{ Folder='09_Apps';                  Path='deviceAppManagement/mobileApps';                      DisplayProp='displayName' }
    @{ Folder='10_AppConfigurations';     Path='deviceAppManagement/mobileAppConfigurations';         DisplayProp='displayName' }
    @{ Folder='11_AppProtection';         Path='deviceAppManagement/managedAppPolicies';              DisplayProp='displayName' }
    @{ Folder='12_AutopilotProfiles';     Path='deviceManagement/windowsAutopilotDeploymentProfiles'; DisplayProp='displayName' }
)

function Write-Info { param([string]$T) Write-Host ("[INFO] {0}" -f $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ("[OK]   {0}" -f $T) -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host ("[WARN] {0}" -f $T) -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host ("[ERR]  {0}" -f $T) -ForegroundColor Red }

function Add-Log {
    param([string]$Family,[string]$Name,[string]$Status,[string]$Reason)
    $script:Log.Add([pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Family=$Family; Name=$Name; Status=$Status; Reason=$Reason
    }) | Out-Null
}

# --- P1-3 : retry/backoff on transient throttling (HTTP 429) and gateway errors (503/504) ---
# A transient 429/503/504 on ANY Graph call (pagination, POST /groups, POST /assign) must be
# replayed, not surfaced as a Failed/ERROR. Honors Retry-After when present, else exponential
# backoff (cap 60s) + jitter. Any non-throttling error is re-thrown unchanged, so the fail-closed
# logic (P0-2/P0-6) is untouched.
function Invoke-GraphWithRetry {
    param([Parameter(Mandatory=$true)][scriptblock]$Call,[int]$MaxAttempts=5)
    for ($i=1;;$i++) {
        try { return & $Call }
        catch {
            $ex = $_.Exception
            # Detect the HTTP status across the possible exception shapes of Invoke-MgGraphRequest.
            $code = 0
            try { if ($ex.Response -and $ex.Response.StatusCode) { $code = [int]$ex.Response.StatusCode } } catch {}
            if ($code -eq 0) { try { if ($ex.StatusCode) { $code = [int]$ex.StatusCode } } catch {} }
            if ($code -eq 0 -and $_.ErrorDetails -and $_.ErrorDetails.Message -match '\b(429|503|504)\b') { $code = [int]$Matches[1] }
            if ($code -eq 0 -and $ex.Message -match '\b(429|503|504)\b') { $code = [int]$Matches[1] }
            if ($code -in 429,503,504 -and $i -lt $MaxAttempts) {
                $ra = 0
                try { if ($ex.Response -and $ex.Response.Headers.RetryAfter.Delta) { $ra = [int]$ex.Response.Headers.RetryAfter.Delta.TotalSeconds } } catch {}
                if ($ra -le 0) { $ra = [int][Math]::Min([Math]::Pow(2,$i),60) }
                Start-Sleep -Seconds ([int]$ra + (Get-Random -Minimum 0 -Maximum 2))
                continue
            }
            throw
        }
    }
}

# --- App-only certificate connection via INTUNE_AUTO_* variables (identical to the rest of the kit) ---
function Connect-GraphForIntuneAutomation {
    param([Parameter(Mandatory=$true)][string]$TenantId,[string[]]$Scopes)
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $tenantLower  = $TenantId.ToLowerInvariant()
    $sourceTenant = $env:INTUNE_AUTO_SOURCE_TENANT_ID
    $targetTenant = $env:INTUNE_AUTO_TARGET_TENANT_ID
    $clientId = $null; $certThumb = $null

    if ($sourceTenant -and ($tenantLower -eq $sourceTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_SOURCE_CLIENT_ID; $certThumb = $env:INTUNE_AUTO_SOURCE_CERT_THUMBPRINT
    }
    if ($targetTenant -and ($tenantLower -eq $targetTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_TARGET_CLIENT_ID; $certThumb = $env:INTUNE_AUTO_TARGET_CERT_THUMBPRINT
    }
    if (-not $clientId  -and $env:INTUNE_AUTO_CLIENT_ID)       { $clientId  = $env:INTUNE_AUTO_CLIENT_ID }
    if (-not $certThumb -and $env:INTUNE_AUTO_CERT_THUMBPRINT) { $certThumb = $env:INTUNE_AUTO_CERT_THUMBPRINT }

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower) `
        -and $clientId -and $ctx.ClientId -and ($ctx.ClientId -eq $clientId)) { return }

    if ($clientId -and $certThumb) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $TenantId -ClientId $clientId -CertificateThumbprint $certThumb -ContextScope Process -NoWelcome | Out-Null
    } else {
        # Interactive fallback ONLY if no app-only identity is provided (outside zero-touch).
        if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower)) { return }
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
    }

    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.TenantId) { throw "Invalid Graph connection (tenant $TenantId)." }
    if ($ctx.TenantId.ToLowerInvariant() -ne $tenantLower) {
        throw "Wrong tenant after connection. Expected=$TenantId ; connected=$($ctx.TenantId)"
    }
}

function Get-TenantDisplay {
    try { return ((Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/organization" }).value | Select-Object -First 1) } catch { return $null }
}

function Get-All {
    param([Parameter(Mandatory=$true)][string]$RelPath)
    $all = @(); $u = "$GraphBase/$RelPath"
    do {
        $r = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri $u }
        if     ($r.value) { $all += @($r.value) }
        elseif ($r.id)    { $all += $r }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # Stream the elements ($all), not ",$all": otherwise "@(Get-All ...)" re-wraps the collection into
    # a single element and the foreach iterates only once (same bug as Export FraisComplet v1).
    return $all
}

function Get-Prop { param($Obj,[string]$Prop) if ($null -eq $Obj) { return $null }; return $Obj.$Prop }

function Get-TargetGroupId {
    param($Target)
    if (-not $Target) { return $null }
    $t = $Target.'@odata.type'
    if ($t -match 'groupAssignmentTarget' -or $t -match 'exclusionGroupAssignmentTarget') { return $Target.groupId }
    return $null
}
function Get-TargetFilterId {
    param($Target)
    if ($Target -and $Target.deviceAndAppManagementAssignmentFilterId `
        -and $Target.deviceAndAppManagementAssignmentFilterId -ne '00000000-0000-0000-0000-000000000000') {
        return $Target.deviceAndAppManagementAssignmentFilterId
    }
    return $null
}
function Get-SafeMailNickname {
    param([string]$Base,[string]$Fallback)
    $src = if (-not [string]::IsNullOrWhiteSpace($Base)) { $Base } else { $Fallback }
    $nick = ($src -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($nick)) { $nick = 'grp' + ([guid]::NewGuid().Guid.Substring(0,8)) }
    if ($nick.Length -gt 60) { $nick = $nick.Substring(0,60) }
    return $nick
}

# =========================================================================
# WRITE SAFEGUARD (P0-6) - parametric, independent of the manifest file
# =========================================================================
function Assert-TargetIsNotSource {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Phase)
    # HARD-FAIL: a write phase must never run without the export manifest (no silent skip).
    $manifestPath = Join-Path $Root 'manifest-assignments.json'
    if (-not (Test-Path $manifestPath)) {
        throw "SAFEGUARD ($Phase): manifest-assignments.json is absent in $Root - write phase refused (run the Export phase first)."
    }
    $manifestSource = $null
    try { $manifestSource = (Get-Content $manifestPath -Raw | ConvertFrom-Json).TenantId }
    catch { throw "SAFEGUARD ($Phase): manifest-assignments.json in $Root is unreadable/corrupt - write phase refused (re-run the Export phase)." }
    # PARAMETRIC guard (file-independent): the TARGET must never equal the SOURCE tenant, whatever the
    # manifest state. -SourceTenantId (param) wins; the manifest TenantId is only a fallback source.
    $effectiveSource = if (-not [string]::IsNullOrWhiteSpace($SourceTenantId)) { $SourceTenantId } else { $manifestSource }
    if (-not [string]::IsNullOrWhiteSpace($effectiveSource) -and -not [string]::IsNullOrWhiteSpace($TargetTenantId) `
        -and ($TargetTenantId.ToLowerInvariant() -eq $effectiveSource.ToLowerInvariant())) {
        throw "SAFEGUARD ($Phase): TargetTenantId ($TargetTenantId) is identical to the SOURCE tenant. Write refused."
    }
    return $manifestSource
}

# =========================================================================
# EXPORT PHASE (SOURCE, read-only)
# =========================================================================
function Invoke-ExportPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($SourceTenantId)) { throw 'SourceTenantId required for the Export phase.' }
    Write-Info "EXPORT phase - app-only SOURCE connection ($SourceTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $SourceTenantId -Scopes @(
        'DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All',
        'DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All','Group.Read.All')
    $org = Get-TenantDisplay
    Write-Ok ("SOURCE : {0} ({1})" -f (Get-Prop $org 'displayName'), (Get-MgContext).TenantId)

    New-Item -ItemType Directory -Force $Root | Out-Null

    # 1) Filters (id -> name)
    $filterMap = @{}
    try {
        foreach ($f in @(Get-All 'deviceManagement/assignmentFilters')) { if ($f.id) { $filterMap[$f.id] = $f.displayName } }
        Write-Ok ("{0} filter(s) inventoried" -f $filterMap.Count)
    } catch { Write-Warn2 "Cannot read filters: $($_.Exception.Message)" }

    # 2) Assignments per object
    $assignmentRecords = @()
    $groupIds      = New-Object System.Collections.Generic.HashSet[string]
    $filterIdsUsed = New-Object System.Collections.Generic.HashSet[string]

    foreach ($cat in $AssignableCatalog) {
        try { $items = @(Get-All $cat.Path) }
        catch { Write-Warn2 ("{0} : unreadable family ({1})" -f $cat.Folder, $_.Exception.Message); continue }
        $withAssign = 0
        foreach ($it in $items) {
            if (-not $it.id) { continue }
            $name = (Get-Prop $it $cat.DisplayProp)
            if (-not $name) { $name = if ($it.displayName) { $it.displayName } elseif ($it.name) { $it.name } else { $it.id } }
            $assigns = @()
            try { $assigns = @(Get-All ("{0}/{1}/assignments" -f $cat.Path, $it.id)) } catch {}
            if ($assigns.Count -eq 0) { continue }
            $withAssign++

            $cleanAssigns = @()
            foreach ($a in $assigns) {
                $gid = Get-TargetGroupId  -Target $a.target; if ($gid) { [void]$groupIds.Add($gid) }
                $fid = Get-TargetFilterId -Target $a.target; if ($fid) { [void]$filterIdsUsed.Add($fid) }
                $cleanAssigns += [pscustomobject]@{ intent=$a.intent; source=$a.source; target=$a.target }
            }
            $assignmentRecords += [pscustomobject]@{
                Family=$cat.Folder; EndpointPath=$cat.Path; ObjectName=$name
                ObjectType=$it.'@odata.type'; Assignments=$cleanAssigns
            }
        }
        Write-Ok ("{0,-26} {1,3} object(s), {2,3} with assignment(s)" -f $cat.Folder, $items.Count, $withAssign)
    }

    # 3) Catalog of referenced Entra groups
    $groupsCatalog = @(); $groupErrors = @()
    $props = 'id,displayName,mailNickname,description,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled'
    foreach ($gid in $groupIds) {
        try {
            $g = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri ("{0}/groups/{1}?`$select={2}" -f $GraphBase, $gid, $props) }
            $groupsCatalog += [pscustomobject]@{
                oldId=$g.id; displayName=$g.displayName; mailNickname=$g.mailNickname; description=$g.description
                groupTypes=@($g.groupTypes); membershipRule=$g.membershipRule
                membershipRuleProcessingState=$g.membershipRuleProcessingState
                securityEnabled=$g.securityEnabled; mailEnabled=$g.mailEnabled
            }
        } catch { $groupErrors += [pscustomobject]@{ oldId=$gid; Error=$_.Exception.Message } }
    }
    $dyn = @($groupsCatalog | Where-Object { $_.groupTypes -contains 'DynamicMembership' }).Count
    Write-Ok ("{0} group(s) read ({1} dynamic), {2} in error" -f $groupsCatalog.Count, $dyn, $groupErrors.Count)

    # 4) Saves
    ($assignmentRecords | ConvertTo-Json -Depth 40) | Set-Content (Join-Path $Root 'assignments-map.json') -Encoding UTF8
    ($groupsCatalog     | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $Root 'groups-catalog.json')  -Encoding UTF8
    ($filterMap.GetEnumerator() | ForEach-Object { [pscustomobject]@{ oldId=$_.Key; displayName=$_.Value } } |
        ConvertTo-Json -Depth 5) | Set-Content (Join-Path $Root 'filters-catalog.json') -Encoding UTF8
    ([pscustomobject]@{
        Version='2.0-graph-apponly'; ExportedAt=(Get-Date).ToString('o')
        TenantId=(Get-MgContext).TenantId; TenantName=(Get-Prop $org 'displayName')
        Counts=[pscustomobject]@{
            ObjectsWithAssignments=$assignmentRecords.Count; GroupsReferenced=$groupsCatalog.Count
            GroupsUnreadable=$groupErrors.Count; FiltersReferenced=$filterIdsUsed.Count }
        GroupErrors=$groupErrors
    } | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $Root 'manifest-assignments.json') -Encoding UTF8

    Add-Log 'Assignments' 'Export' 'EXISTS' ("{0} objects, {1} groups, {2} filters" -f $assignmentRecords.Count, $groupsCatalog.Count, $filterIdsUsed.Count)
    Write-Ok ("Assignments export written to: {0}" -f $Root)
}

# =========================================================================
# GROUPS PHASE (TARGET, write)
# =========================================================================
function Invoke-GroupsPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($TargetTenantId)) { throw 'TargetTenantId required for the Groups phase.' }
    $catalogPath = Join-Path $Root 'groups-catalog.json'
    if (-not (Test-Path $catalogPath)) { throw "groups-catalog.json not found in $Root (run the Export phase first)." }
    $catalog = @(Get-Content $catalogPath -Raw | ConvertFrom-Json)

    # P0-6: file-independent SAFEGUARD (Target != Source) + hard-fail if the manifest is missing.
    $srcTenant = Assert-TargetIsNotSource -Root $Root -Phase 'Groups'

    Write-Info "GROUPS phase - app-only TARGET connection ($TargetTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes @('Group.ReadWrite.All')
    $ctxTid = (Get-MgContext).TenantId
    if ($srcTenant -and ($ctxTid.ToLowerInvariant() -eq $srcTenant.ToLowerInvariant())) {
        throw "SAFEGUARD: the TARGET ($ctxTid) is identical to the SOURCE of the export. Write refused."
    }
    Write-Ok ("TARGET : {0}" -f $ctxTid)

    $existing = @(Get-All 'groups?$select=id,displayName,mailNickname')
    $byName=@{}; $byNick=@{}
    foreach ($g in $existing) {
        if ($g.displayName)  { $byName[$g.displayName.ToLowerInvariant()] = $g }
        if ($g.mailNickname) { $byNick[$g.mailNickname.ToLowerInvariant()] = $g }
    }
    Write-Ok ("{0} existing group(s) in the target" -f $existing.Count)

    $plan = @()
    foreach ($src in $catalog) {
        $match = $null
        if ($src.displayName -and $byName.ContainsKey($src.displayName.ToLowerInvariant()))      { $match = $byName[$src.displayName.ToLowerInvariant()] }
        elseif ($src.mailNickname -and $byNick.ContainsKey($src.mailNickname.ToLowerInvariant())) { $match = $byNick[$src.mailNickname.ToLowerInvariant()] }
        $isDynamic = ($src.groupTypes -contains 'DynamicMembership') -and (-not $StaticOnlyGroups)
        $plan += [pscustomobject]@{
            displayName=$src.displayName; oldId=$src.oldId
            newId=if ($match) { $match.id } else { $null }
            Status=if ($match) { 'EXISTS' } else { 'NEW' }
            Dynamic=$isDynamic; _src=$src
        }
    }
    $toCreate = @($plan | Where-Object Status -eq 'NEW')
    $exists   = @($plan | Where-Object Status -eq 'EXISTS')
    Write-Info ("Groups -> to create : {0} | already present : {1} | total : {2}" -f $toCreate.Count, $exists.Count, $plan.Count)
    foreach ($p in $exists) { Add-Log 'Groups' $p.displayName 'EXISTS' 'already present' }

    if (-not $Execute) {
        foreach ($p in $toCreate) { Add-Log 'Groups' $p.displayName 'PREVIEW' ("planned creation ({0})" -f $(if($p.Dynamic){'dynamic'}else{'static'})) }
        ($plan | Select-Object displayName,oldId,newId,Status,Dynamic | ConvertTo-Json -Depth 5) |
            Set-Content (Join-Path $Root 'groups-idmap.PREVIEW.json') -Encoding UTF8
        Write-Warn2 ("PREVIEW : {0} group(s) would be created. Partial mapping : groups-idmap.PREVIEW.json" -f $toCreate.Count)
        return
    }

    foreach ($p in $toCreate) {
        $src = $p._src
        $body = [ordered]@{
            displayName=$src.displayName; mailEnabled=$false; securityEnabled=$true
            mailNickname=Get-SafeMailNickname -Base $src.mailNickname -Fallback $src.displayName
        }
        if ($src.description) { $body.description = $src.description }
        if ($p.Dynamic -and $src.membershipRule) {
            $body.groupTypes = @('DynamicMembership')
            $body.membershipRule = $src.membershipRule
            $body.membershipRuleProcessingState = if ($src.membershipRuleProcessingState) { $src.membershipRuleProcessingState } else { 'On' }
        } else { $body.groupTypes = @() }
        $json = ($body | ConvertTo-Json -Depth 10)
        try {
            $created = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/groups" -Body $json -ContentType 'application/json' }
            $p.newId = $created.id; $p.Status = 'CREATED'
            Add-Log 'Groups' $p.displayName 'CREATED' ''
            Write-Ok ("+ group {0}" -f $p.displayName)
        } catch {
            $p.Status = 'ERROR'
            Add-Log 'Groups' $p.displayName 'ERROR' $_.Exception.Message
            Write-Bad ("group {0} -- {1}" -f $p.displayName, $_.Exception.Message)
        }
    }

    ($plan | Select-Object displayName,oldId,newId,Status,Dynamic | ConvertTo-Json -Depth 5) |
        Set-Content (Join-Path $Root 'groups-idmap.json') -Encoding UTF8
    Write-Ok ("Groups mapping written : {0}" -f (Join-Path $Root 'groups-idmap.json'))
}

# =========================================================================
# ASSIGN PHASE (TARGET, write)
# =========================================================================
$FamilyMap = @{
    '01_DeviceConfigurations'  = @{ Path='deviceManagement/deviceConfigurations';               DisplayProp='displayName' }
    '02_ConfigurationPolicies' = @{ Path='deviceManagement/configurationPolicies';              DisplayProp='name'        }
    '03_CompliancePolicies'    = @{ Path='deviceManagement/deviceCompliancePolicies';           DisplayProp='displayName' }
    '04_ScriptsPowerShell'     = @{ Path='deviceManagement/deviceManagementScripts';            DisplayProp='displayName' }
    '05_ScriptsShell'          = @{ Path='deviceManagement/deviceShellScripts';                 DisplayProp='displayName' }
    '06_Remediations'          = @{ Path='deviceManagement/deviceHealthScripts';                DisplayProp='displayName' }
    '09_Apps'                  = @{ Path='deviceAppManagement/mobileApps';                      DisplayProp='displayName' }
    '10_AppConfigurations'     = @{ Path='deviceAppManagement/mobileAppConfigurations';         DisplayProp='displayName' }
    '11_AppProtection'         = @{ Path='deviceAppManagement/managedAppPolicies';              DisplayProp='displayName' }
    '12_AutopilotProfiles'     = @{ Path='deviceManagement/windowsAutopilotDeploymentProfiles'; DisplayProp='displayName' }
}

function Invoke-AssignPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($TargetTenantId)) { throw 'TargetTenantId required for the Assign phase.' }
    $assignPath = Join-Path $Root 'assignments-map.json'
    if (-not (Test-Path $assignPath)) { throw "assignments-map.json not found in $Root (run the Export phase first)." }
    $records = @(Get-Content $assignPath -Raw | ConvertFrom-Json)
    if ($OnlyFamilies) { $records = @($records | Where-Object { $OnlyFamilies -contains $_.Family }) }

    # P0-6: file-independent SAFEGUARD (Target != Source) + hard-fail if the manifest is missing.
    $srcTenant = Assert-TargetIsNotSource -Root $Root -Phase 'Assign'

    $groupNameByOldId = @{}
    $catalogPath = Join-Path $Root 'groups-catalog.json'
    if (Test-Path $catalogPath) {
        foreach ($g in @(Get-Content $catalogPath -Raw | ConvertFrom-Json)) { if ($g.oldId) { $groupNameByOldId[$g.oldId] = $g.displayName } }
    }
    $newIdByOldId = @{}
    $idmapPath = Join-Path $Root 'groups-idmap.json'
    if (Test-Path $idmapPath) {
        foreach ($m in @(Get-Content $idmapPath -Raw | ConvertFrom-Json)) { if ($m.oldId -and $m.newId) { $newIdByOldId[$m.oldId] = $m.newId } }
        Write-Info ("Groups mapping loaded : {0} match(es)." -f $newIdByOldId.Count)
    } else { Write-Warn2 'groups-idmap.json missing : remap only by live name lookup.' }

    $filterNameByOldId = @{}
    $filtersPath = Join-Path $Root 'filters-catalog.json'
    if (Test-Path $filtersPath) {
        foreach ($f in @(Get-Content $filtersPath -Raw | ConvertFrom-Json)) { if ($f.oldId) { $filterNameByOldId[$f.oldId] = $f.displayName } }
    }

    Write-Info "ASSIGN phase - app-only TARGET connection ($TargetTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes @(
        'DeviceManagementConfiguration.ReadWrite.All','DeviceManagementApps.ReadWrite.All',
        'DeviceManagementServiceConfig.ReadWrite.All','Group.Read.All')
    $ctxTid = (Get-MgContext).TenantId
    if ($srcTenant -and ($ctxTid.ToLowerInvariant() -eq $srcTenant.ToLowerInvariant())) {
        throw "SAFEGUARD: the TARGET ($ctxTid) is identical to the SOURCE of the export. Write refused."
    }
    Write-Ok ("TARGET : {0}" -f $ctxTid)

    # Live target index: groups by name, filters by name
    $tgtGroupsByName=@{}
    foreach ($g in @(Get-All 'groups?$select=id,displayName')) { if ($g.displayName) { $tgtGroupsByName[$g.displayName.ToLowerInvariant()] = $g.id } }
    $tgtFiltersByName=@{}
    foreach ($f in @(Get-All 'deviceManagement/assignmentFilters')) { if ($f.displayName) { $tgtFiltersByName[$f.displayName.ToLowerInvariant()] = $f.id } }
    Write-Ok ("{0} group(s), {1} filter(s) in the target" -f $tgtGroupsByName.Count, $tgtFiltersByName.Count)

    $resolveGroup = {
        param($OldId)
        if ($newIdByOldId.ContainsKey($OldId) -and $newIdByOldId[$OldId]) { return $newIdByOldId[$OldId] }
        if ($groupNameByOldId.ContainsKey($OldId)) {
            $nm = $groupNameByOldId[$OldId]
            if ($nm -and $tgtGroupsByName.ContainsKey($nm.ToLowerInvariant())) { return $tgtGroupsByName[$nm.ToLowerInvariant()] }
        }
        return $null
    }
    $resolveFilter = {
        param($OldId)
        if ($filterNameByOldId.ContainsKey($OldId)) {
            $nm = $filterNameByOldId[$OldId]
            if ($nm -and $tgtFiltersByName.ContainsKey($nm.ToLowerInvariant())) { return $tgtFiltersByName[$nm.ToLowerInvariant()] }
        }
        return $null
    }

    $unresolved = @()
    foreach ($fam in ($records | Group-Object Family)) {
        $famName = $fam.Name
        if (-not $FamilyMap.ContainsKey($famName)) { continue }
        $path = $FamilyMap[$famName].Path
        $disp = $FamilyMap[$famName].DisplayProp
        Write-Info ("--- {0} ({1} object(s) with assignment) ---" -f $famName, $fam.Count)

        $tgtByName=@{}
        foreach ($o in @(Get-All ("{0}?`$select=id,{1}" -f $path, $disp))) {
            $n = (Get-Prop $o $disp); if (-not $n -and $o.displayName) { $n = $o.displayName }
            if ($n) { $tgtByName[$n.ToLowerInvariant()] = $o.id }
        }

        foreach ($rec in $fam.Group) {
            $nameKey = if ($rec.ObjectName) { $rec.ObjectName.ToLowerInvariant() } else { $null }
            if (-not $nameKey -or -not $tgtByName.ContainsKey($nameKey)) {
                Add-Log $famName $rec.ObjectName 'SKIPPED' 'object missing from target'; continue
            }
            $targetId = $tgtByName[$nameKey]

            $newAssignments=@(); $droppedHere=0
            # P0-2 fail-CLOSED: track unresolved inclusions and exclusions separately.
            $hadUnresolvedInclusion = $false
            $hadUnresolvedExclusion = $false
            foreach ($a in @($rec.Assignments)) {
                $t = $a.target; if (-not $t) { continue }
                $type = $t.'@odata.type'
                $isExclusion = ($type -match 'exclusionGroupAssignmentTarget')
                $newTarget = [ordered]@{ '@odata.type' = $type }
                if ($type -match 'groupAssignmentTarget' -or $type -match 'exclusionGroupAssignmentTarget') {
                    $newGid = & $resolveGroup $t.groupId
                    if (-not $newGid) {
                        $droppedHere++
                        $unresolved += [pscustomobject]@{ Family=$famName; Object=$rec.ObjectName; Kind=$(if($isExclusion){'GROUP (exclusion)'}else{'GROUP (inclusion)'}); OldId=$t.groupId; Name=$groupNameByOldId[$t.groupId] }
                        # An unresolved EXCLUSION would BROADEN scope -> block; an unresolved INCLUSION only narrows it.
                        if ($isExclusion) { $hadUnresolvedExclusion = $true } else { $hadUnresolvedInclusion = $true }
                        continue
                    }
                    $newTarget.groupId = $newGid
                }
                $oldFilterId = $t.deviceAndAppManagementAssignmentFilterId
                if ($oldFilterId -and $oldFilterId -ne '00000000-0000-0000-0000-000000000000') {
                    $newFid = & $resolveFilter $oldFilterId
                    if ($newFid) {
                        $newTarget.deviceAndAppManagementAssignmentFilterId = $newFid
                        $newTarget.deviceAndAppManagementAssignmentFilterType = $t.deviceAndAppManagementAssignmentFilterType
                    } else {
                        # A missing filter restricts scope: NEVER apply the target without it -> treat as EXCLUSION class.
                        $droppedHere++
                        $unresolved += [pscustomobject]@{ Family=$famName; Object=$rec.ObjectName; Kind='FILTER (unresolved)'; OldId=$oldFilterId; Name=$filterNameByOldId[$oldFilterId] }
                        $hadUnresolvedExclusion = $true
                        continue
                    }
                }
                $entry = [ordered]@{ target = $newTarget }
                if ($a.intent) { $entry.intent = $a.intent }
                $newAssignments += $entry
            }

            # P0-2 fail-CLOSED gate: /assign is a full replace, so a partial set that drops an exclusion or a
            # filter would BROADEN scope. Block such objects UNCONDITIONALLY (never POST), whatever the switch.
            if ($hadUnresolvedExclusion) {
                Add-Log $famName $rec.ObjectName 'BLOCKED' 'unresolved exclusion or filter (filters are not auto-recreated in the target) - scope would broaden, assignment refused'
                Write-Bad ("  [BLOCKED] {0} : unresolved exclusion/filter - scope would broaden (create the filter/exclusion group in the target, or re-run without it)" -f $rec.ObjectName)
                continue
            }
            if ($hadUnresolvedInclusion -and -not $AllowPartialInclusionsOnly) {
                Add-Log $famName $rec.ObjectName 'BLOCKED' ("unresolved inclusion ({0}) - use -AllowPartialInclusionsOnly to apply the resolved same-or-narrower subset" -f $droppedHere)
                Write-Bad ("  [BLOCKED] {0} : unresolved inclusion (add -AllowPartialInclusionsOnly to allow)" -f $rec.ObjectName)
                continue
            }

            if ($newAssignments.Count -eq 0) {
                Add-Log $famName $rec.ObjectName 'SKIPPED' ("no resolved assignment ({0} dropped)" -f $droppedHere); continue
            }
            if (-not $Execute) {
                Add-Log $famName $rec.ObjectName 'PREVIEW' ("{0} assignment(s) (of which {1} dropped)" -f $newAssignments.Count, $droppedHere)
                Write-Host ("  [prev] {0} -> {1} assignment(s)" -f $rec.ObjectName, $newAssignments.Count) -ForegroundColor DarkCyan
                continue
            }
            $json = (@{ assignments = $newAssignments } | ConvertTo-Json -Depth 40)
            try {
                $null = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method POST -Uri ("{0}/{1}/{2}/assign" -f $GraphBase, $path, $targetId) -Body $json -ContentType 'application/json' }
                Add-Log $famName $rec.ObjectName 'APPLIED' ("{0} assignment(s)" -f $newAssignments.Count)
                Write-Ok ("+ {0} ({1} assignment(s))" -f $rec.ObjectName, $newAssignments.Count)
            } catch {
                Add-Log $famName $rec.ObjectName 'ERROR' $_.Exception.Message
                Write-Bad ("{0} -- {1}" -f $rec.ObjectName, $_.Exception.Message)
            }
        }
    }
    if ($unresolved.Count -gt 0) {
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
        ($unresolved | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $Root "assignments-unresolved_$stamp.json") -Encoding UTF8
        Write-Warn2 ("{0} unresolved target(s) -> assignments-unresolved_{1}.json" -f $unresolved.Count, $stamp)
    }
}

# =========================================================================
# MAIN
# =========================================================================
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # Determine the Assignments_* working folder
    if ($AssignmentsPath) { $root = $AssignmentsPath }
    elseif ($Phase -in 'Export','All') { $root = Join-Path $WorkRoot ("Assignments_{0}" -f (Get-Date -Format 'yyyy-MM-dd_HHmm')) }
    else {
        if (-not (Test-Path $WorkRoot)) { throw "WorkRoot not found : $WorkRoot" }
        $latest = Get-ChildItem $WorkRoot -Directory -Filter 'Assignments_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "No Assignments_* folder found in $WorkRoot" }
        $root = $latest.FullName
    }
    New-Item -ItemType Directory -Force $root | Out-Null
    if (-not $LogPath) { $LogPath = Join-Path $root ("assignments-log_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host ("ASSIGNMENTS MIGRATION (app-only) - Phase {0} - {1}" -f $Phase, $(if($Execute){'EXECUTE'}else{'PREVIEW'})) -ForegroundColor Green
    Write-Host ("Folder : {0}" -f $root) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor DarkGray

    if ($Phase -in 'Export','All') { Invoke-ExportPhase -Root $root }
    if ($Phase -in 'Groups','All') { Invoke-GroupsPhase -Root $root }
    if ($Phase -in 'Assign','All') { Invoke-AssignPhase -Root $root }

    $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Ok ("CSV log : {0}" -f $LogPath)
    $script:Log | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Name, $_.Count) -ForegroundColor Gray }
}
catch {
    try { $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8 } catch {}
    Write-Bad $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    throw
}

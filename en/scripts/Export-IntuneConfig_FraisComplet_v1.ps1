#Requires -Version 7.0
<#
.SYNOPSIS
    FRESH and COMPLETE Intune export from PROD (PowerShell 7 + Microsoft Graph SDK, beta endpoint).
    Produces an Export_<date> folder that is already REHYDRATED, directly importable by the v3 engine.

.DESCRIPTION
    Fixes the 2 pitfalls of the legacy Microsoft.Graph.Intune module:
      - NO "$expand=settings" on the configurationPolicies collection (source of the 400):
        settings are retrieved PER ITEM (GET configurationPolicies/{id}/settings).
      - base64 content of scripts/remediations retrieved PER ITEM (GET .../{id}),
        and scheduledActionsForRule / localizedNotificationMessages retrieved via $expand per item.
    Each family is isolated in try/catch: a failing family does not interrupt the export.
    Writes a manifest.json (TenantId, date, account, counts) at the root of the export.

.PARAMETER SourceTenantId
    GUID of the PROD tenant to export. Safeguard: refuses if the current Graph context != this value.

.PARAMETER OutputPath
    Target folder of the export (e.g. C:\...\input\Export_2026-07-15_0930). Created if missing.

.NOTES
    PREREQUISITE: Connect-MgGraph -TenantId <PROD> -Scopes DeviceManagement*.Read.All  (already done before the call).
    READ-ONLY: this script writes NOTHING to the tenant.
.EXAMPLE
    Connect-MgGraph -TenantId <SOURCE_TENANT_ID> -Scopes 'DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All'
    .\Export-IntuneConfig_FraisComplet_v1.ps1 -SourceTenantId <SOURCE_TENANT_ID> -OutputPath .\input\Export_2026-07-15_0930
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceTenantId,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$B = 'https://graph.microsoft.com/beta'
# Known exclusions (NOT exported - see LIMITATIONS.md): Device Inventory policies (not exportable with a
# standard Microsoft Graph token), ADMX Administrative Templates, Endpoint Security intents, Enrollment
# configurations, encrypted secrets, and LOB/Win32/VPP app binaries.
$warn = New-Object System.Collections.Generic.List[string]
$counts = @()

# --- Safeguard: we must be connected to the SOURCE tenant (PROD) ---
$ctx = Get-MgContext
if (-not $ctx) { throw "No Graph connection. Run Connect-MgGraph -TenantId $SourceTenantId ... (PROD account) first." }
if ($ctx.TenantId -ne $SourceTenantId) { throw "SAFEGUARD: current context $($ctx.TenantId) != expected source $SourceTenantId. Connect to the PROD tenant." }

$org = $null
try { $org = (Invoke-MgGraphRequest -Method GET -Uri "$B/organization").value | Select-Object -First 1 } catch {}
Write-Host ""
Write-Host ("EXPORT from : {0}  (TenantId {1})" -f $org.displayName, $ctx.TenantId) -ForegroundColor Cyan
Write-Host ("Account       : {0}" -f $ctx.Account) -ForegroundColor Cyan
Write-Host ("Destination   : {0}" -f $OutputPath) -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

function Get-All {
    param([string]$RelPath)
    $all = @(); $u = "$B/$RelPath"
    do {
        $r = Invoke-MgGraphRequest -Method GET -Uri $u
        if ($r.value) { $all += $r.value } elseif ($r.id) { $all += $r }
        $u = $r.'@odata.nextLink'
    } while ($u)
    ,$all
}

function Save-Obj {
    param([string]$Dir,[string]$Name,[string]$Id,$Obj)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'object' }
    $safe = ($Name -replace '[^\w\.\- ]','_').Trim()
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0,80) }
    $file = Join-Path $Dir ("{0}_{1}.json" -f $safe, $Id)
    ($Obj | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $file -Encoding UTF8
}

# Family -> endpoint. Enrichment mode:
#   Item     = re-GET the full entity (base64 content of scripts/remediations)
#   Settings = attach settings per item (Settings Catalog) -> AVOIDS the 400 of the $expand collection
#   Expand   = re-GET with $expand (compliance: actions ; notifications: messages)
$fam = @(
  @{ F='01_DeviceConfigurations';  P='deviceManagement/deviceConfigurations';               N='displayName'; Item=$true }
  @{ F='02_ConfigurationPolicies'; P='deviceManagement/configurationPolicies';              N='name';        Settings=$true }
  @{ F='03_CompliancePolicies';    P='deviceManagement/deviceCompliancePolicies';           N='displayName'; Expand='scheduledActionsForRule($expand=scheduledActionConfigurations)' }
  @{ F='04_ScriptsPowerShell';     P='deviceManagement/deviceManagementScripts';            N='displayName'; Item=$true }
  @{ F='05_ScriptsShell';          P='deviceManagement/deviceShellScripts';                 N='displayName'; Item=$true }
  @{ F='06_Remediations';          P='deviceManagement/deviceHealthScripts';                N='displayName'; Item=$true }
  @{ F='07_Filters';               P='deviceManagement/assignmentFilters';                  N='displayName' }
  @{ F='08_ScopeTags';             P='deviceManagement/roleScopeTags';                      N='displayName' }
  @{ F='09_Apps';                  P='deviceAppManagement/mobileApps';                      N='displayName' }
  @{ F='10_AppConfigurations';     P='deviceAppManagement/mobileAppConfigurations';         N='displayName' }
  @{ F='11_AppProtection';         P='deviceAppManagement/managedAppPolicies';              N='displayName' }
  @{ F='12_AutopilotProfiles';     P='deviceManagement/windowsAutopilotDeploymentProfiles'; N='displayName' }
  @{ F='13_NotificationTemplates'; P='deviceManagement/notificationMessageTemplates';       N='displayName'; Expand='localizedNotificationMessages' }
  @{ F='14_AdminTemplates';        P='deviceManagement/groupPolicyConfigurations';          N='displayName' }
  @{ F='15_EndpointSecurity';      P='deviceManagement/intents';                            N='displayName' }
  @{ F='16_Enrollment';            P='deviceManagement/deviceEnrollmentConfigurations';     N='displayName' }
  @{ F='17_FeatureUpdateProfiles'; P='deviceManagement/windowsFeatureUpdateProfiles'; N='displayName' }
  @{ F='18_QualityUpdateProfiles'; P='deviceManagement/windowsQualityUpdateProfiles'; N='displayName' }
  @{ F='19_DriverUpdateProfiles';  P='deviceManagement/windowsDriverUpdateProfiles';  N='displayName' }
  @{ F='20_TermsAndConditions';    P='deviceManagement/termsAndConditions';            N='displayName' }
  @{ F='21_DeviceCategories';      P='deviceManagement/deviceCategories';              N='displayName' }
  @{ F='22_RoleDefinitions';       P='deviceManagement/roleDefinitions';               N='displayName' }
  @{ F='23_ConditionalAccess';    P='identity/conditionalAccess/policies';               N='displayName' }
)

Write-Host "Families :" -ForegroundColor Yellow
foreach ($cat in $fam) {
    $dir = Join-Path $OutputPath $cat.F
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $items = @()
    try { $items = @(Get-All $cat.P) }
    catch { $warn.Add("[$($cat.F)] list FAILED : $($_.Exception.Message)"); }

    $n = 0
    foreach ($o in $items) {
        try {
            $obj = $o
            if     ($cat.Item)     { $obj = Invoke-MgGraphRequest -Method GET -Uri "$B/$($cat.P)/$($o.id)" }
            elseif ($cat.Expand)   { $obj = Invoke-MgGraphRequest -Method GET -Uri "$B/$($cat.P)/$($o.id)?`$expand=$($cat.Expand)" }
            elseif ($cat.Settings) { $obj = $o; $obj['settings'] = @(Get-All "$($cat.P)/$($o.id)/settings") }

            $name = [string]$obj.($cat.N)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$obj.displayName }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$obj.name }
            Save-Obj -Dir $dir -Name $name -Id ([string]$obj.id) -Obj $obj
            $n++
        } catch { $warn.Add("[$($cat.F)] item $($o.id) FAILED : $($_.Exception.Message)") }
    }
    $counts += [pscustomobject]@{ Family = $cat.F; Count = $n }
    Write-Host ("  {0,-26} {1}" -f $cat.F, $n) -ForegroundColor Green
}

# --- Manifest ---
$manifest = [ordered]@{
    Version    = 'FraisComplet-v1'
    ExportedAt = (Get-Date).ToString('o')
    TenantId   = $ctx.TenantId
    TenantName = $org.displayName
    Account    = $ctx.Account
    Families   = $counts
}
($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.json') -Encoding UTF8

Write-Host ""
Write-Host ("Export finished : {0}" -f $OutputPath) -ForegroundColor Magenta
Write-Host ("Total objects   : {0}" -f (($counts | Measure-Object Count -Sum).Sum)) -ForegroundColor Magenta
if ($warn.Count -gt 0) {
    $wf = Join-Path $OutputPath 'export_warnings.txt'
    $warn | Set-Content -LiteralPath $wf -Encoding UTF8
    Write-Host ("Warnings : {0} (see {1})" -f $warn.Count, $wf) -ForegroundColor Yellow
}


# --- Integrity: SHA-256 checksums of every exported file (Verify-IntuneExport.ps1) ---
$sums = [ordered]@{}
Get-ChildItem $OutputPath -Recurse -File | Where-Object { $_.Name -ne 'checksums.json' } | Sort-Object FullName | ForEach-Object {
    $rel = ($_.FullName.Substring($OutputPath.Length).TrimStart('','/')) -replace '\','/'
    $sums[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
($sums | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $OutputPath 'checksums.json') -Encoding UTF8
Write-Host ("Checksums   : {0} file(s) (checksums.json)" -f $sums.Count) -ForegroundColor Cyan

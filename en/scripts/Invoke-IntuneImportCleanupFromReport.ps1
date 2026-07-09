#Requires -Version 5.1
<#
.SYNOPSIS
    Cleanup objects created by a failed Intune import attempt.

.DESCRIPTION
    Reads RAPPORT-IMPORT*.txt, extracts objects marked CREATED, connects to the target tenant,
    finds objects by name in the expected Graph collection, and deletes only candidates created in
    the supplied import time window. Default mode is preview. Add -Execute to delete.

.NOTES
    The -ImportStartUtc / -ImportEndUtc window prevents deleting pre-existing objects: only objects
    whose createdDateTime falls inside it are removed. Defaults to the last 24 hours (clean up right
    after a failed run). Pass an explicit, narrow window to clean an older import.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [Parameter(Mandatory=$true)][string]$TargetTenantId,
    [datetime]$ImportStartUtc = ([datetime]::UtcNow.AddDays(-1)),
    [datetime]$ImportEndUtc = ([datetime]::UtcNow.AddMinutes(10)),
    [switch]$Execute,
    [switch]$Force,
    [string]$LogPath = (Join-Path (Get-Location) ("CleanupResults_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

$ErrorActionPreference='Stop'
$GraphBase='https://graph.microsoft.com/beta'
$Results=New-Object System.Collections.Generic.List[object]

$Scopes=@(
 'DeviceManagementConfiguration.ReadWrite.All',
 'DeviceManagementApps.ReadWrite.All',
 'DeviceManagementManagedDevices.ReadWrite.All',
 'DeviceManagementServiceConfig.ReadWrite.All',
 'DeviceManagementScripts.ReadWrite.All',
 'DeviceManagementRBAC.ReadWrite.All'
)

$Catalog=@{
 '01_DeviceConfigurations' = @{ Path='deviceManagement/deviceConfigurations'; NameProp='displayName' }
 '02_ConfigurationPolicies'= @{ Path='deviceManagement/configurationPolicies'; NameProp='name' }
 '03_CompliancePolicies'   = @{ Path='deviceManagement/deviceCompliancePolicies'; NameProp='displayName' }
 '04_ScriptsPowerShell'    = @{ Path='deviceManagement/deviceManagementScripts'; NameProp='displayName' }
 '06_Remediations'         = @{ Path='deviceManagement/deviceHealthScripts'; NameProp='displayName' }
 '07_Filters'              = @{ Path='deviceManagement/assignmentFilters'; NameProp='displayName' }
 '08_ScopeTags'            = @{ Path='deviceManagement/roleScopeTags'; NameProp='displayName' }
 '09_Apps'                 = @{ Path='deviceAppManagement/mobileApps'; NameProp='displayName' }
 '10_AppConfigurations'    = @{ Path='deviceAppManagement/mobileAppConfigurations'; NameProp='displayName' }
 '11_AppProtection'        = @{ Path='deviceAppManagement/managedAppPolicies'; NameProp='displayName' }
 '12_AutopilotProfiles'    = @{ Path='deviceManagement/windowsAutopilotDeploymentProfiles'; NameProp='displayName' }
 '13_NotificationTemplates'= @{ Path='deviceManagement/notificationMessageTemplates'; NameProp='displayName' }
}


function Connect-GraphForIntuneAutomation {
    param(
        [Parameter(Mandatory=$true)][string]$TenantId,
        [string[]]$Scopes
    )
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $tenantLower = $TenantId.ToLowerInvariant()
    $sourceTenant = $env:INTUNE_AUTO_SOURCE_TENANT_ID
    $targetTenant = $env:INTUNE_AUTO_TARGET_TENANT_ID

    $clientId = $null
    $certThumb = $null

    if ($sourceTenant -and ($tenantLower -eq $sourceTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_SOURCE_CLIENT_ID
        $certThumb = $env:INTUNE_AUTO_SOURCE_CERT_THUMBPRINT
    }
    if ($targetTenant -and ($tenantLower -eq $targetTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_TARGET_CLIENT_ID
        $certThumb = $env:INTUNE_AUTO_TARGET_CERT_THUMBPRINT
    }
    if (-not $clientId -and $env:INTUNE_AUTO_CLIENT_ID) { $clientId = $env:INTUNE_AUTO_CLIENT_ID }
    if (-not $certThumb -and $env:INTUNE_AUTO_CERT_THUMBPRINT) { $certThumb = $env:INTUNE_AUTO_CERT_THUMBPRINT }

    $ctx = Get-MgContext -ErrorAction SilentlyContinue

    if ($clientId -and $certThumb) {
        if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower) -and $ctx.ClientId -and ($ctx.ClientId -eq $clientId)) {
            return
        }
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $TenantId -ClientId $clientId -CertificateThumbprint $certThumb -ContextScope Process -NoWelcome | Out-Null
        return
    }

    if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower)) {
        $ctxScopes = @($ctx.Scopes)
        $missing = @()
        foreach ($s in @($Scopes)) {
            if ($ctxScopes -notcontains $s) { $missing += $s }
        }
        if ($missing.Count -eq 0) { return }
        Write-Host ("Missing Graph scopes for {0}: {1}. Re-authentication required." -f $TenantId, ($missing -join ', ')) -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    } elseif ($ctx) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
}

function Add-Result($Family,$Name,$Status,$Action,$GraphId,$CreatedDateTime,$Reason,$ErrorMessage){
 $Results.Add([pscustomobject]@{
  DateUtc=(Get-Date).ToUniversalTime().ToString('s')+'Z'; Family=$Family; Name=$Name; Status=$Status; Action=$Action;
  GraphId=$GraphId; CreatedDateTime=$CreatedDateTime; Reason=$Reason; ErrorMessage=$ErrorMessage
 }) | Out-Null
}

function Save-Results(){
 if($Results.Count -gt 0){ $Results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8; Write-Host "Log: $LogPath" -ForegroundColor Cyan }
}

function Get-CreatedEntriesFromReport(){
 $text=Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8
 $entries=@()
 foreach($line in ($text -split "`r?`n")){
  if($line -match '^(\S+)\s+\|\s+(.+?)\s+\|\s+CREATED\s*$'){
   $entries += [pscustomobject]@{ Family=$matches[1]; Name=$matches[2].Trim() }
  }
 }
 return $entries
}

function Invoke-Graph($Method,$Uri){
 $full = if($Uri -match '^https://'){$Uri}else{"$GraphBase/$Uri"}
 Invoke-MgGraphRequest -Method $Method -Uri $full
}

function Get-AllGraphItems($Uri){
 $all=@(); $next=if($Uri -match '^https://'){$Uri}else{"$GraphBase/$Uri"}
 do{
  $resp=Invoke-MgGraphRequest -Method GET -Uri $next
  if($resp.value){$all += @($resp.value)} elseif($resp.id){$all += $resp}
  $next=$resp.'@odata.nextLink'
 } while($next)
 return $all
}

function Get-PropertyValue($Obj,[string]$Name){
 if($Obj.PSObject.Properties.Name -contains $Name){ return $Obj.PSObject.Properties[$Name].Value }
 return $null
}

$DisableScopeTags = ($env:INTUNE_AUTO_DISABLE_SCOPE_TAGS -eq '1')
if($DisableScopeTags){ $Scopes = @($Scopes | Where-Object { $_ -ne 'DeviceManagementRBAC.ReadWrite.All' }) }

try{
 if(-not (Test-Path -LiteralPath $ReportPath)){ throw "ReportPath not found: $ReportPath" }
 if(-not $Execute){ Write-Host 'PREVIEW mode: no deletion. Add -Execute to delete.' -ForegroundColor Yellow }
 Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
 Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes $Scopes
 $ctx=Get-MgContext
 Write-Host "Target tenant: $($ctx.TenantId)" -ForegroundColor Cyan
 $entries=@(Get-CreatedEntriesFromReport)
 Write-Host "CREATED objects in report: $($entries.Count)" -ForegroundColor Cyan
 if($Execute -and (-not $Force)){
  $r=Read-Host "Delete objects created between $($ImportStartUtc.ToString('s'))Z and $($ImportEndUtc.ToString('s'))Z ? [Y/N]"
  if($r -notmatch '^[OoYy]'){ throw 'Cancelled by user.' }
 }
 foreach($g in ($entries | Group-Object Family)){
  if(-not $Catalog.ContainsKey($g.Name)){
   foreach($e in $g.Group){ Add-Result $e.Family $e.Name 'SKIPPED' 'NO_CATALOG' $null $null 'Family not supported by cleanup' $null }
   continue
  }
  if($DisableScopeTags -and $g.Name -eq '08_ScopeTags'){
   foreach($e in $g.Group){ Add-Result $e.Family $e.Name 'SKIPPED' 'RBAC_SCOPE_TAGS_DISABLED' $null $null 'ScopeTags read/delete skipped because DeviceManagementRBAC is unavailable or disabled.' $null }
   Write-Host "Target read: $($g.Name) skipped (RBAC ScopeTags disabled)." -ForegroundColor Yellow
   continue
  }
  $cat=$Catalog[$g.Name]
  Write-Host "Target read: $($g.Name)" -ForegroundColor Cyan
  try { $items=@(Get-AllGraphItems -Uri $cat.Path) }
  catch {
   foreach($e in $g.Group){ Add-Result $e.Family $e.Name 'SKIPPED' 'LOOKUP_FORBIDDEN_OR_FAILED' $null $null 'Target read failed; cleanup skipped for this family.' $_.Exception.Message }
   Write-Host "  [SKIPPED] Target read failed for $($g.Name): $($_.Exception.Message)" -ForegroundColor Yellow
   continue
  }
  foreach($e in $g.Group){
   $matches=@($items | Where-Object { (Get-PropertyValue $_ $cat.NameProp) -eq $e.Name })
   if($matches.Count -eq 0){ Add-Result $e.Family $e.Name 'NOT_FOUND' 'LOOKUP' $null $null 'No target object with the same name' $null; continue }
   foreach($m in $matches){
    $created=Get-PropertyValue $m 'createdDateTime'
    $id=Get-PropertyValue $m 'id'
    $inWindow=$true
    if($created){
     try{ $dt=([datetime]$created).ToUniversalTime(); $inWindow=($dt -ge $ImportStartUtc.ToUniversalTime() -and $dt -le $ImportEndUtc.ToUniversalTime()) } catch { $inWindow=$false }
    } else { $inWindow=$false }
    if(-not $inWindow){ Add-Result $e.Family $e.Name 'SKIPPED' 'DATE_GUARD' $id $created 'createdDateTime outside import window or missing' $null; continue }
    if(-not $Execute){ Add-Result $e.Family $e.Name 'PREVIEW_DELETE' 'DELETE' $id $created 'Deletion candidate' $null; Write-Host "  [PREVIEW DELETE] $($e.Name)" -ForegroundColor Gray; continue }
    try{ Invoke-Graph -Method DELETE -Uri ("{0}/{1}" -f $cat.Path,$id) | Out-Null; Add-Result $e.Family $e.Name 'DELETED' 'DELETE' $id $created '' $null; Write-Host "  [DELETED] $($e.Name)" -ForegroundColor Green }
    catch{ Add-Result $e.Family $e.Name 'ERROR' 'DELETE' $id $created '' $_.Exception.Message; Write-Host "  [X] $($e.Name): $($_.Exception.Message)" -ForegroundColor Red }
   }
  }
 }
 Save-Results
}catch{
 Save-Results
 Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
 throw
}

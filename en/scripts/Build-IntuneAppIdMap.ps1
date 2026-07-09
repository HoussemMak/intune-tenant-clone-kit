#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a SourceId to TargetId app mapping CSV for Intune app configuration imports.

.DESCRIPTION
    App configuration policies reference mobileApp IDs from the source tenant. Those IDs are not valid in
    the target tenant. This script reads exported apps, connects to the target tenant, matches target apps
    primarily by displayName and @odata.type, and outputs AppIdMap.csv with SourceId, TargetId, DisplayName,
    SourceType, TargetType, MatchStatus.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$TargetTenantId,
    [string]$OutputCsv = (Join-Path (Get-Location) 'AppIdMap.csv')
)
$ErrorActionPreference='Stop'
$GraphBase='https://graph.microsoft.com/beta'
$Scopes=@('DeviceManagementApps.Read.All','DeviceManagementApps.ReadWrite.All')


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

function Resolve-ExportRoot($Path){
 if(-not (Test-Path -LiteralPath $Path)){ throw "Source not found: $Path" }
 $item=Get-Item -LiteralPath $Path
 if($item.PSIsContainer){
  if(Test-Path -LiteralPath (Join-Path $item.FullName 'manifest.json')){ return $item.FullName }
  $mf=Get-ChildItem -Path $item.FullName -Filter manifest.json -Recurse -File | Select-Object -First 1
  if($mf){ return $mf.Directory.FullName }
 }
 if($item.Extension -ieq '.zip'){
  $tmp=Join-Path $env:TEMP ('IntuneMap_' + [guid]::NewGuid().Guid)
  New-Item -Path $tmp -ItemType Directory -Force | Out-Null
  Expand-Archive -Path $item.FullName -DestinationPath $tmp -Force
  $mf=Get-ChildItem -Path $tmp -Filter manifest.json -Recurse -File | Select-Object -First 1
  if($mf){ return $mf.Directory.FullName }
 }
 throw 'manifest.json not found.'
}
function Get-AllGraphItems($Uri){
 $all=@(); $next="$GraphBase/$Uri"
 do{
  $resp=Invoke-MgGraphRequest -Method GET -Uri $next
  if($resp.value){$all += @($resp.value)} elseif($resp.id){$all += $resp}
  $next=$resp.'@odata.nextLink'
 }while($next)
 return $all
}
function Read-Json($Path){ Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Prop($Obj,$Name){ if($Obj.PSObject.Properties.Name -contains $Name){ return $Obj.PSObject.Properties[$Name].Value }; return $null }
try{
 $root=Resolve-ExportRoot $SourcePath
 $appFolder=Join-Path $root '09_Apps'
 if(-not (Test-Path -LiteralPath $appFolder)){ throw '09_Apps folder missing.' }
 Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
 Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes $Scopes
 $targetApps=@(Get-AllGraphItems -Uri 'deviceAppManagement/mobileApps')
 $rows=@()
 foreach($f in Get-ChildItem -Path $appFolder -Filter '*.json' -File){
  $src=Read-Json $f.FullName
  $sid=$src.id; $name=$src.displayName; $stype=$src.'@odata.type'
  $matches=@($targetApps | Where-Object { (Get-Prop $_ 'displayName') -eq $name -and (Get-Prop $_ '@odata.type') -eq $stype })
  if($matches.Count -eq 1){
   $rows += [pscustomobject]@{SourceId=$sid;TargetId=(Get-Prop $matches[0] 'id');DisplayName=$name;SourceType=$stype;TargetType=(Get-Prop $matches[0] '@odata.type');MatchStatus='ExactNameAndType'}
  } elseif($matches.Count -gt 1){
   $rows += [pscustomobject]@{SourceId=$sid;TargetId='';DisplayName=$name;SourceType=$stype;TargetType='';MatchStatus="MultipleMatches:$($matches.Count)"}
  } else {
   $byName=@($targetApps | Where-Object { (Get-Prop $_ 'displayName') -eq $name })
   if($byName.Count -eq 1){
    $rows += [pscustomobject]@{SourceId=$sid;TargetId=(Get-Prop $byName[0] 'id');DisplayName=$name;SourceType=$stype;TargetType=(Get-Prop $byName[0] '@odata.type');MatchStatus='NameOnly'}
   } else {
    $rows += [pscustomobject]@{SourceId=$sid;TargetId='';DisplayName=$name;SourceType=$stype;TargetType='';MatchStatus='NoTargetMatch'}
   }
  }
 }
 $rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
 Write-Host "Mapping generated: $OutputCsv" -ForegroundColor Green
}catch{
 Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
 throw
}

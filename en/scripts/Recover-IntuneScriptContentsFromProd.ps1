#Requires -Version 5.1
<#
.SYNOPSIS
    Attempts to rehydrate Intune PowerShell script and Remediation script contents in an export folder.

.DESCRIPTION
    The failed import showed scripts/remediations with missing scriptContent, detectionScriptContent,
    and remediationScriptContent. This script connects to the PROD/source tenant, reads each object by
    its exported source id, and writes any returned content back into a copy of the export folder.

    If Graph does not return content for some objects, the script records them in a CSV. Those objects
    must be restored from the source script repository or recreated manually.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$SourceTenantId,
    [string]$OutputPath,
    [switch]$ForceOverwrite,
    [string]$LogPath = (Join-Path (Get-Location) ("RecoverScriptContents_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

$ErrorActionPreference='Stop'
$GraphBase='https://graph.microsoft.com/beta'
$Results=New-Object System.Collections.Generic.List[object]
$Scopes=@('DeviceManagementScripts.ReadWrite.All','DeviceManagementConfiguration.ReadWrite.All','Organization.Read.All')


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

function Add-Result($Family,$Name,$Id,$Status,$UpdatedFields,$Reason,$ErrorMessage){
 $Results.Add([pscustomobject]@{DateUtc=(Get-Date).ToUniversalTime().ToString('s')+'Z';Family=$Family;Name=$Name;Id=$Id;Status=$Status;UpdatedFields=$UpdatedFields;Reason=$Reason;ErrorMessage=$ErrorMessage}) | Out-Null
}
function Save-Results(){ if($Results.Count -gt 0){ $Results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8; Write-Host "Log: $LogPath" -ForegroundColor Cyan } }
function Resolve-ExportRoot($Path){
 if(-not (Test-Path -LiteralPath $Path)){ throw "Source not found: $Path" }
 $item=Get-Item -LiteralPath $Path
 if($item.PSIsContainer){
  if(Test-Path -LiteralPath (Join-Path $item.FullName 'manifest.json')){ return $item.FullName }
  $mf=Get-ChildItem -Path $item.FullName -Filter manifest.json -Recurse -File | Select-Object -First 1
  if($mf){ return $mf.Directory.FullName }
 }
 if($item.Extension -ieq '.zip'){
  $tmp=Join-Path $env:TEMP ('IntuneRecover_' + [guid]::NewGuid().Guid)
  New-Item -Path $tmp -ItemType Directory -Force | Out-Null
  Expand-Archive -Path $item.FullName -DestinationPath $tmp -Force
  $mf=Get-ChildItem -Path $tmp -Filter manifest.json -Recurse -File | Select-Object -First 1
  if($mf){ return $mf.Directory.FullName }
 }
 throw 'manifest.json not found.'
}
function Copy-ExportRoot($Root,$Dest,$Force){
 if([string]::IsNullOrWhiteSpace($Dest)){ $Dest = ($Root.TrimEnd('\') + '_content_rehydrated') }
 if(Test-Path -LiteralPath $Dest){
  if(-not $Force){ throw "OutputPath already exists: $Dest. Use -ForceOverwrite." }
  Remove-Item -LiteralPath $Dest -Recurse -Force
 }
 Copy-Item -LiteralPath $Root -Destination $Dest -Recurse -Force
 return (Resolve-Path -LiteralPath $Dest).Path
}
function Invoke-Graph($Uri){ Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/$Uri" }
function Read-Json($Path){ Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json($Path,$Obj){ $Obj | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function HasValue($v){ return ($null -ne $v -and (($v -isnot [string]) -or $v.Trim().Length -gt 0)) }

try{
 $root=Resolve-ExportRoot $SourcePath
 $target=Copy-ExportRoot -Root $root -Dest $OutputPath -Force:$ForceOverwrite
 Write-Host "Export copy: $target" -ForegroundColor Cyan
 Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
 Connect-GraphForIntuneAutomation -TenantId $SourceTenantId -Scopes $Scopes
 $ctx=Get-MgContext
 Write-Host "Tenant connected: $($ctx.TenantId)" -ForegroundColor Cyan
 if($ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -ne $SourceTenantId.ToLowerInvariant())){ throw 'Connection differs from the provided SourceTenantId.' }

 $scriptFolder=Join-Path $target '04_ScriptsPowerShell'
 if(Test-Path -LiteralPath $scriptFolder){
  foreach($file in Get-ChildItem -Path $scriptFolder -Filter '*.json' -File){
   $o=Read-Json $file.FullName; $name=$o.displayName; $id=$o.id
   try{
    $remote=Invoke-Graph -Uri "deviceManagement/deviceManagementScripts/$id"
    if((HasValue $remote.scriptContent) -and (-not (HasValue $o.scriptContent))){ $o.scriptContent=$remote.scriptContent; Write-Json $file.FullName $o; Add-Result '04_ScriptsPowerShell' $name $id 'UPDATED' 'scriptContent' '' $null }
    elseif(HasValue $o.scriptContent){ Add-Result '04_ScriptsPowerShell' $name $id 'UNCHANGED' '' 'Content already present' $null }
    else{ Add-Result '04_ScriptsPowerShell' $name $id 'MISSING' '' 'Graph does not return scriptContent' $null }
   }catch{ Add-Result '04_ScriptsPowerShell' $name $id 'ERROR' '' '' $_.Exception.Message }
  }
 }

 $remFolder=Join-Path $target '06_Remediations'
 if(Test-Path -LiteralPath $remFolder){
  foreach($file in Get-ChildItem -Path $remFolder -Filter '*.json' -File){
   $o=Read-Json $file.FullName; $name=$o.displayName; $id=$o.id
   try{
    $remote=Invoke-Graph -Uri "deviceManagement/deviceHealthScripts/$id"
    $updated=@()
    if((HasValue $remote.detectionScriptContent) -and (-not (HasValue $o.detectionScriptContent))){ $o.detectionScriptContent=$remote.detectionScriptContent; $updated += 'detectionScriptContent' }
    if((HasValue $remote.remediationScriptContent) -and (-not (HasValue $o.remediationScriptContent))){ $o.remediationScriptContent=$remote.remediationScriptContent; $updated += 'remediationScriptContent' }
    if($updated.Count -gt 0){ Write-Json $file.FullName $o; Add-Result '06_Remediations' $name $id 'UPDATED' ($updated -join ';') '' $null }
    elseif((HasValue $o.detectionScriptContent) -and (HasValue $o.remediationScriptContent)){ Add-Result '06_Remediations' $name $id 'UNCHANGED' '' 'Contents already present' $null }
    else{ Add-Result '06_Remediations' $name $id 'MISSING' '' 'Graph does not return the required contents' $null }
   }catch{ Add-Result '06_Remediations' $name $id 'ERROR' '' '' $_.Exception.Message }
  }
 }
 Save-Results
 Write-Host "Rehydrated export: $target" -ForegroundColor Green
}catch{
 Save-Results
 Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
 throw
}

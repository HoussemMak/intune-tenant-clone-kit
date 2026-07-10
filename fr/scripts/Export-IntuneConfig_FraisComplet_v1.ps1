#Requires -Version 7.0
<#
.SYNOPSIS
    Export Intune FRAIS et COMPLET depuis PROD (PowerShell 7 + Microsoft Graph SDK, point de terminaison beta).
    Produit un dossier Export_<date> deja REHYDRATE, directement importable par le moteur v3.

.DESCRIPTION
    Corrige les 2 pieges de l'ancien module Microsoft.Graph.Intune :
      - PAS de "$expand=settings" sur la collection configurationPolicies (source du 400) :
        on recupere les parametres PAR ELEMENT (GET configurationPolicies/{id}/settings).
      - Contenu base64 des scripts/remediations recupere PAR ELEMENT (GET .../{id}),
        et scheduledActionsForRule / localizedNotificationMessages recuperes via $expand par element.
    Chaque famille est isolee en try/catch : une famille en echec n'interrompt pas l'export.
    Ecrit un manifest.json (TenantId, date, compte, comptages) a la racine de l'export.

.PARAMETER SourceTenantId
    GUID du tenant PROD a exporter. Garde-fou : refuse si le contexte Graph courant != cette valeur.

.PARAMETER OutputPath
    Dossier cible de l'export (ex. C:\...\input\Export_2026-07-15_0930). Cree si absent.

.NOTES
    PREREQUIS : Connect-MgGraph -TenantId <PROD> -Scopes DeviceManagement*.Read.All  (deja fait avant l'appel).
    Lecture SEULE : ce script n'ecrit RIEN dans le tenant.
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
# Exclusions connues (NON exportees - voir LIMITATIONS.md) : Device Inventory policies (non exportables
# avec un token Microsoft Graph classique), Modeles d'administration ADMX, intents Endpoint Security,
# configurations d'inscription, secrets chiffres, et binaires d'apps LOB/Win32/VPP.
$warn = New-Object System.Collections.Generic.List[string]
$counts = @()

# --- Garde-fou : on doit etre connecte au tenant SOURCE (PROD) ---
$ctx = Get-MgContext
if (-not $ctx) { throw "Aucune connexion Graph. Faire Connect-MgGraph -TenantId $SourceTenantId ... (compte PROD) avant." }
if ($ctx.TenantId -ne $SourceTenantId) { throw "GARDE-FOU : contexte courant $($ctx.TenantId) != source attendue $SourceTenantId. Connecte-toi au tenant PROD." }

$org = $null
try { $org = (Invoke-MgGraphRequest -Method GET -Uri "$B/organization").value | Select-Object -First 1 } catch {}
Write-Host ""
Write-Host ("EXPORT depuis : {0}  (TenantId {1})" -f $org.displayName, $ctx.TenantId) -ForegroundColor Cyan
Write-Host ("Compte        : {0}" -f $ctx.Account) -ForegroundColor Cyan
Write-Host ("Destination   : {0}" -f $OutputPath) -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

function Get-All {
    param([string]$RelPath)
    $all = @(); $u = "$B/$RelPath"
    do {
        $r = Invoke-MgGraphRequest -Method GET -Uri $u
        if ($r.value) { $all += @($r.value) } elseif ($r.id) { $all += $r }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # IMPORTANT : streamer les elements ($all), PAS ",$all". Avec ",$all", le "@(Get-All ...)"
    # de l'appelant re-emballe le tableau en UN seul element => le foreach n'itere qu'une fois
    # sur toute la collection ($o = tous les objets), $o.id = liste jointe, l'URL par item devient
    # "endpoint/<id1> <id2> ..." => "The provided URL is not valid" et 0 objet exporte.
    return $all
}

function Save-Obj {
    param([string]$Dir,[string]$Name,[string]$Id,$Obj)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'objet' }
    $safe = ($Name -replace '[^\w\.\- ]','_').Trim()
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0,80) }
    $file = Join-Path $Dir ("{0}_{1}.json" -f $safe, $Id)
    ($Obj | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $file -Encoding UTF8
}

# Famille -> point de terminaison. Mode d'enrichissement :
#   Item     = re-GET l'entite complete (contenu base64 des scripts/remediations)
#   Settings = attacher les parametres par element (Settings Catalog) -> EVITE le 400 du $expand collection
#   Expand   = re-GET avec $expand (conformite : actions ; notifications : messages)
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

Write-Host "Familles :" -ForegroundColor Yellow
foreach ($cat in $fam) {
    $dir = Join-Path $OutputPath $cat.F
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $items = @()
    try { $items = @(Get-All $cat.P) }
    catch { $warn.Add("[$($cat.F)] liste KO : $($_.Exception.Message)"); }

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
        } catch { $warn.Add("[$($cat.F)] element $($o.id) KO : $($_.Exception.Message)") }
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
Write-Host ("Export termine : {0}" -f $OutputPath) -ForegroundColor Magenta
Write-Host ("Total objets   : {0}" -f (($counts | Measure-Object Count -Sum).Sum)) -ForegroundColor Magenta
if ($warn.Count -gt 0) {
    $wf = Join-Path $OutputPath 'export_warnings.txt'
    $warn | Set-Content -LiteralPath $wf -Encoding UTF8
    Write-Host ("Avertissements : {0} (voir {1})" -f $warn.Count, $wf) -ForegroundColor Yellow
}


# --- Integrity: SHA-256 checksums of every exported file (Verify-IntuneExport.ps1) ---
$sums = [ordered]@{}
Get-ChildItem $OutputPath -Recurse -File | Where-Object { $_.Name -ne 'checksums.json' } | Sort-Object FullName | ForEach-Object {
    $rel = ($_.FullName.Substring($OutputPath.Length).TrimStart('','/')) -replace '\','/'
    $sums[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
($sums | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $OutputPath 'checksums.json') -Encoding UTF8
Write-Host ("Checksums   : {0} fichier(s) (checksums.json)" -f $sums.Count) -ForegroundColor Cyan

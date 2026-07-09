#Requires -Version 7.0
<#
.SYNOPSIS
    OPT-IN : récupère les valeurs de secrets OMA-URI personnalisés chiffrées depuis le tenant SOURCE et les ré-injecte
    dans les profils de configuration d'appareil exportés, afin que ces profils puissent être recréés automatiquement.

.DESCRIPTION
    Pour chaque profil 01_DeviceConfigurations exporté qui contient des omaSettings chiffrés
    (isEncrypted = true + un secretReferenceValueId), ceci appelle l'action du tenant source
    POST deviceManagement/deviceConfigurations/{id}/getOmaSettingPlainTextValue pour récupérer la valeur
    en clair, l'écrit dans `value`, et SUPPRIME le secretReferenceValueId (spécifique au tenant). À l'import,
    Intune re-chiffre la valeur et génère un nouveau pointeur dans le tenant cible — ainsi aucun administrateur
    n'a besoin de ressaisir le secret.

    ⚠️ SÉCURITÉ : ceci écrit des secrets EN CLAIR dans les fichiers d'export sur le disque. Gardez le dossier
    d'export protégé, supprimez-le après l'import, et ne le validez JAMAIS dans Git (le .gitignore du kit exclut input/ et
    les exports). Nécessite une connexion Graph active au tenant SOURCE avec
    DeviceManagementConfiguration.Read.All (l'action getOmaSettingPlainTextValue).

.PARAMETER ExportPath
    Le dossier d'export (Fixed)Export contenant 01_DeviceConfigurations.

.PARAMETER SourceTenantId
    GUID du tenant SOURCE. Garde-fou : refuse si le contexte Graph actuel est un tenant différent.

.PARAMETER AssumeYes
    Ignore l'invite de confirmation (pour l'automatisation).

.EXAMPLE
    # après connexion au tenant SOURCE :
    .\Recover-IntuneOmaSecrets.ps1 -ExportPath .\FixedExport -SourceTenantId <SOURCE_TENANT_ID>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExportPath,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'
$B = 'https://graph.microsoft.com/beta'

$ctx = Get-MgContext
if (-not $ctx) { throw "Aucune connexion Graph. Connectez-vous d'abord au tenant SOURCE (Connect-MgGraph -TenantId $SourceTenantId ...)." }
if ($ctx.TenantId -ne $SourceTenantId) { throw "GARDE-FOU : contexte actuel $($ctx.TenantId) != source $SourceTenantId. Connectez-vous au tenant SOURCE." }

$dir = Join-Path $ExportPath '01_DeviceConfigurations'
if (-not (Test-Path -LiteralPath $dir)) { Write-Host "Aucun dossier 01_DeviceConfigurations dans $ExportPath." -ForegroundColor Yellow; return }

Write-Host ""
Write-Host "RÉCUPÉRATION DES SECRETS OMA (opt-in)" -ForegroundColor Magenta
Write-Host "Ceci écrit des secrets EN CLAIR dans l'export sur le disque. Protégez-le et supprimez-le après l'import ; ne le validez jamais dans Git." -ForegroundColor Yellow
if (-not $AssumeYes) { $r = Read-Host "Continuer ? [o/N]"; if ($r -notmatch '^[yYoO]') { Write-Host 'Annulé.'; return } }

$recovered = 0; $failed = 0; $profiles = 0
foreach ($f in Get-ChildItem $dir -Filter *.json -File) {
    $o = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if (-not $o.omaSettings) { continue }
    $enc = @($o.omaSettings | Where-Object { $_.isEncrypted -and $_.secretReferenceValueId })
    if ($enc.Count -eq 0) { continue }
    $profiles++
    $changed = $false
    foreach ($oma in $enc) {
        try {
            $resp = Invoke-MgGraphRequest -Method POST `
                -Uri ("{0}/deviceManagement/deviceConfigurations/{1}/getOmaSettingPlainTextValue" -f $B, $o.id) `
                -Body (@{ secretReferenceValueId = $oma.secretReferenceValueId } | ConvertTo-Json) -ContentType 'application/json'
            $clear = if ($null -ne $resp.value) { $resp.value } else { [string]$resp }
            $oma.value = $clear
            $oma.PSObject.Properties.Remove('secretReferenceValueId')   # le pointeur spécifique au tenant ne doit pas être envoyé (POST)
            $recovered++; $changed = $true
        } catch {
            $failed++
            Write-Host ("  [X] {0} / {1}: {2}" -f $o.displayName, $oma.omaUri, $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ($changed) {
        ($o | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $f.FullName -Encoding UTF8
        Write-Host ("  [+] {0} — secrets ré-injectés" -f $o.displayName) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host ("Profils avec secrets : {0} | paramètres récupérés : {1} | échecs : {2}" -f $profiles, $recovered, $failed) -ForegroundColor Cyan
Write-Host "Ces profils de configuration d'appareil s'importeront désormais automatiquement (Intune re-chiffre sur la cible)." -ForegroundColor Green
if ($failed -gt 0) { Write-Host "Certaines valeurs n'ont pas pu être récupérées (droits ou secrets régénérés) — recréez-les manuellement." -ForegroundColor Yellow }

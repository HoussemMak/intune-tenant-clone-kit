> [🇬🇧 English version](../en/EXECUTER.md)

# EXECUTER — Cycle complet Export → Correction → Import (tenant SOURCE → tenant CIBLE)

PowerShell 7 (pwsh). Faire les étapes dans l'ordre. Copier-coller chaque bloc.
À chaque connexion, l'affichage indique **le tenant et le compte connectés** + le compte **attendu** : vérifier avant de continuer.

> Prérequis : avoir copié `config.example.ps1` en `config.ps1` et renseigné vos GUID de tenant.

---

### Étape 1 — Variables (coller une fois ; éditer `$Kit`)
```powershell
$Kit='C:\chemin\vers\intune-tenant-clone-kit'   # <-- éditer
. "$Kit\config.ps1"                               # charge $SourceTenantId,$TargetTenantId,$SourceDomain,$TargetDomain,$AppId
$Stamp=(Get-Date -f yyyy-MM-dd_HHmm)
$Src="$Kit\input\Export_$Stamp"; $Fixed=$Src; $Logs="$Kit\logs"; $Backup="$Kit\backup_$Stamp"
$Report="$Kit\input\import-report.txt"           # (optionnel) rapport d'un import précédent échoué, pour l'étape de nettoyage
$Pkg="$Kit\scripts"; $Engine="$Pkg\Import-IntuneConfig_Corrige_v3.ps1"; $Exporter="$Pkg\Export-IntuneConfig_FraisComplet_v1.ps1"
$Scopes    =@('DeviceManagementConfiguration.ReadWrite.All','DeviceManagementApps.ReadWrite.All','DeviceManagementServiceConfig.ReadWrite.All','DeviceManagementRBAC.ReadWrite.All','DeviceManagementManagedDevices.ReadWrite.All')
$ScopesRead=@('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All')

function Show-Tenant($expect){ $c=Get-MgContext; $o=$null; try{$o=(Invoke-MgGraphRequest GET 'https://graph.microsoft.com/v1.0/organization').value[0]}catch{}
  Write-Host ("--> CONNECTE A : {0}   (TenantId {1})" -f $o.displayName,$c.TenantId) -ForegroundColor Cyan
  Write-Host ("    Compte     : {0}" -f $c.Account) -ForegroundColor Cyan
  Write-Host ("    ATTENDU    : {0}" -f $expect) -ForegroundColor Yellow }
function Connect-Source { Disconnect-MgGraph -EA SilentlyContinue|Out-Null; Connect-MgGraph -TenantId $SourceTenantId -Scopes $ScopesRead -NoWelcome; Show-Tenant "SOURCE — compte admin @ $SourceDomain (lecture seule)" }
function Connect-Target { Disconnect-MgGraph -EA SilentlyContinue|Out-Null; Connect-MgGraph -TenantId $TargetTenantId -Scopes $Scopes     -NoWelcome; Show-Tenant "CIBLE — compte admin @ $TargetDomain (écriture)" }
function Assert-Source  { if((Get-MgContext).TenantId -ne $SourceTenantId){throw 'STOP: pas connecté au tenant SOURCE'}; 'OK SOURCE' }
function Assert-Target  { if((Get-MgContext).TenantId -ne $TargetTenantId){throw 'STOP: pas connecté au tenant CIBLE'};  'OK CIBLE' }
```

### Étape 2 — Module + déblocage des scripts
```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force; Import-Module Microsoft.Graph.Authentication
Get-ChildItem $Pkg -Filter *.ps1 | Unblock-File
New-Item -ItemType Directory -Force $Logs,$Backup | Out-Null
```

### Étape 3 — Connexion SOURCE + EXPORT FRAIS (lecture seule) → `$Src`
```powershell
Connect-Source                     # <-- se connecter avec un compte admin SOURCE ; VÉRIFIER l'affichage "CONNECTE A / ATTENDU"
Assert-Source
& $Exporter -SourceTenantId $SourceTenantId -OutputPath $Src
```
> Produit un export du jour, **déjà réhydraté** (settings, contenus de scripts, actions de conformité). C'est la source d'import (`$Fixed`).

### Étape 4 — Connexion CIBLE + sauvegarde
```powershell
Connect-Target                     # <-- se connecter avec un compte admin CIBLE ; VÉRIFIER l'affichage
Assert-Target
'deviceManagement/deviceConfigurations','deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts','deviceManagement/roleScopeTags','deviceManagement/assignmentFilters','deviceAppManagement/mobileApps','deviceAppManagement/mobileAppConfigurations','deviceAppManagement/managedAppPolicies'|%{
 (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/$_`?`$top=999").value|ConvertTo-Json -Depth 100|Set-Content "$Backup\$($_ -replace '/','_').json" -Encoding UTF8}
```

### Étape 5 — (OPTIONNEL) Nettoyer un import précédent échoué — aperçu
> Seulement si vous avez déjà un import raté à nettoyer (rapport dans `$Report`). Sinon, passer à l'étape 7.
```powershell
& "$Pkg\Invoke-IntuneImportCleanupFromReport.ps1" -ReportPath $Report -TargetTenantId $TargetTenantId -LogPath "$Logs\01_preview.csv"
```

### Étape 6 — (OPTIONNEL) Nettoyage — exécuter
```powershell
& "$Pkg\Invoke-IntuneImportCleanupFromReport.ps1" -ReportPath $Report -TargetTenantId $TargetTenantId -Execute -Force -LogPath "$Logs\02_exec.csv"
```

### Étape 7 — Aperçu des politiques (aucune écriture)
```powershell
Connect-Target; Assert-Target
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Policies -LogPath "$Logs\03_preflight.csv"
```

### Étape 8 — Import (aperçu de chaque vague : retirer `-Execute`)
```powershell
Connect-Target; Assert-Target
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Foundation -Execute -LogPath "$Logs\05_foundation.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Apps       -Execute -LogPath "$Logs\06_apps.csv"
& "$Pkg\Build-IntuneAppIdMap.ps1" -TargetTenantId $TargetTenantId -SourceExportPath "$Fixed\09_Apps" -OutCsv "$Kit\AppIdMap.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Policies   -Execute -LogPath "$Logs\07_policies.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Scripts    -Execute -LogPath "$Logs\08_scripts.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Mobile     -Execute -LogPath "$Logs\09_mobile.csv"
```

### Étape 9 — Bilan des imports
```powershell
Get-ChildItem "$Logs\0*.csv"|%{"`n$($_.Name)";Import-Csv $_|Group-Object Status|Format-Table Name,Count -Auto}
```

### Étape 10 — Affectations : groupes + assignments, remap par NOM (PREVIEW puis `-Execute`)
```powershell
# PREVIEW (aucune écriture) : export source + plan de groupes + plan d'affectations
& "$Pkg\Invoke-IntuneAssignments_Graph.ps1" -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All
# Exécution : crée les groupes manquants (par nom) et applique les affectations remappées
& "$Pkg\Invoke-IntuneAssignments_Graph.ps1" -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All -Execute
```
> En mode manuel, ce script se connecte de façon interactive (SOURCE pour l'export, CIBLE pour l'écriture). Pour l'enchaînement 100 % non-surveillé, voir [`EXECUTER_AUTO.md`](EXECUTER_AUTO.md).

### Étape 11 — Vérification finale (comptes SOURCE vs CIBLE)
```powershell
function C($t,$e){Disconnect-MgGraph -EA SilentlyContinue|Out-Null;Connect-MgGraph -TenantId $t -Scopes $ScopesRead -NoWelcome|Out-Null;(Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/$e`?`$top=999").value.Count}
'deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceConfigurations','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts'|%{[pscustomobject]@{Endpoint=$_;Source=(C $SourceTenantId $_);Cible=(C $TargetTenantId $_)}}|Format-Table -Auto
```

### Étape 12 — Manuel (à faire à la main, hors script — limites d'Intune)
```
- Profils à secret (Wi-Fi/PSK, AppLocker/WDAC, valeurs OMA chiffrées) : re-saisir la valeur et recréer.
- Apps LOB / Win32 / VPP : re-téléverser le binaire.
- Admin Templates, Endpoint Security (intents), Enrollment : recréer au portail.
```

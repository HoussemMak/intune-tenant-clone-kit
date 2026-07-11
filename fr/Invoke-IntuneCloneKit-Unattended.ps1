#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestrateur ZERO-TOUCH du intune-tenant-clone-kit : Export -> (Nettoyage) -> Import par vagues
    -> Affectations -> Verification -> Rapport HTML, SANS AUCUNE INTERVENTION HUMAINE.

.DESCRIPTION
    Enchaine automatiquement, en une seule commande et sans prompt, tout le cycle decrit dans
    EXECUTER.md :
      0. Prepare le module Microsoft.Graph.Authentication.
      1. Connexion app-only CERTIFICAT au tenant SOURCE + export FRAIS rehydrate.
      2. Connexion app-only CERTIFICAT au tenant CIBLE + sauvegarde des collections.
      3. (Optionnel) Nettoyage d'un import precedent rate (a partir d'un rapport).
      4. Prevalidation complete (aucune ecriture).
      5. Import par vagues : Foundation, Apps, (AppIdMap), Policies, Scripts, Mobile.
      6. (Optionnel) Affectations : groupes Entra + assignments remappes par NOM.
      7. (Optionnel) Verification finale SOURCE vs CIBLE (comptages par endpoint).
      8. Rapport HTML + synthese CSV + transcript.

    100% non-interactif : authentification app-only par certificat (aucun popup), aucun Read-Host.
    PREVIEW global disponible via -Preview (aucune ecriture nulle part).

    Identifiants app-only lus, dans l'ordre : parametres -> config.ps1 -> variables d'environnement.

.PARAMETER SourceTenantId / TargetTenantId
    GUID des tenants SOURCE (lecture) et CIBLE (ecriture). Repli sur config.ps1.

.PARAMETER SourceClientId / SourceCertThumbprint / TargetClientId / TargetCertThumbprint
    App registration + empreinte de certificat par tenant (app-only). Si une seule app multi-tenant
    est utilisee, renseigner -ClientId / -CertThumbprint (appliques aux deux).

.PARAMETER ClientId / CertThumbprint
    Identite app-only commune aux deux tenants (repli si les valeurs par tenant sont absentes).

.PARAMETER SourcePath
    Dossier d'export deja rehydrate a importer. Si absent : un export FRAIS est produit depuis la SOURCE.

.PARAMETER ImportReport
    (Optionnel) Rapport RAPPORT-IMPORT*.txt d'un import precedent : declenche le nettoyage prealable.

.PARAMETER ImportStartUtc / ImportEndUtc
    Fenetre temporelle du nettoyage (securite anti-suppression d'objets preexistants).

.PARAMETER Preview
    Simulation globale : aucune ecriture (export + preflight + previews uniquement).

.PARAMETER AllowInteractive
    Autorise un repli sur la connexion interactive si aucune identite app-only n'est fournie.
    A EVITER en mode planifie (romp le zero-touch).

.EXAMPLE
    .\Invoke-IntuneCloneKit-Unattended.ps1 `
        -SourceTenantId <SRC> -TargetTenantId <TGT> `
        -SourceClientId <APPSRC> -SourceCertThumbprint <THUMBSRC> `
        -TargetClientId <APPTGT> -TargetCertThumbprint <THUMBTGT>
#>
[CmdletBinding()]
param(
    [string]$KitRoot,
    [string]$SourceTenantId,
    [string]$TargetTenantId,

    [string]$SourceClientId,
    [string]$SourceCertThumbprint,
    [string]$TargetClientId,
    [string]$TargetCertThumbprint,
    [string]$ClientId,
    [string]$CertThumbprint,

    [string]$WorkDir,
    [string]$SourcePath,
    [string]$ImportReport,
    [datetime]$ImportStartUtc,
    [datetime]$ImportEndUtc,

    [switch]$SkipBackup,
    [switch]$SkipCleanup,
    [switch]$SkipPreflight,
    [switch]$SkipApps,
    [switch]$SkipScripts,
    [switch]$SkipMobile,
    [switch]$SkipAppIdMap,
    [switch]$SkipAssignments,
    [switch]$SkipVerification,
    [switch]$IncludeScopeTags,
    [switch]$StaticOnlyGroups,
    [switch]$StopOnImportErrors,
    [switch]$Preview,
    [switch]$AllowInteractive,
    [switch]$UseAIAssist,
    [switch]$RecoverSecrets
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------
# Chemins & constantes
# --------------------------------------------------------------------------
if (-not $KitRoot) { $KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigFile = Join-Path $KitRoot 'config.ps1'
$ScriptsDir = Join-Path $KitRoot 'scripts'
if (-not $WorkDir) { $WorkDir = $KitRoot }

$RunStamp       = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogsDir        = Join-Path $WorkDir 'logs'
$OutputDir      = Join-Path $WorkDir 'output'
$BackupDir      = Join-Path $WorkDir ("backup_{0}" -f $RunStamp)
$AssignRoot     = Join-Path $WorkDir 'assignments'
$AssignmentsDir = Join-Path $AssignRoot ("Assignments_{0}" -f $RunStamp)
$TranscriptPath = Join-Path $LogsDir ("Transcript_Unattended_{0}.log" -f $RunStamp)
$SummaryCsv     = Join-Path $OutputDir ("SyntheseExecution_{0}.csv" -f $RunStamp)
$FinalReport    = Join-Path $OutputDir ("RapportExecution_Unattended_{0}.html" -f $RunStamp)

$Engine   = Join-Path $ScriptsDir 'Import-IntuneConfig_Corrige_v3.ps1'
$Exporter = Join-Path $ScriptsDir 'Export-IntuneConfig_FraisComplet_v1.ps1'
$Cleanup  = Join-Path $ScriptsDir 'Invoke-IntuneImportCleanupFromReport.ps1'
$AppMap   = Join-Path $ScriptsDir 'Build-IntuneAppIdMap.ps1'
$Assign   = Join-Path $ScriptsDir 'Invoke-IntuneAssignments_Graph.ps1'
$AIAssist = Join-Path $ScriptsDir 'Invoke-IntuneAIAssist.ps1'
$RecoverSec = Join-Path $ScriptsDir 'Recover-IntuneOmaSecrets.ps1'

$VerifyEndpoints = @(
    'deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies',
    'deviceManagement/deviceConfigurations','deviceManagement/deviceManagementScripts',
    'deviceManagement/deviceHealthScripts','deviceManagement/assignmentFilters',
    'deviceAppManagement/mobileApps'
)

# --------------------------------------------------------------------------
# Affichage
# --------------------------------------------------------------------------
function Write-Banner { param([string]$T,[string]$C='Cyan')
    Write-Host ''; Write-Host ('=' * 92) -ForegroundColor DarkGray
    Write-Host $T -ForegroundColor $C; Write-Host ('=' * 92) -ForegroundColor DarkGray }
function Write-Info { param([string]$T) Write-Host ("[INFO] {0}" -f $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ("[OK]   {0}" -f $T) -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host ("[WARN] {0}" -f $T) -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host ("[ERR]  {0}" -f $T) -ForegroundColor Red }

$script:StepRows = New-Object System.Collections.Generic.List[object]
$script:ReconSnapshots = New-Object System.Collections.Generic.List[string]   # P1-2: instantanes reconcile.json par vague (source de verite de la verification)
function Add-StepResult { param([string]$Step,[string]$Status,[string]$LogPath,[string]$Details)
    $script:StepRows.Add([pscustomobject]@{
        DateUtc=(Get-Date).ToUniversalTime().ToString('s')+'Z'; Step=$Step; Status=$Status; LogPath=$LogPath; Details=$Details }) | Out-Null }

function Ensure-Folder { param([string]$P) if (-not (Test-Path -LiteralPath $P)) { New-Item -ItemType Directory -Path $P -Force | Out-Null } }
function Get-NewestFile { param([string]$Dir,[string]$Filter)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    Get-ChildItem -Path $Dir -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

# --------------------------------------------------------------------------
# Config & identites app-only
# --------------------------------------------------------------------------
function Import-KitConfig {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    . $Path
    foreach ($n in 'SourceTenantId','TargetTenantId','SourceClientId','SourceCertThumbprint',
                   'TargetClientId','TargetCertThumbprint','ClientId','CertThumbprint') {
        $v = Get-Variable -Name $n -Scope Local -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $v -and "$v".Trim() -ne '' -and "$v" -notmatch '^<.*>$') { $result[$n] = "$v" }
    }
    return $result
}

function Ensure-GraphModule {
    Write-Banner 'Etape 0 - Module Microsoft.Graph.Authentication'
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Info 'Installation du module (CurrentUser).'
        try { if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null } } catch {}
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication -Force
    Get-ChildItem $ScriptsDir -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    Write-Ok 'Module pret ; scripts debloques.'
}

function Get-AppCred {
    param([string]$TenantId)
    if ($TenantId -eq $SourceTenantId) {
        return [pscustomobject]@{ ClientId=$(if($SourceClientId){$SourceClientId}else{$ClientId}); Thumb=$(if($SourceCertThumbprint){$SourceCertThumbprint}else{$CertThumbprint}) }
    }
    if ($TenantId -eq $TargetTenantId) {
        return [pscustomobject]@{ ClientId=$(if($TargetClientId){$TargetClientId}else{$ClientId}); Thumb=$(if($TargetCertThumbprint){$TargetCertThumbprint}else{$CertThumbprint}) }
    }
    return [pscustomobject]@{ ClientId=$ClientId; Thumb=$CertThumbprint }
}

function Set-AppOnlyEnvironment {
    $env:INTUNE_AUTO_SOURCE_TENANT_ID = $SourceTenantId
    $env:INTUNE_AUTO_TARGET_TENANT_ID = $TargetTenantId
    $s = Get-AppCred -TenantId $SourceTenantId
    $t = Get-AppCred -TenantId $TargetTenantId
    if ($s.ClientId) { $env:INTUNE_AUTO_SOURCE_CLIENT_ID = $s.ClientId }
    if ($s.Thumb)    { $env:INTUNE_AUTO_SOURCE_CERT_THUMBPRINT = $s.Thumb }
    if ($t.ClientId) { $env:INTUNE_AUTO_TARGET_CLIENT_ID = $t.ClientId }
    if ($t.Thumb)    { $env:INTUNE_AUTO_TARGET_CERT_THUMBPRINT = $t.Thumb }
    if ($ClientId)       { $env:INTUNE_AUTO_CLIENT_ID = $ClientId }
    if ($CertThumbprint) { $env:INTUNE_AUTO_CERT_THUMBPRINT = $CertThumbprint }
}

function Connect-Tenant {
    param([Parameter(Mandatory)][string]$TenantId,[string]$Label,[string[]]$Scopes)
    $cred = Get-AppCred -TenantId $TenantId
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    if ($cred.ClientId -and $cred.Thumb) {
        Connect-MgGraph -TenantId $TenantId -ClientId $cred.ClientId -CertificateThumbprint $cred.Thumb -ContextScope Process -NoWelcome | Out-Null
    } elseif ($AllowInteractive) {
        Write-Warn2 ("Aucune identite app-only pour {0} : repli interactif (NON zero-touch)." -f $Label)
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
    } else {
        throw "Aucune identite app-only (ClientId + CertThumbprint) pour le tenant $TenantId ($Label). Fournir les parametres/config ou -AllowInteractive."
    }
    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.TenantId) { throw "Connexion Graph $Label invalide." }
    if ($ctx.TenantId.ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) {
        throw "Connexion $Label sur mauvais tenant. Attendu=$TenantId ; connecte=$($ctx.TenantId)" }
    $org = $null; try { $org = (Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' }).value | Select-Object -First 1 } catch {}
    $acct = if ($ctx.Account) { $ctx.Account } else { 'app-only' }
    Write-Ok ("{0} : {1} (Tenant {2}, {3})" -f $Label, $org.displayName, $ctx.TenantId, $acct)
}

# --------------------------------------------------------------------------
# Resilience Graph : backoff 429/503/504 + pagination complete + aides identite
# --------------------------------------------------------------------------
function Invoke-GraphWithRetry {
    # P1-3 : rejoue un appel Graph sur limitation transitoire (429) ou erreur passerelle (503/504). Respecte
    # Retry-After si expose, sinon backoff exponentiel plafonne a 60s + jitter. Un 429 transitoire ne produit plus Failed/ERROR.
    param([Parameter(Mandatory)][scriptblock]$Call,[int]$MaxAttempts=5)
    for ($i=1;;$i++) {
        try { return & $Call }
        catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 0) { try { $code = [int]$_.Exception.StatusCode } catch {} }
            if ($code -eq 0) {
                $msg = "$($_.Exception.Message)"
                if ($msg -match '\b(429|503|504)\b') { $code = [int]$Matches[1] }
                elseif ($msg -match '(?i)too many requests|throttl|temporarily unavailable') { $code = 429 }
            }
            if ($code -in 429,503,504 -and $i -lt $MaxAttempts) {
                $ra = 0
                try { $ra = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch {}
                if ($ra -le 0) { $ra = [int][Math]::Min([Math]::Pow(2,$i),60) }
                Write-Warn2 ("Limitation Graph (HTTP {0}) : tentative {1}/{2}, attente {3}s." -f $code,$i,$MaxAttempts,$ra)
                Start-Sleep -Seconds ([int]$ra + (Get-Random -Minimum 0 -Maximum 2))
                continue
            }
            throw
        }
    }
}

function Get-GraphAllPages {
    # P1-2 : suit @odata.nextLink pour retourner TOUS les objets (backup/verif ne doivent jamais tronquer au-dela de 999).
    param([Parameter(Mandatory)][string]$Uri)
    $all = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri $next }
        foreach ($it in @($resp.value)) { [void]$all.Add($it) }
        $next = $resp.'@odata.nextLink'
    }
    return $all.ToArray()   # deroule volontairement : chaque appelant recollecte avec @(...)
}

function Get-VerifyName {
    # Identite lisible d'un objet Intune (displayName, sinon name).
    param($Obj)
    foreach ($p in 'displayName','name') { $v = $Obj.$p; if ($v) { return [string]$v } }
    return '(sans nom)'
}
function Get-VerifyKey {
    # Cle d'identite normalisee pour croiser la presence SOURCE vs CIBLE.
    param($Obj)
    foreach ($p in 'displayName','name') { $v = $Obj.$p; if ($v) { return ([string]$v).Trim().ToLowerInvariant() } }
    return $null
}
function Test-CriticalRecord {
    # Reprend l'heuristique du moteur : Conformite / Acces conditionnel / Endpoint Security / baselines de securite.
    param($Rec)
    $fam = [string]$Rec.family; $sn = [string]$Rec.sourceName; $an = [string]$Rec.appliedName
    return ($fam -match '(?i)Compliance|ConditionalAccess|EndpointSecurity|Baseline' -or $sn -like '*aseline*' -or $an -like '*aseline*')
}

# --------------------------------------------------------------------------
# Journaux
# --------------------------------------------------------------------------
function Get-StatusSummaryText { param([string]$CsvPath)
    if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path -LiteralPath $CsvPath)) { return 'Log absent' }
    try {
        $rows = @(Import-Csv -LiteralPath $CsvPath)
        if ($rows.Count -eq 0) { return '0 ligne' }
        if (-not ($rows[0].PSObject.Properties.Name -contains 'Status')) { return ("{0} ligne(s)" -f $rows.Count) }
        return (@($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name,$_.Count }) -join '; ')
    } catch { return ("Lecture log impossible: {0}" -f $_.Exception.Message) } }

function Get-StatusCount { param([string]$CsvPath,[string]$Status)
    if (-not (Test-Path -LiteralPath $CsvPath)) { return 0 }
    try { return @((Import-Csv -LiteralPath $CsvPath) | Where-Object { $_.Status -eq $Status }).Count } catch { return 0 } }

function Invoke-Step {
    param([string]$Name,[scriptblock]$Action,[string]$LogPath,[switch]$Critical)
    Write-Banner $Name
    try {
        & $Action
        $details = Get-StatusSummaryText -CsvPath $LogPath
        Add-StepResult -Step $Name -Status 'OK' -LogPath $LogPath -Details $details
        Write-Ok $details
    } catch {
        Add-StepResult -Step $Name -Status 'ERROR' -LogPath $LogPath -Details $_.Exception.Message
        Write-Bad $_.Exception.Message
        if ($Critical) { throw }
    }
}

# --------------------------------------------------------------------------
# Etapes metier
# --------------------------------------------------------------------------
function Assert-GoodExport {
    # Garde-fou : bloque AVANT toute ecriture cible si l'export est vide ou porte la signature du bug
    # d'export (URL invalide / familles KO). Empeche un run "reussi" mais trompeur.
    param([Parameter(Mandatory)][string]$Path)
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Garde-fou export : manifest.json absent dans $Path. Import interrompu." }
    $mf = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $total = 0
    foreach ($fam in @($mf.Families)) { if ($fam.PSObject.Properties.Name -contains 'Count') { $total += [int]$fam.Count } }
    $warnPath = Join-Path $Path 'export_warnings.txt'
    if (Test-Path -LiteralPath $warnPath) {
        $w = Get-Content -LiteralPath $warnPath -Raw
        if ($w -match 'The provided URL is not valid|liste KO|element .* KO') {
            throw "Garde-fou export : $warnPath contient des erreurs Graph/URL (signature du bug d'export). Import interrompu."
        }
    }
    if ($total -le 0) { throw "Garde-fou export : 0 objet exporte. Export vide, import interrompu. Voir $Path\export_warnings.txt." }
    Write-Ok ("Export valide : {0} objets." -f $total)
}

function Invoke-Export {
    if ($SourcePath) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourcePath 'manifest.json'))) { throw "SourcePath sans manifest.json : $SourcePath" }
        $script:ActiveSource = $SourcePath
        Add-StepResult -Step 'Etape 1 - Export' -Status 'SKIPPED' -LogPath '' -Details "Export ignore, source fournie : $SourcePath"
        Write-Warn2 ("Export ignore. Source d'import = {0}" -f $SourcePath)
        return
    }
    $out = Join-Path $WorkDir ("input\Export_{0}" -f $RunStamp)
    Invoke-Step -Name 'Etape 1 - Export FRAIS depuis la SOURCE (lecture seule)' -Critical -LogPath '' -Action {
        Connect-Tenant -TenantId $SourceTenantId -Label 'SOURCE' -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All')
        & $Exporter -SourceTenantId $SourceTenantId -OutputPath $out
        Assert-GoodExport -Path $out
        $script:ActiveSource = $out
        if ($RecoverSecrets -and (Test-Path $RecoverSec)) { Write-Info 'Recuperation des secrets OMA depuis la source...'; & $RecoverSec -ExportPath $out -SourceTenantId $SourceTenantId -AssumeYes }
    }
    Write-Info ("Source d'import : {0}" -f $script:ActiveSource)
}

function Invoke-Backup {
    if ($SkipBackup) { Write-Warn2 'Sauvegarde cible ignoree.'; return }
    Invoke-Step -Name 'Etape 2 - Sauvegarde des collections CIBLE' -LogPath '' -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE' -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All')
        Ensure-Folder $BackupDir
        foreach ($e in @('deviceManagement/deviceConfigurations','deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts','deviceManagement/roleScopeTags','deviceManagement/assignmentFilters','deviceAppManagement/mobileApps','deviceAppManagement/mobileAppConfigurations','deviceAppManagement/managedAppPolicies')) {
            try {
                $v = @(Get-GraphAllPages -Uri ("https://graph.microsoft.com/beta/{0}?`$top=999" -f $e))
                ($v | ConvertTo-Json -Depth 100) | Set-Content (Join-Path $BackupDir ("{0}.json" -f ($e -replace '/','_'))) -Encoding UTF8
            } catch { Write-Warn2 ("Sauvegarde {0} : {1}" -f $e, $_.Exception.Message) }
        }
        Write-Ok ("Sauvegarde ecrite : {0}" -f $BackupDir)
    }
}

function Invoke-Cleanup {
    if ($SkipCleanup -or [string]::IsNullOrWhiteSpace($ImportReport)) { Write-Warn2 'Nettoyage ignore (pas de rapport).'; return }
    if (-not (Test-Path -LiteralPath $ImportReport)) { Write-Warn2 ("Rapport de nettoyage introuvable : {0}" -f $ImportReport); return }
    $previewLog = Join-Path $LogsDir '01_cleanup_preview.csv'
    $execLog    = Join-Path $LogsDir '02_cleanup_execute.csv'
    $cleanArgs = @{ ReportPath=$ImportReport; TargetTenantId=$TargetTenantId }
    if ($PSBoundParameters.ContainsKey('ImportStartUtc')) { $cleanArgs['ImportStartUtc'] = $ImportStartUtc }
    if ($PSBoundParameters.ContainsKey('ImportEndUtc'))   { $cleanArgs['ImportEndUtc']   = $ImportEndUtc }

    Invoke-Step -Name 'Etape 3A - Nettoyage (apercu)' -Critical -LogPath $previewLog -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE'
        & $Cleanup @cleanArgs -LogPath $previewLog }
    if ($Preview) { Write-Warn2 'Mode Preview : nettoyage reel ignore.'; return }
    Invoke-Step -Name 'Etape 3B - Nettoyage (execution)' -Critical -LogPath $execLog -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE'
        & $Cleanup @cleanArgs -Execute -Force -LogPath $execLog }
}

function Invoke-Preflight {
    if ($SkipPreflight) { Write-Warn2 'Preflight ignore.'; return }
    $log = Join-Path $LogsDir '04_preflight_all.csv'
    $extra = @{}; if ($IncludeScopeTags) { $extra['IncludeScopeTags'] = $true }
    Invoke-Step -Name 'Etape 4 - Prevalidation complete (aucune ecriture)' -Critical -LogPath $log -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE'
        & $Engine -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase All -LogPath $log @extra }
}

function Invoke-Wave {
    param([string]$Phase,[string]$LogName)
    $log = Join-Path $LogsDir $LogName
    $recon = Join-Path $LogsDir 'reconcile.json'
    $extra = @{}; if ($IncludeScopeTags) { $extra['IncludeScopeTags'] = $true }
    if (-not $Preview) { $extra['Execute'] = $true }
    Remove-Item -LiteralPath $recon -Force -ErrorAction SilentlyContinue   # evite d'instantaner un reconcile perime (preflight/vague precedente)
    Invoke-Step -Name ("Etape 5 - Import vague : {0}{1}" -f $Phase, $(if($Preview){' (PREVIEW)'}else{''})) -LogPath $log -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE'
        & $Engine -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase $Phase -AppIdMapPath (Join-Path $LogsDir 'AppIdMap.csv') -LogPath $log @extra }
    if (Test-Path -LiteralPath $recon) {   # P1-2 : conserve le reconcile.json de CETTE vague comme source de verite de la verification
        $snap = Join-Path $LogsDir ("reconcile_{0}.json" -f $Phase)
        Copy-Item -LiteralPath $recon -Destination $snap -Force
        if (-not $script:ReconSnapshots.Contains($snap)) { $script:ReconSnapshots.Add($snap) | Out-Null }
    }
    $err = Get-StatusCount -CsvPath $log -Status 'ERROR'
    if ($err -gt 0 -and $StopOnImportErrors) { throw "Import $Phase : $err erreur(s) et -StopOnImportErrors actif." }
}

function Invoke-AppIdMap {
    if ($SkipAppIdMap) { return }
    $csv = Join-Path $LogsDir 'AppIdMap.csv'
    Invoke-Step -Name 'Etape 5C - Mapping applications SourceId -> TargetId (audit)' -LogPath '' -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'CIBLE'
        & $AppMap -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -OutputCsv $csv
        Write-Ok ("AppIdMap : {0}" -f $csv) }
}

function Invoke-Assignments {
    if ($SkipAssignments) { Write-Warn2 'Affectations ignorees.'; return }
    Ensure-Folder $AssignRoot
    $log = Join-Path $LogsDir '10_assignments.csv'
    $extra = @{}
    if (-not $Preview) { $extra['Execute'] = $true }
    if ($StaticOnlyGroups) { $extra['StaticOnlyGroups'] = $true }
    Invoke-Step -Name ("Etape 6 - Affectations (groupes + assignments){0}" -f $(if($Preview){' (PREVIEW)'}else{''})) -LogPath $log -Action {
        & $Assign -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All -AssignmentsPath $AssignmentsDir -LogPath $log @extra }
}

function Invoke-Verification {
    if ($SkipVerification) { Write-Warn2 'Verification finale ignoree.'; return }
    $log = Join-Path $LogsDir '11_verification.csv'
    Invoke-Step -Name 'Etape 7 - Verification finale SOURCE vs CIBLE (identite/resultat)' -LogPath $log -Action {
        $rows = @()
        # Source de verite privilegiee : instantanes reconcile.json par vague (P1-1). Base sur le RESULTAT, jamais
        # sur des comptes naifs (un objet preexistant cible ne peut masquer un import manque ; Failed/Skipped/OutOfScope nommes).
        $snaps = @($script:ReconSnapshots | Where-Object { Test-Path -LiteralPath $_ })
        if ($snaps.Count -gt 0) {
            $agg = [ordered]@{ Matched=0; Created=0; Failed=0; Skipped=0; Preview=0; OutOfScope=0 }
            $critLines = @()
            $gapRows = New-Object System.Collections.Generic.List[object]
            foreach ($f in $snaps) {
                $doc = $null; try { $doc = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch {}
                if ($null -eq $doc) { continue }
                $phase = [string]$doc.phase
                foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) {
                    $val = 0; try { $val = [int]$doc.summary.$o } catch {}; $agg[$o] += $val
                }
                $recs    = @($doc.records)
                # Une CA creee DESACTIVEE (reason 'manual-enable-required') n'est PAS un clone abouti -> ecart, pas applique.
                $gaps    = @($recs | Where-Object { ($_.outcome -in @('Failed','Skipped','OutOfScope')) -or ($_.reason -match 'manual-enable-required') })
                $applied = @($recs | Where-Object { ($_.outcome -in @('Matched','Created')) -and ($_.reason -notmatch 'manual-enable-required') }).Count
                $missing = (@($gaps | ForEach-Object { $_.sourceName }) -join '; ')
                $rows += [pscustomobject]@{ Endpoint=("Phase: {0}" -f $phase); Source=$recs.Count; Cible=$applied; Missing=$missing; Status=$(if($gaps.Count -eq 0){'OK'}else{'ECART'}) }
                foreach ($g in $gaps) {
                    $crit = Test-CriticalRecord $g
                    $gapRows.Add([pscustomobject]@{ Endpoint=("{0} / {1}" -f $phase,$g.family); Source=$g.sourceName; Cible=$g.outcome; Missing=$g.reason; Status=$(if($crit){'CRITICAL'}else{'GAP'}) }) | Out-Null
                    if ($crit) { $critLines += ("{0} | {1} -> {2} ({3})" -f $g.family,$g.sourceName,$g.outcome,$g.reason) }
                }
            }
            foreach ($gr in $gapRows) { $rows += $gr }
            Write-Info ("Reconcile (verite import) : Matched={0} Created={1} Failed={2} Skipped={3} Preview={4} OutOfScope={5}" -f $agg.Matched,$agg.Created,$agg.Failed,$agg.Skipped,$agg.Preview,$agg.OutOfScope)
            if ($critLines.Count -gt 0) {
                Write-Bad ("SECURITE-CRITIQUE non applique ({0}) :" -f $critLines.Count)
                foreach ($l in $critLines) { Write-Bad ("  [!] {0}" -f $l) }
            } elseif (($agg.Failed + $agg.Skipped + $agg.OutOfScope) -gt 0) {
                Write-Warn2 ("Ecarts a examiner (Failed/Skipped/OutOfScope) : {0}" -f ($agg.Failed + $agg.Skipped + $agg.OutOfScope))
            }
        } else {
            # Repli (aucun reconcile.json produit) : croiser SOURCE vs CIBLE par cle d'IDENTITE (nom). Un objet
            # preexistant cible ne peut masquer un import manque : chaque cle source sans correspondance est nommee (ECART).
            function Read-EndpointObjects { param([string]$TenantId,[string]$Label)
                Connect-Tenant -TenantId $TenantId -Label $Label -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All')
                $h = @{}
                foreach ($e in $VerifyEndpoints) {
                    try { $h[$e] = @(Get-GraphAllPages -Uri ("https://graph.microsoft.com/beta/{0}?`$top=999" -f $e)) }
                    catch { $h[$e] = $null }
                }
                return $h
            }
            $srcMap = Read-EndpointObjects -TenantId $SourceTenantId -Label 'SOURCE (verif)'
            $tgtMap = Read-EndpointObjects -TenantId $TargetTenantId -Label 'CIBLE (verif)'
            foreach ($e in $VerifyEndpoints) {
                $srcObjs = $srcMap[$e]; $tgtObjs = $tgtMap[$e]
                if ($null -eq $srcObjs -or $null -eq $tgtObjs) {
                    $rows += [pscustomobject]@{ Endpoint=$e; Source=$(if($null -eq $srcObjs){'ERR'}else{@($srcObjs).Count}); Cible=$(if($null -eq $tgtObjs){'ERR'}else{@($tgtObjs).Count}); Missing='erreur de lecture'; Status='ERROR-READ' }
                    continue
                }
                $tgtKeys = @{}
                foreach ($o in $tgtObjs) { $k = Get-VerifyKey $o; if ($k) { $tgtKeys[$k] = $true } }
                $missing = New-Object System.Collections.Generic.List[string]
                foreach ($o in $srcObjs) {
                    $k = Get-VerifyKey $o
                    if ($k -and -not $tgtKeys.ContainsKey($k)) { $missing.Add((Get-VerifyName $o)) | Out-Null }
                }
                $rows += [pscustomobject]@{ Endpoint=$e; Source=@($srcObjs).Count; Cible=@($tgtObjs).Count; Missing=($missing -join '; '); Status=$(if($missing.Count -eq 0){'OK'}else{'ECART'}) }
                if ($missing.Count -gt 0) { Write-Warn2 ("{0} : {1} objet(s) source absent(s) de la cible -> {2}" -f $e,$missing.Count,($missing -join '; ')) }
            }
        }
        $rows | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
        $rows | Format-Table -Auto | Out-Host
    }
}

# --------------------------------------------------------------------------
# Rapport HTML
# --------------------------------------------------------------------------
function HtmlEnc { param([string]$T) if ($null -eq $T) { return '' } [System.Net.WebUtility]::HtmlEncode($T) }

function New-FinalReport {
    Write-Banner 'Rapport final'
    Ensure-Folder $OutputDir
    $script:StepRows | Export-Csv -LiteralPath $SummaryCsv -NoTypeInformation -Encoding UTF8

    $logFiles = @(Get-ChildItem -Path $LogsDir -Filter '*.csv' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $statusRows = New-Object System.Collections.Generic.List[object]
    $errorRows  = New-Object System.Collections.Generic.List[object]
    foreach ($log in $logFiles) {
        try {
            $rows = @(Import-Csv -LiteralPath $log.FullName)
            if ($rows.Count -eq 0 -or -not ($rows[0].PSObject.Properties.Name -contains 'Status')) { continue }
            foreach ($g in ($rows | Group-Object Status | Sort-Object Name)) {
                $statusRows.Add([pscustomobject]@{ Log=$log.Name; Status=$g.Name; Count=$g.Count }) | Out-Null }
            foreach ($r in @($rows | Where-Object { $_.Status -eq 'ERROR' })) {
                $errorRows.Add([pscustomobject]@{ Log=$log.Name; Name=$r.Name; Family=$r.Family; Reason=$($r.Reason + ' ' + $r.Error + ' ' + $r.ErrorMessage) }) | Out-Null }
        } catch {}
    }
    function SumWhere { param([scriptblock]$P) $s = (@($statusRows | Where-Object $P) | Measure-Object Count -Sum).Sum; if ($null -eq $s) { 0 } else { $s } }
    $nCreated = SumWhere { $_.Status -eq 'CREATED' }
    $nExists  = SumWhere { $_.Status -eq 'EXISTS' }
    $nApplied = SumWhere { $_.Status -eq 'APPLIED' }
    $nSkipped = SumWhere { $_.Status -like 'SKIP*' }
    $nPreview = SumWhere { $_.Status -eq 'PREVIEW' }
    $nErrors  = SumWhere { $_.Status -eq 'ERROR' }

    $stepHtml = ($script:StepRows | ForEach-Object {
        '<tr><td>{0}</td><td><span class="badge {1}">{2}</span></td><td>{3}</td><td>{4}</td></tr>' -f `
            (HtmlEnc $_.Step), ($_.Status.ToLowerInvariant()), (HtmlEnc $_.Status), (HtmlEnc $_.Details), (HtmlEnc $_.LogPath) }) -join "`n"
    $statusHtml = ($statusRows | ForEach-Object {
        '<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f (HtmlEnc $_.Log), (HtmlEnc $_.Status), $_.Count }) -join "`n"
    $errorHtml = if ($errorRows.Count -gt 0) {
        ($errorRows | Select-Object -First 400 | ForEach-Object {
            '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f (HtmlEnc $_.Log), (HtmlEnc $_.Family), (HtmlEnc $_.Name), (HtmlEnc $_.Reason) }) -join "`n"
    } else { '<tr><td colspan="4">Aucune erreur dans les journaux.</td></tr>' }

    $verifyHtml = ''
    $verifyLog = Join-Path $LogsDir '11_verification.csv'
    if (Test-Path -LiteralPath $verifyLog) {
        $verifyHtml = (@(Import-Csv -LiteralPath $verifyLog) | ForEach-Object {
            $st = [string]$_.Status
            $cls = if ($st -eq 'OK') { 'ok' } elseif ($st -like 'SKIP*') { 'skipped' } else { 'error' }
            '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td><span class="badge {4}">{5}</span></td></tr>' -f (HtmlEnc $_.Endpoint), (HtmlEnc $_.Source), (HtmlEnc $_.Cible), (HtmlEnc $_.Missing), $cls, (HtmlEnc $st) }) -join "`n"
    }
    $verifySection = if ($verifyHtml) {
        "<section class='card'><h2>Verification SOURCE vs CIBLE (identite/resultat)</h2><table><thead><tr><th>Portee</th><th>Source</th><th>Cible</th><th>Manquant / ecart</th><th>Statut</th></tr></thead><tbody>$verifyHtml</tbody></table></section>"
    } else { '' }

    $mode = if ($Preview) { 'PREVIEW (aucune ecriture)' } else { 'EXECUTION' }
    $html = @"
<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport execution zero-touch - intune-tenant-clone-kit</title>
<style>
:root{--bg:#0b1220;--card:#121c31;--text:#eaf0ff;--muted:#9fb1d1;--line:#2b3a5f;--ok:#14b866;--warn:#f6c945;--bad:#ff5c6c}
body{margin:0;background:linear-gradient(135deg,#07101f,#12264f);color:var(--text);font-family:Segoe UI,Arial,sans-serif}
header{padding:30px 40px;border-bottom:1px solid var(--line)}h1{margin:0;font-size:26px}.sub{color:var(--muted);margin-top:8px}
.wrap{padding:26px 40px}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:14px}
.card{background:rgba(18,28,49,.92);border:1px solid var(--line);border-radius:16px;padding:16px;box-shadow:0 14px 40px rgba(0,0,0,.25)}
.metric{font-size:30px;font-weight:700}.label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}
section{margin-top:20px}table{width:100%;border-collapse:collapse;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:9px 8px;vertical-align:top}
th{text-align:left;color:#c8d7ff;background:#17233c}.badge{display:inline-block;border-radius:999px;padding:3px 10px;font-weight:600}
.badge.ok{background:rgba(20,184,102,.16);color:var(--ok)}.badge.error{background:rgba(255,92,108,.16);color:var(--bad)}.badge.skipped{background:rgba(246,201,69,.16);color:var(--warn)}
.oktext{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.note{color:var(--muted);line-height:1.6}
</style></head><body>
<header><h1>Execution zero-touch - Clone Intune SOURCE vers CIBLE</h1>
<div class="sub">Execution $RunStamp - Mode $mode - Source $(HtmlEnc $SourceTenantId) -> Cible $(HtmlEnc $TargetTenantId)</div></header>
<div class="wrap">
  <div class="grid">
    <div class="card"><div class="label">CREATED</div><div class="metric oktext">$nCreated</div></div>
    <div class="card"><div class="label">EXISTS</div><div class="metric">$nExists</div></div>
    <div class="card"><div class="label">APPLIED (affect.)</div><div class="metric oktext">$nApplied</div></div>
    <div class="card"><div class="label">SKIPPED / manuel</div><div class="metric warn">$nSkipped</div></div>
    <div class="card"><div class="label">ERROR</div><div class="metric bad">$nErrors</div></div>
  </div>
  <section class="card"><h2>Etapes executees</h2>
    <table><thead><tr><th>Etape</th><th>Statut</th><th>Details</th><th>Journal</th></tr></thead><tbody>$stepHtml</tbody></table></section>
  <section class="card"><h2>Synthese par journal</h2>
    <table><thead><tr><th>Journal</th><th>Statut</th><th>Nombre</th></tr></thead><tbody>$statusHtml</tbody></table></section>
  $verifySection
  <section class="card"><h2>Erreurs a traiter</h2>
    <table><thead><tr><th>Journal</th><th>Famille</th><th>Objet</th><th>Message</th></tr></thead><tbody>$errorHtml</tbody></table></section>
  <section class="card"><h2>Reste manuel (limites Intune)</h2>
    <p class="note">Profils a secret (Wi-Fi/PSK, AppLocker/WDAC, OMA chiffre), apps LOB/Win32/VPP (binaires),
    Admin Templates, Endpoint Security (intents) et Enrollment ne sont pas clonables par metadata seule et
    restent a recreer manuellement. PREVIEW=$nPreview objet(s) simule(s).</p></section>
</div></body></html>
"@
    Set-Content -LiteralPath $FinalReport -Value $html -Encoding UTF8
    Write-Ok ("Rapport HTML : {0}" -f $FinalReport)
    Write-Ok ("Synthese CSV : {0}" -f $SummaryCsv)
}

# --------------------------------------------------------------------------
# PRINCIPAL
# --------------------------------------------------------------------------
try {
    Ensure-Folder $WorkDir; Ensure-Folder $LogsDir; Ensure-Folder $OutputDir
    Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null

    # Config -> comble les parametres non fournis
    $cfg = Import-KitConfig -Path $ConfigFile
    foreach ($k in $cfg.Keys) { if (-not $PSBoundParameters.ContainsKey($k) -and -not (Get-Variable $k -ValueOnly -EA SilentlyContinue)) { Set-Variable -Name $k -Value $cfg[$k] } }

    Write-Banner 'ORCHESTRATEUR ZERO-TOUCH - intune-tenant-clone-kit' 'Green'
    Write-Info ("KitRoot : {0}" -f $KitRoot)
    Write-Info ("WorkDir : {0}" -f $WorkDir)
    Write-Info ("Mode    : {0}" -f $(if($Preview){'PREVIEW (aucune ecriture)'}else{'EXECUTION'}))

    if (-not $SourceTenantId) { throw 'SourceTenantId manquant (parametre ou config.ps1).' }
    if (-not $TargetTenantId) { throw 'TargetTenantId manquant (parametre ou config.ps1).' }
    if ($SourceTenantId -eq $TargetTenantId) { throw 'SOURCE et CIBLE identiques : refuse.' }
    foreach ($p in @($Engine,$Exporter,$Cleanup,$AppMap,$Assign)) { if (-not (Test-Path -LiteralPath $p)) { throw "Script requis introuvable : $p" } }

    $src = Get-AppCred -TenantId $SourceTenantId
    $tgt = Get-AppCred -TenantId $TargetTenantId
    if (-not $AllowInteractive) {
        if (-not ($src.ClientId -and $src.Thumb)) { throw "Identite app-only SOURCE absente (SourceClientId/SourceCertThumbprint ou ClientId/CertThumbprint)." }
        if (-not ($tgt.ClientId -and $tgt.Thumb)) { throw "Identite app-only CIBLE absente (TargetClientId/TargetCertThumbprint ou ClientId/CertThumbprint)." }
    }

    Set-AppOnlyEnvironment
    Ensure-GraphModule

    # Auto-detection du rapport de nettoyage si non fourni
    if (-not $SkipCleanup -and [string]::IsNullOrWhiteSpace($ImportReport)) {
        $auto = Get-NewestFile -Directory (Join-Path $KitRoot 'input') -Filter 'RAPPORT-IMPORT*.txt'
        if ($auto) { $ImportReport = $auto.FullName; Write-Info ("Rapport de nettoyage detecte : {0}" -f $ImportReport) }
    }

    $script:ActiveSource = $null
    Invoke-Export
    Invoke-Backup
    Invoke-Cleanup
    Invoke-Preflight

    Invoke-Wave -Phase 'Foundation' -LogName '05_import_foundation.csv'
    if (-not $SkipApps) { Invoke-Wave -Phase 'Apps' -LogName '06_import_apps.csv' } else { Write-Warn2 'Import Apps ignore.' }
    Invoke-AppIdMap
    Invoke-Wave -Phase 'Policies' -LogName '07_import_policies.csv'
    if (-not $SkipScripts) { Invoke-Wave -Phase 'Scripts' -LogName '08_import_scripts.csv' } else { Write-Warn2 'Import Scripts ignore.' }
    if (-not $SkipMobile)  { Invoke-Wave -Phase 'Mobile'  -LogName '09_import_mobile.csv' }  else { Write-Warn2 'Import Mobile ignore.' }

    Invoke-Assignments
    Invoke-Verification

    if ($UseAIAssist) {
        # L'etape IA tourne en DRY-RUN par conception : sans -SendToProvider => AUCUN appel externe
        # (elle n'ecrit que des metadonnees expurgees en local). L'envoi externe reste une decision
        # humaine explicite et separee. Meme si -RecoverSecrets a rehydrate des secrets OMA sur disque
        # sous $script:ActiveSource, rien ne quitte la machine ici car -SendToProvider n'est PAS passe.
        Invoke-Step -Name 'Etape 8 - Assistant IA de recreation (optionnel)' -LogPath '' -Action {
            & $AIAssist -ExportPath $script:ActiveSource -OutputPath (Join-Path $OutputDir 'ai') -Language 'fr'
        }
    }

    New-FinalReport
    Write-Banner 'Execution terminee' 'Green'
    Write-Host ("Rapport : {0}" -f $FinalReport) -ForegroundColor Green
    Write-Host ("Logs    : {0}" -f $LogsDir) -ForegroundColor Green
}
catch {
    Write-Bad $_.Exception.Message
    try { New-FinalReport } catch {}
    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}

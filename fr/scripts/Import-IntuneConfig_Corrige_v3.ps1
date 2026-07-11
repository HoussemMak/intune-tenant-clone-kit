#Requires -Version 7.0
<#
.SYNOPSIS
    Moteur d'import Intune CORRIGE (v3) — clone SOURCE -> CIBLE.
    Corrige les bugs confirmes du v1.1/v1.2 :
      - Settings Catalog : POST UNIQUE avec settings INLINE (jamais le two-step /{id}/settings).
      - Preservation stricte des tableaux (children:[], roleScopeTagIds) : lecture -AsHashtable,
        AUCUNE reconstruction recursive d'arbre.
      - Compliance : retrait des tableaux vides + INJECTION de scheduledActionsForRule (action block).
      - Device Config a secret (secretReferenceValueId) : SKIP (traitement manuel).
      - Scripts/Remediations a contenu vide : SKIP (rehydrater d'abord).
      - Idempotence par nom (EXISTS -> SKIP), journal CSV, PREVIEW par defaut.

    PREREQUIS : PowerShell 7, module Microsoft.Graph.Authentication, connexion Connect-MgGraph
    deja etablie sur le tenant CIBLE (TEST) avant l'appel (voir le RUNBOOK).

    IMPORTANT : lancer TOUJOURS en PREVIEW (sans -Execute) d'abord. Verifier le CSV, puis -Execute.

.PARAMETER SourcePath
    Dossier de l'export REHYDRATE (FixedExport) contenant 01_.. 13_.. .

.PARAMETER TargetTenantId
    GUID du tenant cible (TEST). Garde-fou : refuse si le contexte courant != cette valeur.

.PARAMETER SourceTenantId
    GUID du tenant source (PROD). Garde-fou : refuse si cible == source.

.PARAMETER Phase
    Foundation | Apps | Policies | Scripts | Mobile | All   (defaut All)

.PARAMETER Execute
    Ecriture reelle. Absent = PREVIEW (aucun POST).

.PARAMETER IncludeScopeTags
    Conserve roleScopeTagIds (sinon retire -> Graph applique le defaut ["0"]).

.PARAMETER LogPath
    Fichier CSV de journal. Defaut : .\logs\import_v3_<horodatage>.csv

.EXAMPLE
    .\Import-IntuneConfig_Corrige_v3.ps1 -SourcePath .\FixedExport -TargetTenantId <TARGET_TENANT_ID> -SourceTenantId <SOURCE_TENANT_ID> -Phase Policies
    .\Import-IntuneConfig_Corrige_v3.ps1 -SourcePath .\FixedExport -TargetTenantId <TARGET_TENANT_ID> -SourceTenantId <SOURCE_TENANT_ID> -Phase Policies -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$TargetTenantId,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [ValidateSet('Foundation','Apps','Policies','Scripts','Mobile','All')][string]$Phase = 'All',
    [switch]$Execute,
    [switch]$IncludeScopeTags,
    [string]$NamePrefix = '',
    [string]$AppIdMapPath = '',
    [string]$CaIdMapPath = '',
    [string]$LogPath = (Join-Path (Get-Location) ("logs\import_v3_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:SourceFileCount = 0        # P1-1 : compte independant des fichiers SOURCE enumeres par dossier traite (vraie garde de completude)
$script:SourceSeenCount = 0        # P1-1 : nombre d'objets SOURCE reellement parcourus (invariant de completude)
$script:ReconExitCode   = 0        # P1-1 : 2 => securite-critique NON appliquee (pose tout a la fin, -Execute seulement)
$script:RemapLog        = $null    # P1-1 : trace de remap old->new par objet (reinitialisee dans la boucle de fichiers)
# 14_AdminTemplates (ADMX) — caches du catalogue CIBLE + stash par objet des definitionValues source.
# Les definitionValues DOIVENT etre captures AVANT que Build-Payload ne les Strip (Remove-TopKeys mute $obj
# en place) : New-AdminTemplatePayload les stashe ici pour le post-create / le dry-run PREVIEW.
$script:AdmxDefCache    = $null    # dict : 'displayName|classType|categoryPath' (minuscule) -> id de groupPolicyDefinition CIBLE
$script:AdmxPresCache   = @{}      # dict : id def CIBLE -> tableau des presentations CIBLE de cette definition
$script:AdminDefValues  = @()      # stash par objet des definitionValues SOURCE (reinitialise dans la boucle de fichiers)

function Invoke-GraphWithRetry {
    # P1-3 : retry transitoire sur throttling / erreurs serveur (429/503/504). Un 429 transitoire ne doit
    # PLUS produire un ERROR/Failed. Detection du code HTTP defensive (Invoke-MgGraphRequest leve des formes
    # d'exception differentes selon la version du module) avec repli sur le message.
    param([Parameter(Mandatory)][scriptblock]$Call,[int]$MaxAttempts=5)
    for ($i=1;;$i++) {
        try { return & $Call }
        catch {
            $ex = $_.Exception
            $code = 0
            # a) forme classique HttpResponseMessage.StatusCode
            try { if ($ex.Response -and $ex.Response.StatusCode) { $code = [int]$ex.Response.StatusCode } } catch {}
            # b) certaines versions exposent StatusCode directement sur l'exception
            if ($code -eq 0) { try { if ($ex.StatusCode) { $code = [int]$ex.StatusCode } } catch {} }
            # c) repli : detecter le code / libelle dans le message
            if ($code -eq 0) {
                $msg = [string]$ex.Message
                if     ($msg -match '(?i)\b429\b|too\s*many\s*requests|throttl') { $code = 429 }
                elseif ($msg -match '(?i)\b503\b|service\s*unavailable')         { $code = 503 }
                elseif ($msg -match '(?i)\b504\b|gateway\s*time-?out')           { $code = 504 }
            }
            if (($code -in 429,503,504) -and ($i -lt $MaxAttempts)) {
                $ra = 0
                try { if ($ex.Response.Headers.RetryAfter.Delta) { $ra = [int]$ex.Response.Headers.RetryAfter.Delta.TotalSeconds } } catch {}
                if ($ra -le 0) { $ra = [int][Math]::Min([Math]::Pow(2,$i),60) }   # backoff exponentiel plafonne a 60s
                Start-Sleep -Seconds ([int]$ra + (Get-Random -Minimum 0 -Maximum 2))
                continue
            }
            throw
        }
    }
}

# Cartographie SourceId -> TargetId des apps (pour remapper targetedMobileApps des AppConfigurations).
$script:AppIdMap = @{}
if ($AppIdMapPath -and (Test-Path -LiteralPath $AppIdMapPath)) {
    try { Import-Csv -LiteralPath $AppIdMapPath | ForEach-Object { if ($_.SourceId) { $script:AppIdMap[[string]$_.SourceId] = [string]$_.TargetId } } }
    catch { Write-Host ("  [!] AppIdMap illisible ({0}) : {1}" -f $AppIdMapPath,$_.Exception.Message) -ForegroundColor Yellow }
}

# --- Remap des references Conditional Access (P0-5) : table plate GUID-SOURCE -> GUID-CIBLE pour les
#     references CA TENANT-SCOPED (groupes, users, named-locations, apps d'entreprise custom, terms-of-use).
#     Chargee depuis un CSV optionnel (colonnes SourceId,TargetId). FAIL-CLOSED : toute reference
#     tenant-scoped absente de cette table (ou sans table du tout) est traitee comme NON RESOLUE et la
#     policy CA est REFUSEE (jamais emise avec un GUID source). Les CONSTANTES inter-tenant (role
#     TEMPLATES, apps Microsoft bien connues, jetons speciaux) passent inchangees et ne sont JAMAIS
#     cherchees ici.
$script:CaIdMap = @{}
if ($CaIdMapPath -and (Test-Path -LiteralPath $CaIdMapPath)) {
    try { Import-Csv -LiteralPath $CaIdMapPath | ForEach-Object { if ($_.SourceId) { $script:CaIdMap[[string]$_.SourceId] = [string]$_.TargetId } } }
    catch { Write-Host ("  [!] CaIdMap illisible ({0}) : {1}" -f $CaIdMapPath,$_.Exception.Message) -ForegroundColor Yellow }
}
# CONSTANTES inter-tenant qui doivent traverser une policy CA inchangees (pas des GUID tenant-scoped).
$script:CaSpecialUsers     = @('All','None','GuestsOrExternalUsers')
$script:CaSpecialLocations = @('All','AllTrusted')
# Les appId Microsoft first-party bien connus sont GLOBAUX (identiques dans chaque tenant) -> passent inchanges.
$script:CaWellKnownAppIds  = @(
    '00000002-0000-0ff1-ce00-000000000000', # Office 365 Exchange Online
    '00000003-0000-0ff1-ce00-000000000000', # Office 365 SharePoint Online
    '00000004-0000-0ff1-ce00-000000000000', # Skype for Business Online
    '00000005-0000-0ff1-ce00-000000000000', # Office 365 Yammer
    '00000006-0000-0ff1-ce00-000000000000', # Office 365 Portal
    '00000007-0000-0ff1-ce00-000000000000', # Dynamics CRM Online
    '00000003-0000-0000-c000-000000000000', # Microsoft Graph
    '00000009-0000-0000-c000-000000000000', # Power BI Service
    '0000000a-0000-0000-c000-000000000000', # Microsoft Intune
    '00000012-0000-0000-c000-000000000000', # Microsoft Rights Management Services
    '797f4846-ba00-4fd7-ba43-dac1f8f63013', # Windows Azure Service Management API
    'c44b4083-3bb0-49c1-b47d-974e53cbdf3c', # Microsoft Azure Portal
    '1fec8e78-bce4-4aaf-ab1b-5451cc387264', # Microsoft Teams
    'cc15fd57-2c6c-4117-a88c-83b1d56b4bbe', # Microsoft Teams Services
    'd4ebce55-015a-49b5-a083-c84d1797ae8c'  # Microsoft Intune Enrollment
)
$script:CaConstantApps = @('All','None','Office365','MicrosoftAdminPortals') + $script:CaWellKnownAppIds
# Les ids de politique d'authentication strength integres sont des constantes GLOBALES (identiques dans chaque tenant) -> passent inchanges.
$script:CaBuiltInAuthStrength = @(
    '00000000-0000-0000-0000-000000000002', # Multifactor authentication
    '00000000-0000-0000-0000-000000000003', # Passwordless MFA
    '00000000-0000-0000-0000-000000000004'  # Phishing-resistant MFA
)

# Types d'apps NON clonables par metadata seule (contenu binaire / licence) -> manuel.
$AppTypesManual = @(
    '#microsoft.graph.win32LobApp','#microsoft.graph.win32CatalogApp','#microsoft.graph.iosLobApp',
    '#microsoft.graph.androidLobApp','#microsoft.graph.windowsMobileMSI','#microsoft.graph.windowsAppX',
    '#microsoft.graph.windowsUniversalAppX','#microsoft.graph.macOSLobApp','#microsoft.graph.macOSPkgApp',
    '#microsoft.graph.macOSDmgApp','#microsoft.graph.iosVppApp','#microsoft.graph.macOsVppApp',
    '#microsoft.graph.androidManagedStoreApp'
)

# Catalogue : dossier -> endpoint, propriete de nom, phase, champs a retirer au create.
$Catalog = @(
    @{ Folder='07_Filters';               Path='deviceManagement/assignmentFilters';                 Name='displayName'; Phase='Foundation'; Key='platform';     Strip=@('id','createdDateTime','lastModifiedDateTime','payloads','assignments','exportWarnings') }
    @{ Folder='08_ScopeTags';             Path='deviceManagement/roleScopeTags';                      Name='displayName'; Phase='Foundation'; Strip=@('id','isBuiltIn','exportWarnings') }
    @{ Folder='09_Apps';                  Path='deviceAppManagement/mobileApps';                      Name='displayName'; Phase='Apps';       Key='@odata.type'; Strip=@('id','createdDateTime','lastModifiedDateTime','uploadState','publishingState','isAssigned','dependentAppCount','supersedingAppCount','supersededAppCount','committedContentVersion','size','assignments','revokeLicenseActionResults','exportWarnings'); Special='App' }
    @{ Folder='01_DeviceConfigurations';  Path='deviceManagement/deviceConfigurations';               Name='displayName'; Phase='Policies';   Key='@odata.type'; Strip=@('id','createdDateTime','lastModifiedDateTime','version','supportsScopeTags','assignments','exportWarnings'); Special='DeviceConfig' }
    @{ Folder='02_ConfigurationPolicies'; Path='deviceManagement/configurationPolicies';              Name='name';        Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','settingCount','assignments','isAssigned','exportWarnings'); Special='SettingsCatalog' }
    @{ Folder='03_CompliancePolicies';    Path='deviceManagement/deviceCompliancePolicies';           Name='displayName'; Phase='Policies';   Key='@odata.type'; Strip=@('id','createdDateTime','lastModifiedDateTime','version','assignments','exportWarnings'); Special='Compliance' }
    @{ Folder='04_ScriptsPowerShell';     Path='deviceManagement/deviceManagementScripts';            Name='displayName'; Phase='Scripts';    Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings'); Special='Script' }
    @{ Folder='05_ScriptsShell';          Path='deviceManagement/deviceShellScripts';                 Name='displayName'; Phase='Scripts';    Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings'); Special='Script' }
    @{ Folder='06_Remediations';          Path='deviceManagement/deviceHealthScripts';                Name='displayName'; Phase='Scripts';    Strip=@('id','createdDateTime','lastModifiedDateTime','highestAvailableVersion','isGlobalScript','assignments','exportWarnings'); Special='Remediation' }
    @{ Folder='10_AppConfigurations';     Path='deviceAppManagement/mobileAppConfigurations';         Name='displayName'; Phase='Mobile';     Key='@odata.type'; Strip=@('id','createdDateTime','lastModifiedDateTime','version','assignments','exportWarnings'); Special='AppConfig' }
    @{ Folder='11_AppProtection';         Path='deviceAppManagement/managedAppPolicies';              Name='displayName'; Phase='Mobile';     Key='@odata.type'; Strip=@('id','createdDateTime','lastModifiedDateTime','version','deployedAppCount','assignments','exportWarnings') }
    @{ Folder='12_AutopilotProfiles';     Path='deviceManagement/windowsAutopilotDeploymentProfiles'; Name='displayName'; Phase='Mobile';     Strip=@('id','createdDateTime','lastModifiedDateTime','managementServiceAppId','assignments','exportWarnings') }
    @{ Folder='13_NotificationTemplates'; Path='deviceManagement/notificationMessageTemplates';       Name='displayName'; Phase='Mobile';     Strip=@('id','lastModifiedDateTime','localizedNotificationMessages','exportWarnings'); Special='Notification' }
    @{ Folder='17_FeatureUpdateProfiles'; Path='deviceManagement/windowsFeatureUpdateProfiles'; Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings','deployableContentDisplayName','endOfSupportDate') }
    @{ Folder='18_QualityUpdateProfiles'; Path='deviceManagement/windowsQualityUpdateProfiles'; Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings') }
    @{ Folder='19_DriverUpdateProfiles';  Path='deviceManagement/windowsDriverUpdateProfiles';  Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings','newUpdates') }
    @{ Folder='20_TermsAndConditions';    Path='deviceManagement/termsAndConditions';            Name='displayName'; Phase='Mobile';     Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings','modifiedDateTime') }
    @{ Folder='21_DeviceCategories';      Path='deviceManagement/deviceCategories';              Name='displayName'; Phase='Foundation'; Strip=@('id','exportWarnings') }
    @{ Folder='22_RoleDefinitions';       Path='deviceManagement/roleDefinitions';               Name='displayName'; Phase='Foundation'; Strip=@('id','createdDateTime','lastModifiedDateTime','exportWarnings'); Special='RoleDefinition' }
    @{ Folder='23_ConditionalAccess';    Path='identity/conditionalAccess/policies';               Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','modifiedDateTime','templateId','exportWarnings'); Special='ConditionalAccess' }
    @{ Folder='14_AdminTemplates';        Path='deviceManagement/groupPolicyConfigurations';          Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','definitionValues','policyConfigurationIngestionType','exportWarnings'); Special='AdminTemplate' }
    @{ Folder='16_Enrollment';            Path='deviceManagement/deviceEnrollmentConfigurations';     Name='displayName'; Phase='Foundation'; Key='@odata.type'; Strip=@('id','priority','createdDateTime','lastModifiedDateTime','version','deviceEnrollmentConfigurationType','assignments','exportWarnings'); Special='Enrollment' }
)

# GARDE-FOU fail-closed (design : Endpoint Security). 15_EndpointSecurity ne doit JAMAIS etre cable dans
# $Catalog : deviceManagement/intents (et l'API templates legacy) ont ete GELES par Microsoft (~03/2025).
# L'Endpoint Security moderne est une configurationPolicy deja geree par la famille 02 ; les intents legacy
# residuels se recreent a la main / via AI-assist, jamais par un importeur d'intents. Si quelqu'un en recable
# un ici, refuser de tourner.
if (@($Catalog | Where-Object { $_.Folder -eq '15_EndpointSecurity' }).Count -gt 0) {
    throw "GARDE-FOU : 15_EndpointSecurity ne doit pas etre dans `$Catalog (deviceManagement/intents gele ; ES moderne = famille 02, intents legacy = manuel/AI-assist)."
}

# Surcharges de raison OutOfScope : pour les dossiers presents dans l'export mais volontairement absents du
# $Catalog, donner une raison SPECIFIQUE et honnete au lieu du generique 'aucun endpoint'. 15_EndpointSecurity
# est le cas notable.
$script:OutOfScopeReasons = @{
    '15_EndpointSecurity' = 'Endpoint Security intents legacy : API deviceManagement/intents gelee par Microsoft (~03/2025). L''ES moderne se recree via la famille 02 (configurationPolicies) ; les intents legacy = runbook manuel / AI-assist. Non recreable par API.'
}

function Add-Result {
    # Enregistrement enrichi P1-1. Les colonnes historiques (Timestamp/Family/Name/Status/Reason/GraphId/Error)
    # sont conservees TELLES QUELLES pour la compat CSV ; les nouvelles colonnes decrivent des RESULTATS (neutres
    # vis-a-vis du backend) :
    #   SourceName  = nom source NON prefixe,   AppliedName = nom reellement pousse (prefixe),
    #   IdentityKey = cle logique sur le nom source non prefixe,   TargetId = l'id cible (== GraphId),
    #   Remap       = tableau de {kind,oldId,newId} (defaut @()).
    param($Family,$Name,$Status,$Reason,$GraphId,$Err,$SourceName,$AppliedName,$IdentityKey,$Remap=@())
    if (-not $SourceName)  { $SourceName  = $Name }
    if (-not $AppliedName) { $AppliedName = $Name }
    # Normalise Remap en object[] SANS l'operateur @() : @() sur une List[object] leve
    # "Argument types do not match" sur PowerShell 7.5 / .NET 9 (RemapLog est une List).
    $remapAcc = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Remap) { foreach ($__r in $Remap) { [void]$remapAcc.Add($__r) } }
    $script:Results.Add([pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Family=$Family; Name=$Name; Status=$Status
        Reason=$Reason; GraphId=$GraphId; Error=$Err
        SourceName=$SourceName; AppliedName=$AppliedName; IdentityKey=$IdentityKey
        TargetId=$GraphId; Remap=$remapAcc.ToArray()
    })
}

function Assert-Target {
    if ($TargetTenantId -eq $SourceTenantId) { throw "GARDE-FOU : cible == source ($TargetTenantId). Refuse." }
    $ctx = Get-MgContext
    if (-not $ctx) { throw "Aucune connexion Graph. Faire Connect-MgGraph -TenantId $TargetTenantId ... avant." }
    if ($ctx.TenantId -ne $TargetTenantId) { throw "GARDE-FOU : contexte courant $($ctx.TenantId) != cible $TargetTenantId." }
    Write-Host ("  [OK] Contexte cible confirme : {0} ({1})" -f $ctx.TenantId,$ctx.Account) -ForegroundColor Green
}

function Read-JsonFile { param($Path) (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -AsHashtable -Depth 100 }

function Get-IdempotencyKey {
    # Cle d'idempotence : nom (+ discriminateur de type/plateforme si $Cat.Key est defini). Evite les faux
    # EXISTS / doublons sur objets homonymes de types differents (ex. iosVppApp vs androidManagedStoreApp,
    # filtre iOS vs iOSMobileApplicationManagement). L'acces ".$prop" fonctionne pour SOURCE (hashtable)
    # comme CIBLE (objet Graph). $NameOverride permet a l'appelant de passer le nom deja prefixe.
    param($Obj,$Cat,[string]$NameOverride)
    if ($NameOverride) { $name = $NameOverride }
    else {
        $name = [string]($Obj.$($Cat.Name))
        if (-not $name) { $name = [string]($Obj.displayName) }
        if (-not $name) { $name = [string]($Obj.name) }
    }
    $key = $name.ToLowerInvariant()
    if ($Cat.Key) { $key = $key + '|' + ([string]($Obj.$($Cat.Key))).ToLowerInvariant() }
    return $key
}

function Get-AllValues {
    param($Path)
    $all=@(); $u="$GraphBase/$Path"
    do {
        $r = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri $u }
        if ($r.value) { $all += @($r.value) }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # Streamer les elements (defense en profondeur). L'appelant enchaine "| ForEach-Object",
    # donc ",$all" fonctionnait, mais "return $all" evite tout risque de collapse si l'appel change.
    return $all
}

function Build-TargetAppIdMap {
    # P1-4 : en run -Phase All unique, l'AppIdMap n'est pas fournie au moment d'importer les
    # AppConfigurations. On la construit ICI, APRES la vague Apps et AVANT les AppConfigurations, en
    # interrogeant le tenant CIBLE (apps deja creees) et en matchant par displayName + @odata.type (repli
    # nom seul) -- meme logique que Build-IntuneAppIdMap.ps1. Alimente $script:AppIdMap (SourceId -> TargetId).
    # N'ecrase jamais une entree deja chargee via -AppIdMapPath.
    $appsFolder = Join-Path $SourcePath '09_Apps'
    if (-not (Test-Path -LiteralPath $appsFolder)) { return }
    $srcFiles = @(Get-ChildItem -LiteralPath $appsFolder -Filter *.json -File -ErrorAction SilentlyContinue)
    if ($srcFiles.Count -eq 0) { return }
    try { $targetApps = @(Get-AllValues -Path 'deviceAppManagement/mobileApps') }
    catch { Write-Host ("  [!] AppIdMap auto : lecture des apps cible impossible : {0}" -f $_.Exception.Message) -ForegroundColor Yellow; return }
    $added = 0
    foreach ($sf in $srcFiles) {
        try { $src = Read-JsonFile $sf.FullName } catch { continue }
        $sid = [string]$src.'id'; $sname = [string]$src.'displayName'; $stype = [string]$src.'@odata.type'
        if (-not $sid -or -not $sname) { continue }
        if ($script:AppIdMap.ContainsKey($sid)) { continue }   # ne jamais ecraser une entree -AppIdMapPath
        $match = $null
        $byNameType = @($targetApps | Where-Object { [string]$_.'displayName' -eq $sname -and [string]$_.'@odata.type' -eq $stype })
        if ($byNameType.Count -eq 1) { $match = $byNameType[0] }
        elseif ($byNameType.Count -eq 0) {
            $byName = @($targetApps | Where-Object { [string]$_.'displayName' -eq $sname })
            if ($byName.Count -eq 1) { $match = $byName[0] }
        }
        if ($match) { $script:AppIdMap[$sid] = [string]$match.'id'; $added++ }
    }
    Write-Host ("  [i] AppIdMap auto-construite depuis le tenant cible : {0} correspondance(s)." -f $added) -ForegroundColor DarkCyan
}

function Remove-TopKeys { param([hashtable]$H,[string[]]$Keys) foreach($k in $Keys){ if($H.ContainsKey($k)){ [void]$H.Remove($k) } } }

function Set-RoleScopeTagIds {
    param([hashtable]$H)
    if (-not $IncludeScopeTags) { if($H.ContainsKey('roleScopeTagIds')){ [void]$H.Remove('roleScopeTagIds') }; return }
    if ($H.ContainsKey('roleScopeTagIds')) { $H['roleScopeTagIds'] = [string[]]@($H['roleScopeTagIds']) }
}

# ---- Constructeurs de payload (AUCUNE reconstruction recursive : on ne descend PAS dans settingInstance) ----
function New-GenericPayload {
    param([hashtable]$O,$Cat)
    Remove-TopKeys -H $O -Keys $Cat.Strip
    Set-RoleScopeTagIds -H $O
    ,$O
}

function New-SettingsCatalogPayload {
    param([hashtable]$O,$Cat)
    Remove-TopKeys -H $O -Keys $Cat.Strip
    Set-RoleScopeTagIds -H $O
    # templateReference : @odata.type avec '#', conserver verbatim
    if ($O['templateReference'] -is [hashtable]) {
        $O['templateReference']['@odata.type'] = '#microsoft.graph.deviceManagementConfigurationPolicyTemplateReference'
    }
    # Encapsuler chaque settings[i] : retirer 'id' du wrapper, injecter @odata.type, settingInstance VERBATIM
    $wrapped = foreach ($s in @($O['settings'])) {
        [ordered]@{
            '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
            'settingInstance' = $s['settingInstance']
        }
    }
    $O['settings'] = @($wrapped)   # tableau meme a 0/1 element (PS7 preserve)
    ,$O
}

function New-CompliancePayload {
    param([hashtable]$O,$Cat)
    Remove-TopKeys -H $O -Keys $Cat.Strip
    # 1er passage : retrait de roleScopeTagIds (scope tags PROD 1/3 absents d'TEST)
    if ($O.ContainsKey('roleScopeTagIds')) { [void]$O.Remove('roleScopeTagIds') }
    foreach ($k in 'validOperatingSystemBuildRanges','wslDistributions') {
        if ($O.ContainsKey($k) -and @($O[$k]).Count -eq 0) { [void]$O.Remove($k) }
    }
    if (-not $O.ContainsKey('scheduledActionsForRule') -or @($O['scheduledActionsForRule']).Count -eq 0) {
        $O['scheduledActionsForRule'] = @(
            [ordered]@{
                ruleName = 'PasswordRequired'
                scheduledActionConfigurations = @(
                    [ordered]@{
                        '@odata.type'            = '#microsoft.graph.deviceComplianceActionItem'
                        actionType               = 'block'
                        gracePeriodHours         = 0     # <-- DECISION METIER : ajuster (ex. 24-72) avant PROD
                        notificationTemplateId   = '00000000-0000-0000-0000-000000000000'
                        notificationMessageCCList = @()
                    }
                )
            }
        )
    }
    ,$O
}

function Test-HasEncryptedSecret {
    param([hashtable]$O)
    if (-not $O.ContainsKey('omaSettings')) { return $false }
    foreach ($s in @($O['omaSettings'])) { if ($s['secretReferenceValueId']) { return $true } }
    $false
}

function New-DeviceConfigPayload {
    param([hashtable]$O,$Cat)
    if (Test-HasEncryptedSecret -O $O) { throw 'SKIP_SECRET : profil a secretReferenceValueId -> traitement manuel (re-saisie du clair).' }
    New-GenericPayload -O $O -Cat $Cat
}

function New-ContentScriptPayload {
    param([hashtable]$O,$Cat,[string[]]$Fields)
    foreach ($f in $Fields) {
        $v = $O[$f]
        if ([string]::IsNullOrEmpty($v)) { throw "SKIP_EMPTY : $f vide -> rehydrater le contenu depuis PROD avant import." }
    }
    New-GenericPayload -O $O -Cat $Cat
}

# ---- 16_Enrollment : skip-and-flag AVANT tout POST (fail-closed) ----------------------------------
function New-EnrollmentPayload {
    # deviceEnrollmentConfigurations : endpoint unique, sous-type porte par @odata.type dans le corps. L'export
    # liste defauts + profils cibles sans filtre ; on classe ici. Seuls les profils CIBLES sont POSTes
    # (ESP/limit/singlePlatformRestriction/notifications). Les defauts et singletons du tenant sont SKIP (un POST
    # collisionnerait ou casserait la priorite). priority est en lecture seule au create -> strippee & journalisee,
    # jamais reordonnee (setPriority remanierait aussi les profils deja presents dans la cible). assignments ->
    # deferees a Invoke-IntuneAssignments (jamais de GUID de groupe source poste). @odata.type CONSERVE pour le routage.
    param([hashtable]$O,$Cat)
    $t   = [string]$O['@odata.type']
    $ect = [string]$O['deviceEnrollmentConfigurationType']
    $prio = $O['priority']
    # priority est deserialisee en Int64 par ConvertFrom-Json -AsHashtable : un '-is [int]' litteral RATE 0 et
    # ferait fail-OUVERT sur un defaut tenant. Garder le null d'abord (priority absente != 0), puis comparer en Int64.
    $prioIsZero = $false
    if ($null -ne $prio) { try { $prioIsZero = ([int64]$prio -eq 0) } catch { $prioIsZero = $false } }
    $singletons = @(
      '#microsoft.graph.deviceEnrollmentWindowsHelloForBusinessConfiguration',
      '#microsoft.graph.deviceComanagementAuthorityConfiguration',
      '#microsoft.graph.windowsRestoreDeviceEnrollmentConfiguration')
    # 1) Defauts tenant / singletons : NE JAMAIS dupliquer.
    if ($ect -like 'default*' -or $prioIsZero -or ($singletons -contains $t)) {
        throw "SKIP_DEFAULT_SINGLETON : enrollment default/singleton ($ect/$t) -- collision cible ou casse la priorite."
    }
    # 2) Restriction multi-plateforme combinee legacy : revue manuelle (recreer/convertir en singlePlatformRestriction).
    if ($t -eq '#microsoft.graph.deviceEnrollmentPlatformRestrictionsConfiguration') {
        throw "SKIP_FLAG_REVIEW : platformRestrictions combinee legacy -- recreer/convertir en singlePlatformRestriction."
    }
    return (New-GenericPayload -O $O -Cat $Cat)   # strippe priority/id/... -> jamais de GUID source ; @odata.type conserve
}

# ---- 14_AdminTemplates (ADMX) : creer la coquille, puis remap-ou-skip de chaque definitionValue --------
function Get-AdmxDefinitionCache {
    # Charge les groupPolicyDefinitions CIBLE UNE fois et indexe par 'displayName|classType|categoryPath' (minuscule).
    # Les ids de definition DIFFERENT entre tenants meme pour un ADMX identique -> resolution par attributs, jamais par GUID source.
    if ($null -ne $script:AdmxDefCache) { return $script:AdmxDefCache }
    $cache = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($d in @(Get-AllValues -Path 'deviceManagement/groupPolicyDefinitions')) {
        $k = ('{0}|{1}|{2}' -f [string]$d.displayName,[string]$d.classType,[string]$d.categoryPath).ToLowerInvariant()
        if ($k -and -not $cache.ContainsKey($k)) { $cache[$k] = [string]$d.id }
    }
    $script:AdmxDefCache = $cache
    return $cache
}

function Get-AdmxPresentations {
    # Presentations CIBLE d'une definition (en cache). Sert au remap de presentation@odata.bind par label + @odata.type.
    param([string]$DefId)
    if ($script:AdmxPresCache.ContainsKey($DefId)) { return $script:AdmxPresCache[$DefId] }
    $pres = @(Get-AllValues -Path ("deviceManagement/groupPolicyDefinitions('{0}')/presentations" -f $DefId))
    $script:AdmxPresCache[$DefId] = $pres
    return $pres
}

function Resolve-AdmxDefinitionValue {
    # Construit le corps POST remappe pour UN definitionValue source, ou LEVE SKIP_UNRESOLVED_DEF (fail-closed).
    # Ne jamais emettre un id de definition/presentation du tenant source : la definition est resolue par attributs
    # et chaque presentation@odata.bind est imbriquee sous la definition CIBLE resolue. Une seule presentation non
    # resolue SKIP tout le definitionValue (une valeur partielle 400/corrompt la stratégie).
    param([hashtable]$Dv)
    $def = $Dv['definition']
    if (-not ($def -is [hashtable])) { throw "SKIP_UNRESOLVED_DEF : definitionValue sans definition imbriquee (rehydrater l'export)." }
    $dName = [string]$def['displayName']; $dClass = [string]$def['classType']; $dCat = [string]$def['categoryPath']
    $dkey = ('{0}|{1}|{2}' -f $dName,$dClass,$dCat).ToLowerInvariant()
    $cache = Get-AdmxDefinitionCache
    $tgtDefId = $null
    if ($cache.ContainsKey($dkey)) { $tgtDefId = $cache[$dkey] }
    if ([string]::IsNullOrWhiteSpace($tgtDefId)) {
        throw "SKIP_UNRESOLVED_DEF : definition ADMX '$dName' (classType=$dClass, category=$dCat) introuvable dans le catalogue cible (ADMX custom/non ingere)."
    }
    $body = [ordered]@{
        'enabled'               = [bool]$Dv['enabled']
        'definition@odata.bind' = "$GraphBase/deviceManagement/groupPolicyDefinitions('$tgtDefId')"
    }
    $srcPvs = @($Dv['presentationValues'])
    if ($srcPvs.Count -gt 0) {
        $tgtPres = @(Get-AdmxPresentations -DefId $tgtDefId)
        $typeCounter = @{}   # compteur de consommation par @odata.type pour le repli par ordre
        $pvOut = @()
        foreach ($pv in $srcPvs) {
            $srcPres  = $pv['presentation']
            $srcLabel = if ($srcPres -is [hashtable]) { [string]$srcPres['label'] } else { '' }
            $srcType  = if ($srcPres -is [hashtable]) { [string]$srcPres['@odata.type'] } else { '' }
            $idx = 0; if ($typeCounter.ContainsKey($srcType)) { $idx = [int]$typeCounter[$srcType] }
            $typeCounter[$srcType] = $idx + 1
            $tgtPresId = $null
            # primaire : match sur label + @odata.type
            $cand = @($tgtPres | Where-Object { [string]$_.label -eq $srcLabel -and [string]$_.'@odata.type' -eq $srcType })
            if ($cand.Count -ge 1) { $tgtPresId = [string]$cand[0].id }
            else {
                # repli : meme ORDRE parmi les presentations cible de meme @odata.type
                $sameType = @($tgtPres | Where-Object { [string]$_.'@odata.type' -eq $srcType })
                if ($sameType.Count -eq 1) { $tgtPresId = [string]$sameType[0].id }   # sans ambiguite seulement ; refuse de deviner par ordre (risque de mauvaise presentation -> SKIP)
            }
            if ([string]::IsNullOrWhiteSpace($tgtPresId)) {
                throw "SKIP_UNRESOLVED_DEF : presentation '$srcLabel' ($srcType) non resolue pour la definition '$dName' -- definitionValue entier skippe."
            }
            # conserver le presentationValue verbatim (@odata.type Decimal/Text/List/... + value/values), retirer
            # seulement presentation/id/timestamps source, puis imbriquer presentation@odata.bind sous la definition CIBLE.
            $pvClone = [ordered]@{}
            foreach ($k in $pv.Keys) {
                if ($k -in @('presentation','id','lastModifiedDateTime','createdDateTime')) { continue }
                $pvClone[$k] = $pv[$k]
            }
            $pvClone['presentation@odata.bind'] = "$GraphBase/deviceManagement/groupPolicyDefinitions('$tgtDefId')/presentations('$tgtPresId')"
            $pvOut += $pvClone
        }
        $body['presentationValues'] = @($pvOut)
    }
    return $body
}

function New-AdminTemplatePayload {
    # Construit UNIQUEMENT la COQUILLE de config (POST /groupPolicyConfigurations = {displayName, description, roleScopeTagIds}).
    # Les definitionValues sont Strip du corps de create et POSTes APRES la creation (voir le bloc post-create).
    # Ils sont captures ICI d'abord, car Remove-TopKeys (New-GenericPayload) mute $O en place -> lire
    # $O['definitionValues'] apres Build-Payload ne renverrait rien.
    param([hashtable]$O,$Cat)
    $script:AdminDefValues = @($O['definitionValues'])
    return (New-GenericPayload -O $O -Cat $Cat)
}

# ---- Conditional Access remap-ou-refus (P0-5) -----------------------------------------------------
function Resolve-CaRefList {
    # Remappe une liste de references CA : laisse passer les CONSTANTES inchangees, remappe les GUID
    # tenant-scoped via la table CA, LEVE (fail-closed) sur toute reference tenant-scoped non resolue.
    # Chaque valeur emise (cible remappee OU constante laissee passer) est enregistree dans $script:CaEmitted
    # pour que le garde-fou fail-closed ci-dessous distingue une constante legitime d'un id source qui a fuite.
    # -AllConstant marque une classe entiere comme constante inter-tenant (ex. include/excludeRoles =
    # ids de role TEMPLATE d'annuaire).
    param($List,[string[]]$Constants,[string]$Slot,[switch]$AllConstant)
    $out = @()
    foreach ($ref in @($List)) {
        $s = [string]$ref
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($AllConstant -or ($Constants -contains $s)) { $out += $s; [void]$script:CaEmitted.Add($s); continue }
        $t = $script:CaIdMap[$s]
        if ([string]::IsNullOrWhiteSpace($t)) {
            throw "SKIP_UNRESOLVED_CA_REF : reference $Slot '$s' sans equivalent cible (CaIdMap) -> policy CA refusee (fail-closed)."
        }
        $out += $t; [void]$script:CaEmitted.Add([string]$t)
        if ($null -ne $script:RemapLog) { [void]$script:RemapLog.Add([pscustomobject]@{ kind=$Slot; oldId=$s; newId=[string]$t }) }  # P1-1 trace de remap
    }
    return ,@($out)
}

function Resolve-CaReferences {
    # Remappe EN PLACE toute classe de reference tenant-scoped d'une policy CA ; leve pour refuser toute
    # la policy si une reference ne peut etre resolue. Les role TEMPLATES, apps Microsoft bien connues et
    # auth strengths integres passent inchanges. Un GARDE-FOU fail-closed scanne ensuite les sous-arbres
    # conditions/grantControls et refuse la policy si UN GUID non emis volontairement subsiste (ref source
    # dans un slot non gere : external tenants, custom auth strength, device states...).
    param([hashtable]$O)
    $script:CaEmitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $cond = $O['conditions']
    if ($cond -is [hashtable]) {
        $users = $cond['users']
        if ($users -is [hashtable]) {
            foreach ($slot in 'includeUsers','excludeUsers') {
                if ($users.ContainsKey($slot)) { $users[$slot] = Resolve-CaRefList -List $users[$slot] -Constants $script:CaSpecialUsers -Slot "users.$slot" }
            }
            foreach ($slot in 'includeGroups','excludeGroups') {
                if ($users.ContainsKey($slot)) { $users[$slot] = Resolve-CaRefList -List $users[$slot] -Constants @() -Slot "users.$slot" }
            }
            foreach ($slot in 'includeRoles','excludeRoles') {
                # Les ids de role TEMPLATE d'annuaire sont des constantes inter-tenant : passent inchanges (jamais via une table Intune).
                if ($users.ContainsKey($slot)) { $users[$slot] = Resolve-CaRefList -List $users[$slot] -AllConstant -Slot "users.$slot" }
            }
        }
        $apps = $cond['applications']
        if ($apps -is [hashtable]) {
            foreach ($slot in 'includeApplications','excludeApplications') {
                if ($apps.ContainsKey($slot)) { $apps[$slot] = Resolve-CaRefList -List $apps[$slot] -Constants $script:CaConstantApps -Slot "applications.$slot" }
            }
        }
        $capps = $cond['clientApplications']
        if ($capps -is [hashtable]) {
            foreach ($slot in 'includeServicePrincipals','excludeServicePrincipals') {
                # les service principals sont tenant-scoped : remap via CaIdMap ou refus (fail-closed).
                if ($capps.ContainsKey($slot)) { $capps[$slot] = Resolve-CaRefList -List $capps[$slot] -Constants @('ServicePrincipalsInMyTenant','None') -Slot "clientApplications.$slot" }
            }
        }
        $locs = $cond['locations']
        if ($locs -is [hashtable]) {
            foreach ($slot in 'includeLocations','excludeLocations') {
                # named-locations : pas de table dediee => les refs retombent sur CaIdMap ; absentes => refusees (fail-closed).
                if ($locs.ContainsKey($slot)) { $locs[$slot] = Resolve-CaRefList -List $locs[$slot] -Constants $script:CaSpecialLocations -Slot "locations.$slot" }
            }
        }
    }
    $grant = $O['grantControls']
    if ($grant -is [hashtable]) {
        if ($grant.ContainsKey('termsOfUse')) {
            $grant['termsOfUse'] = Resolve-CaRefList -List $grant['termsOfUse'] -Constants @() -Slot 'grantControls.termsOfUse'
        }
        $as = $grant['authenticationStrength']
        if ($as -is [hashtable] -and $as.ContainsKey('id')) {
            # les auth strengths integres sont des constantes globales ; un id custom (tenant-scoped) sans map cible -> refuse.
            $as['id'] = @(Resolve-CaRefList -List @($as['id']) -Constants $script:CaBuiltInAuthStrength -Slot 'grantControls.authenticationStrength.id')[0]
        }
    }
    # Garde-fou fail-closed : aucun GUID source ne doit subsister dans les sous-arbres conditions/grantControls.
    # Tout ce qu'on a remappe ou laisse passer volontairement est dans $script:CaEmitted ; un GUID reste dans un
    # slot non gere/non mappe est refuse plutot qu'emis. (Les id/templateId/dates de premier niveau ne sont pas scannes.)
    foreach ($sub in @($O['conditions'], $O['grantControls'])) {
        if ($null -eq $sub) { continue }
        $blob = ($sub | ConvertTo-Json -Depth 100 -Compress)
        foreach ($mm in ([regex]'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches($blob)) {
            $g = $mm.Value
            if ($script:CaEmitted.Contains($g)) { continue }
            if ($script:CaWellKnownAppIds -contains $g) { continue }
            throw "SKIP_UNRESOLVED_CA_REF : GUID '$g' dans un slot CA non gere/non mappe -> policy CA refusee (fail-closed ; ne jamais emettre un id source)."
        }
    }
}

function Build-Payload {
    param([hashtable]$O,$Cat)
    switch ($Cat.Special) {
        'SettingsCatalog' { return (New-SettingsCatalogPayload -O $O -Cat $Cat) }
        'Compliance'      { return (New-CompliancePayload      -O $O -Cat $Cat) }
        'DeviceConfig'    { return (New-DeviceConfigPayload    -O $O -Cat $Cat) }
        'Script'          { return (New-ContentScriptPayload   -O $O -Cat $Cat -Fields @('scriptContent')) }
        'Remediation'     { return (New-ContentScriptPayload   -O $O -Cat $Cat -Fields @('detectionScriptContent','remediationScriptContent')) }
        'App' {
            $t = $O['@odata.type']
            if ($AppTypesManual -contains $t) { throw "SKIP_MANUAL : type d'app non clonable ($t)." }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'AppConfig' {
            # Remap targetedMobileApps (IDs d'apps SOURCE -> cible) via AppIdMap ; SKIP_UNMAPPED si non mappe.
            # Table fournie via -AppIdMapPath OU auto-construite depuis le tenant cible (P1-4, run -Phase All unique).
            if ($O.ContainsKey('targetedMobileApps') -and @($O['targetedMobileApps']).Count -gt 0) {   # P1-4 : inconditionnel -> une app non mappee = SKIP_UNMAPPED, jamais un GUID source POSTe
                $mapped = @()
                foreach ($sid in @($O['targetedMobileApps'])) {
                    $tid = $script:AppIdMap[[string]$sid]
                    if ([string]::IsNullOrWhiteSpace($tid)) { throw "SKIP_UNMAPPED : app source $sid sans equivalent cible dans AppIdMap.csv -> config non importee." }
                    $mapped += $tid
                    if ($null -ne $script:RemapLog) { [void]$script:RemapLog.Add([pscustomobject]@{ kind='targetedMobileApps'; oldId=[string]$sid; newId=$tid }) }  # P1-1 trace de remap
                }
                $O['targetedMobileApps'] = @($mapped)
            }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'RoleDefinition' {
            if ($O['isBuiltIn'] -or $O['isBuiltInRoleDefinition']) { throw 'SKIP_BUILTIN : definition de role integree (non creable).' }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'ConditionalAccess' {
            # P0-5 : remap-ou-refus. Creee DESACTIVEE, et ne JAMAIS emettre un GUID du tenant source dans un quelconque slot.
            $O['state'] = 'disabled'
            Resolve-CaReferences -O $O
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'Enrollment'    { return (New-EnrollmentPayload    -O $O -Cat $Cat) }
        'AdminTemplate' { return (New-AdminTemplatePayload -O $O -Cat $Cat) }
        default { return (New-GenericPayload -O $O -Cat $Cat) }
    }
}

# ---- Rapport de reconciliation P1-1 (le differenciateur durable ; decrit des RESULTATS, pas du transport) ----
function ConvertTo-HtmlText { param([string]$s) if ($null -eq $s) { return '' } ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }

function Get-CanonicalOutcome {
    # Mappe un Status brut du moteur vers un OUTCOME canonique, neutre vis-a-vis du backend.
    param([string]$Status)
    switch -Regex ($Status) {
        '^EXISTS$'              { 'Matched' ; break }
        '^CREATED(-DISABLED)?$' { 'Created' ; break }
        '^ERROR$'               { 'Failed'  ; break }
        '^PREVIEW$'             { 'Preview' ; break }
        '^(SKIP.*|BLOCKED)$'    { 'Skipped' ; break }
        default                 { 'Skipped' }
    }
}

function Write-Reconciliation {
    # Emet reconcile.json / reconcile.html / reconcile.csv a cote du journal CSV ($LogPath). Centre resultats,
    # neutre backend. Verifie l'invariant de completude et leve la banniere SECURITY-CRITICAL + exit 2.
    $reconDir = Split-Path -Parent $LogPath
    if (-not $reconDir) { $reconDir = (Get-Location).Path }
    if (-not (Test-Path $reconDir)) { New-Item -ItemType Directory -Force -Path $reconDir | Out-Null }
    $jsonPath = Join-Path $reconDir 'reconcile.json'
    $htmlPath = Join-Path $reconDir 'reconcile.html'
    $csvPath  = Join-Path $reconDir 'reconcile.csv'

    # 1) Enregistrements canoniques depuis les resultats du moteur (exclut les sous-enregistrements '/msg' + '/defval' :
    #    ce sont des details par-message / par-valeur-ADMX d'un objet parent, pas des objets source de premier niveau pour l'invariant).
    $canon = @(foreach ($r in @($script:Results | Where-Object { $_.Family -notlike '*/msg' -and $_.Family -notlike '*/defval' })) {
        [pscustomobject]@{
            family=$r.Family; sourceName=$r.SourceName; appliedName=$r.AppliedName
            identityKey=$r.IdentityKey; outcome=(Get-CanonicalOutcome $r.Status); reason=$r.Reason
            targetId=$r.TargetId; remap=@($r.Remap); timestamp=$r.Timestamp; status=$r.Status
        }
    })

    # 2) OutOfScope : dossiers PRESENTS dans l'export mais ABSENTS du $Catalog (aucun mapping d'endpoint).
    $catalogFolders = @($Catalog | ForEach-Object { $_.Folder })
    $outRecords = @()
    if (Test-Path -LiteralPath $SourcePath) {
        foreach ($d in @(Get-ChildItem -LiteralPath $SourcePath -Directory -ErrorAction SilentlyContinue)) {
            if ($catalogFolders -contains $d.Name) { continue }
            foreach ($jf in @(Get-ChildItem -LiteralPath $d.FullName -Filter *.json -File -ErrorAction SilentlyContinue)) {
                $sn = $jf.BaseName
                try { $o = Read-JsonFile $jf.FullName; if ($o['displayName']) { $sn=[string]$o['displayName'] } elseif ($o['name']) { $sn=[string]$o['name'] } } catch {}
                $oosReason = $script:OutOfScopeReasons[$d.Name]
                if ([string]::IsNullOrWhiteSpace($oosReason)) { $oosReason = 'Dossier present dans l''export mais absent du Catalogue d''import (aucun endpoint)' }
                $outRecords += [pscustomobject]@{
                    family=$d.Name; sourceName=$sn; appliedName=$sn; identityKey=''
                    outcome='OutOfScope'; reason=$oosReason
                    targetId=''; remap=@(); timestamp=(Get-Date).ToString('o'); status='OUTOFSCOPE'
                }
            }
        }
    }
    $allCanon = @($canon) + @($outRecords)

    # 3) Invariant de completude : chaque objet SOURCE vu == exactement un outcome (OutOfScope inclus).
    $seen = $script:SourceFileCount + @($outRecords).Count
    $invariantOK = (@($allCanon).Count -eq $seen)

    # 4) Comptes du resume par outcome canonique.
    $summary = [ordered]@{}
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) { $summary[$o] = 0 }
    foreach ($grp in ($allCanon | Group-Object outcome)) { $summary[$grp.Name] = $grp.Count }

    # 5) SECURITY-CRITICAL : Special = Compliance|ConditionalAccess, ou une security baseline (nom *aseline*).
    $specialByFolder = @{}
    foreach ($c in $Catalog) { if ($c.Special) { $specialByFolder[$c.Folder] = $c.Special } }
    $criticalNotApplied = @(foreach ($r in $allCanon) {
        $sp = $specialByFolder[$r.family]
        $isCrit = ($sp -eq 'Compliance' -or $sp -eq 'ConditionalAccess' `
            -or $r.family -match '(?i)EndpointSecurity|Baseline' `
            -or $r.status -eq 'SKIP_FLAG_REVIEW' `
            -or $r.sourceName -like '*aseline*' -or $r.appliedName -like '*aseline*')
        if (-not $isCrit) { continue }
        # OutOfScope compte aussi : un objet securite-critique silencieusement drope (hors $Catalog) ne doit PAS passer pour "tout va bien".
        if (($r.outcome -in @('Failed','Skipped','OutOfScope')) -or ($r.status -eq 'CREATED-DISABLED')) { $r }
    })

    # ---- reconcile.json ----
    $doc = [ordered]@{
        schemaVersion='1.0'; backend='graph-beta'; generatedAt=(Get-Date).ToString('o')
        phase=$Phase; target=$TargetTenantId; summary=$summary
        records=@($allCanon | ForEach-Object {
            [ordered]@{
                family=$_.family; sourceName=$_.sourceName; appliedName=$_.appliedName
                identityKey=$_.identityKey; outcome=$_.outcome; reason=$_.reason
                targetId=$_.targetId; remap=@($_.remap); timestamp=$_.timestamp
            }
        })
    }
    $doc | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    # ---- reconcile.csv (colonnes canoniques) ----
    $allCanon | Select-Object family,sourceName,appliedName,identityKey,outcome,reason,targetId |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    # ---- reconcile.html ----
    $colorOf = @{ Matched='#2e7d32'; Created='#1565c0'; Failed='#c62828'; Skipped='#ef6c00'; Preview='#616161'; OutOfScope='#6a1b9a' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Reconciliation Intune</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{margin:0 0 4px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:8px 0 24px}th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;text-align:left;vertical-align:top}')
    [void]$sb.AppendLine('th{background:#f5f5f5}.pill{color:#fff;border-radius:10px;padding:2px 8px;font-size:12px;white-space:nowrap}')
    [void]$sb.AppendLine('.crit{background:#c62828;color:#fff;padding:12px 16px;border-radius:6px;margin:12px 0}.ok{background:#2e7d32;color:#fff;padding:12px 16px;border-radius:6px;margin:12px 0}')
    [void]$sb.AppendLine('.meta{color:#555;font-size:13px}code{background:#f0f0f0;padding:1px 4px;border-radius:3px}</style></head><body>')
    [void]$sb.AppendLine(("<h1>Rapport de reconciliation Intune</h1><div class='meta'>backend=graph-beta &middot; phase={0} &middot; target={1} &middot; genere {2}</div>" -f (ConvertTo-HtmlText $Phase),(ConvertTo-HtmlText $TargetTenantId),(ConvertTo-HtmlText ((Get-Date).ToString('o')))))
    # Section d'en-tete : SECURITY-CRITICAL NOT APPLIED
    if ($criticalNotApplied.Count -gt 0) {
        [void]$sb.AppendLine(("<div class='crit'><b>&#9888; SECURITY-CRITICAL NOT APPLIED ({0})</b><br>Objets de securite critiques (Compliance / Conditional Access / baselines) qui n'ont PAS ete appliques.</div>" -f $criticalNotApplied.Count))
        [void]$sb.AppendLine('<table><tr><th>Famille</th><th>Source</th><th>Applique</th><th>Outcome</th><th>Raison</th></tr>')
        foreach ($r in $criticalNotApplied) {
            [void]$sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class='pill' style='background:{3}'>{4}</span></td><td>{5}</td></tr>" -f (ConvertTo-HtmlText $r.family),(ConvertTo-HtmlText $r.sourceName),(ConvertTo-HtmlText $r.appliedName),($colorOf[$r.outcome]),(ConvertTo-HtmlText $r.outcome),(ConvertTo-HtmlText $r.reason)))
        }
        [void]$sb.AppendLine('</table>')
    } else {
        [void]$sb.AppendLine("<div class='ok'>&#10003; SECURITY-CRITICAL NOT APPLIED : aucun. Aucun objet de securite critique laisse non applique.</div>")
    }
    # Resume + invariant
    [void]$sb.Append("<div class='meta'>Resume : ")
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) {
        [void]$sb.Append(("<span class='pill' style='background:{0}'>{1}: {2}</span> " -f ($colorOf[$o]),$o,$summary[$o]))
    }
    [void]$sb.AppendLine(("</div><div class='meta'>Invariant de completude : {0} outcome(s) == {1} objet(s) source vu(s) -&gt; {2}</div>" -f @($allCanon).Count,$seen,($(if($invariantOK){'OK'}else{'FAIL'}))))
    # Tables par famille
    foreach ($grp in ($allCanon | Group-Object family | Sort-Object Name)) {
        [void]$sb.AppendLine(("<h3>{0} ({1})</h3>" -f (ConvertTo-HtmlText $grp.Name),$grp.Count))
        [void]$sb.AppendLine('<table><tr><th>Outcome</th><th>Nom source</th><th>Nom applique</th><th>IdentityKey</th><th>Id cible</th><th>Raison</th></tr>')
        foreach ($r in $grp.Group) {
            [void]$sb.AppendLine(("<tr><td><span class='pill' style='background:{0}'>{1}</span></td><td>{2}</td><td>{3}</td><td><code>{4}</code></td><td><code>{5}</code></td><td>{6}</td></tr>" -f ($colorOf[$r.outcome]),(ConvertTo-HtmlText $r.outcome),(ConvertTo-HtmlText $r.sourceName),(ConvertTo-HtmlText $r.appliedName),(ConvertTo-HtmlText $r.identityKey),(ConvertTo-HtmlText $r.targetId),(ConvertTo-HtmlText $r.reason)))
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    Set-Content -LiteralPath $htmlPath -Value $sb.ToString() -Encoding UTF8

    # ---- console + code de sortie ----
    Write-Host ""
    Write-Host "=== Reconciliation ===" -ForegroundColor Magenta
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) { Write-Host ("  {0,-11}: {1}" -f $o,$summary[$o]) }
    Write-Host ("  Completude : {0} outcomes == {1} vus -> {2}" -f @($allCanon).Count,$seen,($(if($invariantOK){'OK'}else{'FAIL'}))) -ForegroundColor ($(if($invariantOK){'Green'}else{'Red'}))
    Write-Host ("  reconcile.json : {0}" -f $jsonPath) -ForegroundColor Cyan
    Write-Host ("  reconcile.html : {0}" -f $htmlPath) -ForegroundColor Cyan
    Write-Host ("  reconcile.csv  : {0}" -f $csvPath)  -ForegroundColor Cyan

    if ($criticalNotApplied.Count -gt 0 -and $Execute) {
        Write-Host ""
        Write-Host "################################################################" -ForegroundColor Red
        Write-Host "#  SECURITY-CRITICAL NOT APPLIED  --  ACTION MANUELLE REQUISE   #" -ForegroundColor Red
        Write-Host "################################################################" -ForegroundColor Red
        foreach ($r in $criticalNotApplied) { Write-Host ("  [!] {0} | {1} -> {2} ({3})" -f $r.family,$r.sourceName,$r.outcome,$r.reason) -ForegroundColor Red }
        $script:ReconExitCode = 2
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Import Intune CORRIGE v3 ===  Phase=$Phase  Execute=$($Execute.IsPresent)" -ForegroundColor Magenta
if (-not $Execute) { Write-Host "MODE PREVIEW : aucune ecriture. Ajouter -Execute pour importer." -ForegroundColor Yellow }
Assert-Target

$selected = if ($Phase -eq 'All') { $Catalog } else { $Catalog | Where-Object { $_.Phase -eq $Phase } }

foreach ($cat in $selected) {
    $folder = Join-Path $SourcePath $cat.Folder
    if (-not (Test-Path $folder)) { continue }
    $files = @(Get-ChildItem $folder -Filter *.json -File)
    if ($files.Count -eq 0) { continue }
    $script:SourceFileCount += $files.Count   # P1-1 : enumere independamment d'Add-Result -> un fichier drope fait ECHOUER l'invariant

    Write-Host ""
    Write-Host ("--- {0} ({1} fichier(s)) ---" -f $cat.Folder,$files.Count) -ForegroundColor Cyan

    # P1-4 : juste avant les AppConfigurations, si aucune AppIdMap n'a ete fournie/chargee, la construire
    # depuis le tenant CIBLE (apps creees pendant la vague Apps de ce meme run) pour que les configs dont
    # l'app cible existe soient importees au lieu d'un SKIP_UNMAPPED systematique.
    if ($cat.Special -eq 'AppConfig' -and $script:AppIdMap.Count -eq 0) { Build-TargetAppIdMap }

    # Idempotence : cle (nom + discriminateur de type/plateforme) -> id CIBLE dans le tenant cible.
    # P1-1 : Dictionary cle->targetId (etait un HashSet) pour qu'un MATCHED puisse PROUVER la cible preexistante mappee.
    $existingKeys = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    try {
        foreach ($e in @(Get-AllValues -Path $cat.Path)) {
            $k = Get-IdempotencyKey -Obj $e -Cat $cat
            if ($k) { $existingKeys[$k] = [string]$e.id }   # stocke l'id de l'objet cible (dernier gagne sur cle en doublon)
        }
    } catch { Write-Host ("  [!] Lecture existants impossible ({0}) : {1}" -f $cat.Path,$_.Exception.Message) -ForegroundColor Yellow }

    # P1-1 : IdentityKey source deja produites DANS CE run (par famille) -> fail-dur des fichiers source en doublon.
    $seenIdentity = @{}

    foreach ($f in $files) {
        $script:RemapLog = New-Object System.Collections.Generic.List[object]   # P1-1 : trace de remap pour CET objet
        $script:AdminDefValues = @()                                            # ADMX : reinitialise le stash des definitionValues par objet
        $obj  = Read-JsonFile $f.FullName
        $script:SourceSeenCount++                                               # P1-1 completude : un objet SOURCE vu
        # SourceName = nom source NON prefixe ; AppliedName ($name) = nom reellement pousse (prefixe).
        $sourceName = if ($obj[$cat.Name]) { [string]$obj[$cat.Name] } elseif ($obj['displayName']) { [string]$obj['displayName'] } else { [string]$obj['name'] }
        $name = $sourceName
        if ($NamePrefix) { $name = $NamePrefix + $name }
        # IdentityKey ENREGISTREE = cle logique sur le nom source NON prefixe (neutre backend, independante du prefixe).
        $identityKey = Get-IdempotencyKey -Obj $obj -Cat $cat
        # $key = cle de MATCH contre la cible (prefixee dans un run prefixe) -- le match cible est INCHANGE.
        $key  = Get-IdempotencyKey -Obj $obj -Cat $cat -NameOverride $name

        # P1-1 collision : deux fichiers source DIFFERENTS avec la meme IdentityKey logique -> fail-dur le second
        # (ne pas le laisser absorber en silence comme EXISTS). Verifie AVANT le match EXISTS, volontairement.
        if ($identityKey -and $seenIdentity.ContainsKey($identityKey)) {
            $dupReason = "IdentityKey en doublon '$identityKey' deja produite par la source '$($seenIdentity[$identityKey])' dans ce run"
            Add-Result $cat.Folder $name 'SKIP_DUP_KEY' $dupReason $null $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
            Write-Host ("  [!] SKIP_DUP_KEY {0} -- {1}" -f $name,$dupReason) -ForegroundColor Red
            continue
        }
        if ($identityKey) { $seenIdentity[$identityKey] = $f.Name }

        if ($existingKeys.ContainsKey($key)) {
            $tid = $existingKeys[$key]
            Add-Result $cat.Folder $name 'EXISTS' 'Meme cle (nom+type) deja presente' $tid $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
            Write-Host ("  [=] {0}" -f $name) -ForegroundColor DarkGray
            continue
        }

        try { $payload = Build-Payload -O $obj -Cat $cat }
        catch {
            $reason = $_.Exception.Message
            Add-Result $cat.Folder $name ($reason.Split(':')[0].Trim()) $reason $null $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
            Write-Host ("  [~] {0} -- {1}" -f $name,$reason) -ForegroundColor Yellow
            continue
        }

        if ($NamePrefix -and $payload.Contains($cat.Name)) { $payload[$cat.Name] = $name }

        if (-not $Execute) {
            $extra = if ($cat.Special -eq 'SettingsCatalog') { "settings=$((@($payload['settings'])).Count)" }
                     elseif ($cat.Special -eq 'ConditionalAccess') { 'DESACTIVEE / activation-manuelle-requise' }
                     elseif ($cat.Special -eq 'AdminTemplate') {
                        # ADMX dry-run : resoudre chaque definitionValue contre le catalogue CIBLE SANS POSTer.
                        $dvs = @($script:AdminDefValues); $r=0; $s=0
                        foreach ($dv in $dvs) { try { [void](Resolve-AdmxDefinitionValue -Dv $dv); $r++ } catch { $s++ } }
                        "defvals=$($dvs.Count) resolved=$r skipped=$s"
                     } else { '' }
            Add-Result $cat.Folder $name 'PREVIEW' $extra $null $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey -Remap $script:RemapLog
            Write-Host ("  [.] PREVIEW {0} {1}" -f $name,$extra) -ForegroundColor Gray
            continue
        }

        try {
            $json = $payload | ConvertTo-Json -Depth 100
            $created = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/$($cat.Path)" -Body $json -ContentType 'application/json' }
            if ($cat.Special -eq 'ConditionalAccess') {
                # Outcome DISTINCT : une CA creee DESACTIVEE avec refs remappees n'est JAMAIS un clone abouti (activation manuelle requise).
                Add-Result $cat.Folder $name 'CREATED-DISABLED' 'Creee-DESACTIVEE / references-remappees / activation-manuelle-requise' $created.id $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey -Remap $script:RemapLog
            } else {
                Add-Result $cat.Folder $name 'CREATED' '' $created.id $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey -Remap $script:RemapLog
            }
            $existingKeys[$key] = [string]$created.id   # evite un doublon si 2 fichiers source ont la meme cle dans le meme run
            Write-Host ("  [+] {0}" -f $name) -ForegroundColor Green

            # Notification templates : POST des messages localises apres creation
            if ($cat.Special -eq 'Notification' -and $created.id -and $obj['localizedNotificationMessages']) {
                foreach ($m in @($obj['localizedNotificationMessages'])) {
                    $mm = [ordered]@{}; foreach($k in $m.Keys){ if($k -notin @('id','lastModifiedDateTime')){ $mm[$k]=$m[$k] } }
                    try {
                        Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method POST -ContentType 'application/json' `
                          -Uri "$GraphBase/deviceManagement/notificationMessageTemplates/$($created.id)/localizedNotificationMessages" `
                          -Body ($mm | ConvertTo-Json -Depth 20) } | Out-Null
                    } catch { Add-Result ($cat.Folder+'/msg') ("$name/$($m.locale)") 'ERROR' '' $created.id $_.Exception.Message }
                }
            }

            # ADMX : apres creation de la coquille, POST chaque definitionValue avec @odata.bind remappe CIBLE.
            # Chaque valeur est independante (try/catch) : une non resolue est SKIP sans casser les autres ;
            # la coquille de config existe deja, le tenant n'est donc jamais brické -- seules les valeurs non mappables manquent.
            if ($cat.Special -eq 'AdminTemplate' -and $created.id) {
                $dvs = @($script:AdminDefValues); $nRes=0; $nSkip=0
                foreach ($dv in $dvs) {
                    $defName = ''
                    if ($dv['definition'] -is [hashtable]) { $defName = [string]$dv['definition']['displayName'] }
                    try {
                        $dvBody = Resolve-AdmxDefinitionValue -Dv $dv
                        Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method POST -ContentType 'application/json' `
                          -Uri "$GraphBase/deviceManagement/groupPolicyConfigurations/$($created.id)/definitionValues" `
                          -Body ($dvBody | ConvertTo-Json -Depth 100) } | Out-Null
                        $nRes++
                    } catch {
                        $dvReason = $_.Exception.Message
                        $dvStatus = $dvReason.Split(':')[0].Trim()
                        if ($dvStatus -notlike 'SKIP*') { $dvStatus = 'ERROR' }
                        $nSkip++
                        Add-Result ($cat.Folder+'/defval') ("$name / $defName") $dvStatus $dvReason $created.id $dvReason
                    }
                }
                Write-Host ("      defvals={0} resolved={1} skipped={2}" -f @($dvs).Count,$nRes,$nSkip) -ForegroundColor DarkCyan
            }
        } catch {
            Add-Result $cat.Folder $name 'ERROR' '' $null $_.Exception.Message -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
            Write-Host ("  [X] {0} -- {1}" -f $name, ($_.Exception.Message -replace '\s+',' ').Substring(0,[Math]::Min(140,($_.Exception.Message).Length))) -ForegroundColor Red
        }
    }
}

# Journal
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$script:Results | Select-Object * -ExcludeProperty Remap | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== Bilan ($Phase) ===" -ForegroundColor Magenta
$script:Results | Group-Object Status | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize
Write-Host ("Journal CSV : {0}" -f $LogPath) -ForegroundColor Cyan

# P1-1 : rapport de reconciliation (reconcile.json/html/csv) + garde SECURITY-CRITICAL. exit 2 en -Execute seulement.
Write-Reconciliation
if ($script:ReconExitCode -ne 0) {
    exit $script:ReconExitCode   # standalone : sortie non nulle. Dans le build module cette ligne devient 'return' (ne jamais tuer le host).
}

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
)

function Add-Result {
    param($Family,$Name,$Status,$Reason,$GraphId,$Err)
    $script:Results.Add([pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Family=$Family; Name=$Name; Status=$Status
        Reason=$Reason; GraphId=$GraphId; Error=$Err
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
        $r = Invoke-MgGraphRequest -Method GET -Uri $u
        if ($r.value) { $all += @($r.value) }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # Streamer les elements (defense en profondeur). L'appelant enchaine "| ForEach-Object",
    # donc ",$all" fonctionnait, mais "return $all" evite tout risque de collapse si l'appel change.
    return $all
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
            # Remap targetedMobileApps (IDs d'apps SOURCE -> cible) via AppIdMap.csv ; SKIP si non mappe.
            # Uniquement si -AppIdMapPath est fourni (mode remap) ; sinon on garde les IDs source.
            if ($AppIdMapPath -and $O.ContainsKey('targetedMobileApps') -and @($O['targetedMobileApps']).Count -gt 0) {
                $mapped = @()
                foreach ($sid in @($O['targetedMobileApps'])) {
                    $tid = $script:AppIdMap[[string]$sid]
                    if ([string]::IsNullOrWhiteSpace($tid)) { throw "SKIP_UNMAPPED : app source $sid sans equivalent cible dans AppIdMap.csv -> config non importee." }
                    $mapped += $tid
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
        default { return (New-GenericPayload -O $O -Cat $Cat) }
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

    Write-Host ""
    Write-Host ("--- {0} ({1} fichier(s)) ---" -f $cat.Folder,$files.Count) -ForegroundColor Cyan

    # Idempotence : cles (nom + discriminateur de type/plateforme) deja presentes dans la cible
    $existingKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        foreach ($e in @(Get-AllValues -Path $cat.Path)) {
            $k = Get-IdempotencyKey -Obj $e -Cat $cat
            if ($k) { [void]$existingKeys.Add($k) }
        }
    } catch { Write-Host ("  [!] Lecture existants impossible ({0}) : {1}" -f $cat.Path,$_.Exception.Message) -ForegroundColor Yellow }

    foreach ($f in $files) {
        $obj  = Read-JsonFile $f.FullName
        $name = if ($obj[$cat.Name]) { [string]$obj[$cat.Name] } elseif ($obj['displayName']) { [string]$obj['displayName'] } else { [string]$obj['name'] }
        if ($NamePrefix) { $name = $NamePrefix + $name }
        $key  = Get-IdempotencyKey -Obj $obj -Cat $cat -NameOverride $name

        if ($existingKeys.Contains($key)) {
            Add-Result $cat.Folder $name 'EXISTS' 'Meme cle (nom+type) deja presente' $null $null
            Write-Host ("  [=] {0}" -f $name) -ForegroundColor DarkGray
            continue
        }

        try { $payload = Build-Payload -O $obj -Cat $cat }
        catch {
            $reason = $_.Exception.Message
            Add-Result $cat.Folder $name ($reason.Split(':')[0].Trim()) $reason $null $null
            Write-Host ("  [~] {0} -- {1}" -f $name,$reason) -ForegroundColor Yellow
            continue
        }

        if ($NamePrefix -and $payload.Contains($cat.Name)) { $payload[$cat.Name] = $name }

        if (-not $Execute) {
            $extra = if ($cat.Special -eq 'SettingsCatalog') { "settings=$((@($payload['settings'])).Count)" } elseif ($cat.Special -eq 'ConditionalAccess') { 'DESACTIVEE / activation-manuelle-requise' } else { '' }
            Add-Result $cat.Folder $name 'PREVIEW' $extra $null $null
            Write-Host ("  [.] PREVIEW {0} {1}" -f $name,$extra) -ForegroundColor Gray
            continue
        }

        try {
            $json = $payload | ConvertTo-Json -Depth 100
            $created = Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/$($cat.Path)" -Body $json -ContentType 'application/json'
            if ($cat.Special -eq 'ConditionalAccess') {
                # Outcome DISTINCT : une CA creee DESACTIVEE avec refs remappees n'est JAMAIS un clone abouti (activation manuelle requise).
                Add-Result $cat.Folder $name 'CREATED-DISABLED' 'Creee-DESACTIVEE / references-remappees / activation-manuelle-requise' $created.id $null
            } else {
                Add-Result $cat.Folder $name 'CREATED' '' $created.id $null
            }
            [void]$existingKeys.Add($key)   # evite un doublon si 2 fichiers source ont la meme cle dans le meme run
            Write-Host ("  [+] {0}" -f $name) -ForegroundColor Green

            # Notification templates : POST des messages localises apres creation
            if ($cat.Special -eq 'Notification' -and $created.id -and $obj['localizedNotificationMessages']) {
                foreach ($m in @($obj['localizedNotificationMessages'])) {
                    $mm = [ordered]@{}; foreach($k in $m.Keys){ if($k -notin @('id','lastModifiedDateTime')){ $mm[$k]=$m[$k] } }
                    try {
                        Invoke-MgGraphRequest -Method POST -ContentType 'application/json' `
                          -Uri "$GraphBase/deviceManagement/notificationMessageTemplates/$($created.id)/localizedNotificationMessages" `
                          -Body ($mm | ConvertTo-Json -Depth 20) | Out-Null
                    } catch { Add-Result ($cat.Folder+'/msg') ("$name/$($m.locale)") 'ERROR' '' $created.id $_.Exception.Message }
                }
            }
        } catch {
            Add-Result $cat.Folder $name 'ERROR' '' $null $_.Exception.Message
            Write-Host ("  [X] {0} -- {1}" -f $name, ($_.Exception.Message -replace '\s+',' ').Substring(0,[Math]::Min(140,($_.Exception.Message).Length))) -ForegroundColor Red
        }
    }
}

# Journal
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$script:Results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== Bilan ($Phase) ===" -ForegroundColor Magenta
$script:Results | Group-Object Status | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize
Write-Host ("Journal CSV : {0}" -f $LogPath) -ForegroundColor Cyan

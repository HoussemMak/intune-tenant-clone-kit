#Requires -Version 7.0
<#
.SYNOPSIS
    Migration ZERO-TOUCH des AFFECTATIONS Intune (groupes + assignments) SOURCE -> CIBLE.
    Portage moderne, 100% non-interactif, des 3 scripts legacy :
      - Export-IntuneAssignmentsAndGroups_MSGraphLegacy.ps1
      - Import-IntuneGroups_MSGraphLegacy.ps1
      - Set-IntuneAssignments_MSGraphLegacy.ps1
    en un seul script base sur Microsoft.Graph.Authentication + Invoke-MgGraphRequest.

.DESCRIPTION
    Remplace le module deprecie Microsoft.Graph.Intune (Connect-MSGraph interactif) par une
    connexion app-only CERTIFICAT identique au reste du kit (Connect-GraphForIntuneAutomation,
    variables d'environnement INTUNE_AUTO_*). AUCUN Read-Host, AUCUN popup de connexion.

    Trois phases, enchainables via -Phase All :
      Export  (SOURCE, lecture seule)  -> assignments-map.json, groups-catalog.json,
                                           filters-catalog.json, manifest-assignments.json
      Groups  (CIBLE, ecriture)        -> recree les groupes manquants, ecrit groups-idmap.json
      Assign  (CIBLE, ecriture)        -> remappe par NOM (groupes + filtres) et POST .../{id}/assign

    PREVIEW par defaut : sans -Execute, aucune ecriture (les groupes/affectations sont seulement
    simules et journalises). Ajouter -Execute pour appliquer.

    Garde-fous : refuse d'ecrire si le contexte CIBLE == tenant SOURCE de l'export.

.PARAMETER SourceTenantId
    GUID du tenant SOURCE (lecture). Requis pour la phase Export.

.PARAMETER TargetTenantId
    GUID du tenant CIBLE (ecriture). Requis pour Groups/Assign.

.PARAMETER Phase
    Export | Groups | Assign | All (defaut All).

.PARAMETER AssignmentsPath
    Dossier de travail Assignments_* (contient les .json). Cree si la phase Export s'execute.
    Si absent : cree sous -WorkRoot pour Export/All, sinon reutilise le plus recent.

.PARAMETER WorkRoot
    Racine ou creer/chercher le dossier Assignments_* (defaut .\IntuneExport_Assignments).

.PARAMETER Execute
    Ecriture reelle. Absent = PREVIEW (aucun POST).

.PARAMETER StaticOnlyGroups
    Recree les groupes dynamiques en STATIQUE vide (ignore membershipRule) - plus sur en bac a sable.

.PARAMETER OnlyFamilies
    Limite la phase Assign a certaines familles (ex. 01_DeviceConfigurations).

.PARAMETER LogPath
    Journal CSV (Family,Name,Status,Reason). Defaut sous le dossier Assignments_*.

.NOTES
    Auth app-only attendue via variables d'environnement (posees par l'orchestrateur) :
      INTUNE_AUTO_SOURCE_TENANT_ID / INTUNE_AUTO_SOURCE_CLIENT_ID / INTUNE_AUTO_SOURCE_CERT_THUMBPRINT
      INTUNE_AUTO_TARGET_TENANT_ID / INTUNE_AUTO_TARGET_CLIENT_ID / INTUNE_AUTO_TARGET_CERT_THUMBPRINT
    Permissions applicatives requises (consentement admin) :
      SOURCE : DeviceManagement*.Read.All, Group.Read.All, Organization.Read.All
      CIBLE  : DeviceManagement*.ReadWrite.All, Group.ReadWrite.All, Organization.Read.All
#>
[CmdletBinding()]
param(
    [string]$SourceTenantId,
    [string]$TargetTenantId,
    [ValidateSet('Export','Groups','Assign','All')][string]$Phase = 'All',
    [string]$AssignmentsPath,
    [string]$WorkRoot = (Join-Path (Get-Location) 'IntuneExport_Assignments'),
    [switch]$Execute,
    [switch]$StaticOnlyGroups,
    [string[]]$OnlyFamilies,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$GraphBase = 'https://graph.microsoft.com/beta'
$script:Log = New-Object System.Collections.Generic.List[object]

# Familles portant des affectations (memes endpoints que l'export de configuration).
$AssignableCatalog = @(
    @{ Folder='01_DeviceConfigurations';  Path='deviceManagement/deviceConfigurations';               DisplayProp='displayName' }
    @{ Folder='02_ConfigurationPolicies'; Path='deviceManagement/configurationPolicies';              DisplayProp='name'        }
    @{ Folder='03_CompliancePolicies';    Path='deviceManagement/deviceCompliancePolicies';           DisplayProp='displayName' }
    @{ Folder='04_ScriptsPowerShell';     Path='deviceManagement/deviceManagementScripts';            DisplayProp='displayName' }
    @{ Folder='05_ScriptsShell';          Path='deviceManagement/deviceShellScripts';                 DisplayProp='displayName' }
    @{ Folder='06_Remediations';          Path='deviceManagement/deviceHealthScripts';                DisplayProp='displayName' }
    @{ Folder='09_Apps';                  Path='deviceAppManagement/mobileApps';                      DisplayProp='displayName' }
    @{ Folder='10_AppConfigurations';     Path='deviceAppManagement/mobileAppConfigurations';         DisplayProp='displayName' }
    @{ Folder='11_AppProtection';         Path='deviceAppManagement/managedAppPolicies';              DisplayProp='displayName' }
    @{ Folder='12_AutopilotProfiles';     Path='deviceManagement/windowsAutopilotDeploymentProfiles'; DisplayProp='displayName' }
)

function Write-Info { param([string]$T) Write-Host ("[INFO] {0}" -f $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ("[OK]   {0}" -f $T) -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host ("[WARN] {0}" -f $T) -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host ("[ERR]  {0}" -f $T) -ForegroundColor Red }

function Add-Log {
    param([string]$Family,[string]$Name,[string]$Status,[string]$Reason)
    $script:Log.Add([pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Family=$Family; Name=$Name; Status=$Status; Reason=$Reason
    }) | Out-Null
}

# --- Connexion app-only certificat via variables INTUNE_AUTO_* (identique au reste du kit) ---
function Connect-GraphForIntuneAutomation {
    param([Parameter(Mandatory=$true)][string]$TenantId,[string[]]$Scopes)
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $tenantLower  = $TenantId.ToLowerInvariant()
    $sourceTenant = $env:INTUNE_AUTO_SOURCE_TENANT_ID
    $targetTenant = $env:INTUNE_AUTO_TARGET_TENANT_ID
    $clientId = $null; $certThumb = $null

    if ($sourceTenant -and ($tenantLower -eq $sourceTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_SOURCE_CLIENT_ID; $certThumb = $env:INTUNE_AUTO_SOURCE_CERT_THUMBPRINT
    }
    if ($targetTenant -and ($tenantLower -eq $targetTenant.ToLowerInvariant())) {
        $clientId = $env:INTUNE_AUTO_TARGET_CLIENT_ID; $certThumb = $env:INTUNE_AUTO_TARGET_CERT_THUMBPRINT
    }
    if (-not $clientId  -and $env:INTUNE_AUTO_CLIENT_ID)       { $clientId  = $env:INTUNE_AUTO_CLIENT_ID }
    if (-not $certThumb -and $env:INTUNE_AUTO_CERT_THUMBPRINT) { $certThumb = $env:INTUNE_AUTO_CERT_THUMBPRINT }

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower) `
        -and $clientId -and $ctx.ClientId -and ($ctx.ClientId -eq $clientId)) { return }

    if ($clientId -and $certThumb) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $TenantId -ClientId $clientId -CertificateThumbprint $certThumb -ContextScope Process -NoWelcome | Out-Null
    } else {
        # Repli interactif UNIQUEMENT si aucune identite app-only n'est fournie (hors zero-touch).
        if ($ctx -and $ctx.TenantId -and ($ctx.TenantId.ToLowerInvariant() -eq $tenantLower)) { return }
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
    }

    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.TenantId) { throw "Connexion Graph non valide (tenant $TenantId)." }
    if ($ctx.TenantId.ToLowerInvariant() -ne $tenantLower) {
        throw "Mauvais tenant apres connexion. Attendu=$TenantId ; connecte=$($ctx.TenantId)"
    }
}

function Get-TenantDisplay {
    try { return ((Invoke-MgGraphRequest -Method GET -Uri "$GraphBase/organization").value | Select-Object -First 1) } catch { return $null }
}

function Get-All {
    param([Parameter(Mandatory=$true)][string]$RelPath)
    $all = @(); $u = "$GraphBase/$RelPath"
    do {
        $r = Invoke-MgGraphRequest -Method GET -Uri $u
        if     ($r.value) { $all += @($r.value) }
        elseif ($r.id)    { $all += $r }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # Streamer les elements ($all) et non ",$all" : sinon "@(Get-All ...)" re-emballe la collection
    # en un seul element et le foreach n'itere qu'une fois (meme bug que l'export FraisComplet v1).
    return $all
}

function Get-Prop { param($Obj,[string]$Prop) if ($null -eq $Obj) { return $null }; return $Obj.$Prop }

function Get-TargetGroupId {
    param($Target)
    if (-not $Target) { return $null }
    $t = $Target.'@odata.type'
    if ($t -match 'groupAssignmentTarget' -or $t -match 'exclusionGroupAssignmentTarget') { return $Target.groupId }
    return $null
}
function Get-TargetFilterId {
    param($Target)
    if ($Target -and $Target.deviceAndAppManagementAssignmentFilterId `
        -and $Target.deviceAndAppManagementAssignmentFilterId -ne '00000000-0000-0000-0000-000000000000') {
        return $Target.deviceAndAppManagementAssignmentFilterId
    }
    return $null
}
function Get-SafeMailNickname {
    param([string]$Base,[string]$Fallback)
    $src = if (-not [string]::IsNullOrWhiteSpace($Base)) { $Base } else { $Fallback }
    $nick = ($src -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($nick)) { $nick = 'grp' + ([guid]::NewGuid().Guid.Substring(0,8)) }
    if ($nick.Length -gt 60) { $nick = $nick.Substring(0,60) }
    return $nick
}

# =========================================================================
# PHASE EXPORT (SOURCE, lecture seule)
# =========================================================================
function Invoke-ExportPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($SourceTenantId)) { throw 'SourceTenantId requis pour la phase Export.' }
    Write-Info "Phase EXPORT - connexion app-only SOURCE ($SourceTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $SourceTenantId -Scopes @(
        'DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All',
        'DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All','Group.Read.All')
    $org = Get-TenantDisplay
    Write-Ok ("SOURCE : {0} ({1})" -f (Get-Prop $org 'displayName'), (Get-MgContext).TenantId)

    New-Item -ItemType Directory -Force $Root | Out-Null

    # 1) Filtres (id -> nom)
    $filterMap = @{}
    try {
        foreach ($f in @(Get-All 'deviceManagement/assignmentFilters')) { if ($f.id) { $filterMap[$f.id] = $f.displayName } }
        Write-Ok ("{0} filtre(s) inventorie(s)" -f $filterMap.Count)
    } catch { Write-Warn2 "Lecture filtres impossible : $($_.Exception.Message)" }

    # 2) Affectations par objet
    $assignmentRecords = @()
    $groupIds      = New-Object System.Collections.Generic.HashSet[string]
    $filterIdsUsed = New-Object System.Collections.Generic.HashSet[string]

    foreach ($cat in $AssignableCatalog) {
        try { $items = @(Get-All $cat.Path) }
        catch { Write-Warn2 ("{0} : famille illisible ({1})" -f $cat.Folder, $_.Exception.Message); continue }
        $withAssign = 0
        foreach ($it in $items) {
            if (-not $it.id) { continue }
            $name = (Get-Prop $it $cat.DisplayProp)
            if (-not $name) { $name = if ($it.displayName) { $it.displayName } elseif ($it.name) { $it.name } else { $it.id } }
            $assigns = @()
            try { $assigns = @(Get-All ("{0}/{1}/assignments" -f $cat.Path, $it.id)) } catch {}
            if ($assigns.Count -eq 0) { continue }
            $withAssign++

            $cleanAssigns = @()
            foreach ($a in $assigns) {
                $gid = Get-TargetGroupId  -Target $a.target; if ($gid) { [void]$groupIds.Add($gid) }
                $fid = Get-TargetFilterId -Target $a.target; if ($fid) { [void]$filterIdsUsed.Add($fid) }
                $cleanAssigns += [pscustomobject]@{ intent=$a.intent; source=$a.source; target=$a.target }
            }
            $assignmentRecords += [pscustomobject]@{
                Family=$cat.Folder; EndpointPath=$cat.Path; ObjectName=$name
                ObjectType=$it.'@odata.type'; Assignments=$cleanAssigns
            }
        }
        Write-Ok ("{0,-26} {1,3} objet(s), {2,3} avec affectation(s)" -f $cat.Folder, $items.Count, $withAssign)
    }

    # 3) Catalogue des groupes Entra referen ces
    $groupsCatalog = @(); $groupErrors = @()
    $props = 'id,displayName,mailNickname,description,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled'
    foreach ($gid in $groupIds) {
        try {
            $g = Invoke-MgGraphRequest -Method GET -Uri ("{0}/groups/{1}?`$select={2}" -f $GraphBase, $gid, $props)
            $groupsCatalog += [pscustomobject]@{
                oldId=$g.id; displayName=$g.displayName; mailNickname=$g.mailNickname; description=$g.description
                groupTypes=@($g.groupTypes); membershipRule=$g.membershipRule
                membershipRuleProcessingState=$g.membershipRuleProcessingState
                securityEnabled=$g.securityEnabled; mailEnabled=$g.mailEnabled
            }
        } catch { $groupErrors += [pscustomobject]@{ oldId=$gid; Error=$_.Exception.Message } }
    }
    $dyn = @($groupsCatalog | Where-Object { $_.groupTypes -contains 'DynamicMembership' }).Count
    Write-Ok ("{0} groupe(s) lu(s) ({1} dynamique(s)), {2} en erreur" -f $groupsCatalog.Count, $dyn, $groupErrors.Count)

    # 4) Sauvegardes
    ($assignmentRecords | ConvertTo-Json -Depth 40) | Set-Content (Join-Path $Root 'assignments-map.json') -Encoding UTF8
    ($groupsCatalog     | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $Root 'groups-catalog.json')  -Encoding UTF8
    ($filterMap.GetEnumerator() | ForEach-Object { [pscustomobject]@{ oldId=$_.Key; displayName=$_.Value } } |
        ConvertTo-Json -Depth 5) | Set-Content (Join-Path $Root 'filters-catalog.json') -Encoding UTF8
    ([pscustomobject]@{
        Version='2.0-graph-apponly'; ExportedAt=(Get-Date).ToString('o')
        TenantId=(Get-MgContext).TenantId; TenantName=(Get-Prop $org 'displayName')
        Counts=[pscustomobject]@{
            ObjectsWithAssignments=$assignmentRecords.Count; GroupsReferenced=$groupsCatalog.Count
            GroupsUnreadable=$groupErrors.Count; FiltersReferenced=$filterIdsUsed.Count }
        GroupErrors=$groupErrors
    } | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $Root 'manifest-assignments.json') -Encoding UTF8

    Add-Log 'Assignments' 'Export' 'EXISTS' ("{0} objets, {1} groupes, {2} filtres" -f $assignmentRecords.Count, $groupsCatalog.Count, $filterIdsUsed.Count)
    Write-Ok ("Export affectations ecrit dans : {0}" -f $Root)
}

# =========================================================================
# PHASE GROUPS (CIBLE, ecriture)
# =========================================================================
function Invoke-GroupsPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($TargetTenantId)) { throw 'TargetTenantId requis pour la phase Groups.' }
    $catalogPath = Join-Path $Root 'groups-catalog.json'
    if (-not (Test-Path $catalogPath)) { throw "groups-catalog.json introuvable dans $Root (lancer la phase Export d'abord)." }
    $catalog = @(Get-Content $catalogPath -Raw | ConvertFrom-Json)

    $srcTenant = $null
    $manifestPath = Join-Path $Root 'manifest-assignments.json'
    if (Test-Path $manifestPath) { try { $srcTenant = (Get-Content $manifestPath -Raw | ConvertFrom-Json).TenantId } catch {} }

    Write-Info "Phase GROUPS - connexion app-only CIBLE ($TargetTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes @('Group.ReadWrite.All')
    $ctxTid = (Get-MgContext).TenantId
    if ($srcTenant -and ($ctxTid.ToLowerInvariant() -eq $srcTenant.ToLowerInvariant())) {
        throw "GARDE-FOU : la CIBLE ($ctxTid) est identique a la SOURCE de l'export. Ecriture refusee."
    }
    Write-Ok ("CIBLE : {0}" -f $ctxTid)

    $existing = @(Get-All 'groups?$select=id,displayName,mailNickname')
    $byName=@{}; $byNick=@{}
    foreach ($g in $existing) {
        if ($g.displayName)  { $byName[$g.displayName.ToLowerInvariant()] = $g }
        if ($g.mailNickname) { $byNick[$g.mailNickname.ToLowerInvariant()] = $g }
    }
    Write-Ok ("{0} groupe(s) existant(s) dans la cible" -f $existing.Count)

    $plan = @()
    foreach ($src in $catalog) {
        $match = $null
        if ($src.displayName -and $byName.ContainsKey($src.displayName.ToLowerInvariant()))      { $match = $byName[$src.displayName.ToLowerInvariant()] }
        elseif ($src.mailNickname -and $byNick.ContainsKey($src.mailNickname.ToLowerInvariant())) { $match = $byNick[$src.mailNickname.ToLowerInvariant()] }
        $isDynamic = ($src.groupTypes -contains 'DynamicMembership') -and (-not $StaticOnlyGroups)
        $plan += [pscustomobject]@{
            displayName=$src.displayName; oldId=$src.oldId
            newId=if ($match) { $match.id } else { $null }
            Status=if ($match) { 'EXISTS' } else { 'NEW' }
            Dynamic=$isDynamic; _src=$src
        }
    }
    $toCreate = @($plan | Where-Object Status -eq 'NEW')
    $exists   = @($plan | Where-Object Status -eq 'EXISTS')
    Write-Info ("Groupes -> a creer : {0} | deja presents : {1} | total : {2}" -f $toCreate.Count, $exists.Count, $plan.Count)
    foreach ($p in $exists) { Add-Log 'Groups' $p.displayName 'EXISTS' 'deja present' }

    if (-not $Execute) {
        foreach ($p in $toCreate) { Add-Log 'Groups' $p.displayName 'PREVIEW' ("creation prevue ({0})" -f $(if($p.Dynamic){'dynamique'}else{'statique'})) }
        ($plan | Select-Object displayName,oldId,newId,Status,Dynamic | ConvertTo-Json -Depth 5) |
            Set-Content (Join-Path $Root 'groups-idmap.PREVIEW.json') -Encoding UTF8
        Write-Warn2 ("PREVIEW : {0} groupe(s) seraient crees. Mapping partiel : groups-idmap.PREVIEW.json" -f $toCreate.Count)
        return
    }

    foreach ($p in $toCreate) {
        $src = $p._src
        $body = [ordered]@{
            displayName=$src.displayName; mailEnabled=$false; securityEnabled=$true
            mailNickname=Get-SafeMailNickname -Base $src.mailNickname -Fallback $src.displayName
        }
        if ($src.description) { $body.description = $src.description }
        if ($p.Dynamic -and $src.membershipRule) {
            $body.groupTypes = @('DynamicMembership')
            $body.membershipRule = $src.membershipRule
            $body.membershipRuleProcessingState = if ($src.membershipRuleProcessingState) { $src.membershipRuleProcessingState } else { 'On' }
        } else { $body.groupTypes = @() }
        $json = ($body | ConvertTo-Json -Depth 10)
        try {
            $created = Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/groups" -Body $json -ContentType 'application/json'
            $p.newId = $created.id; $p.Status = 'CREATED'
            Add-Log 'Groups' $p.displayName 'CREATED' ''
            Write-Ok ("+ groupe {0}" -f $p.displayName)
        } catch {
            $p.Status = 'ERROR'
            Add-Log 'Groups' $p.displayName 'ERROR' $_.Exception.Message
            Write-Bad ("groupe {0} -- {1}" -f $p.displayName, $_.Exception.Message)
        }
    }

    ($plan | Select-Object displayName,oldId,newId,Status,Dynamic | ConvertTo-Json -Depth 5) |
        Set-Content (Join-Path $Root 'groups-idmap.json') -Encoding UTF8
    Write-Ok ("Mapping groupes ecrit : {0}" -f (Join-Path $Root 'groups-idmap.json'))
}

# =========================================================================
# PHASE ASSIGN (CIBLE, ecriture)
# =========================================================================
$FamilyMap = @{
    '01_DeviceConfigurations'  = @{ Path='deviceManagement/deviceConfigurations';               DisplayProp='displayName' }
    '02_ConfigurationPolicies' = @{ Path='deviceManagement/configurationPolicies';              DisplayProp='name'        }
    '03_CompliancePolicies'    = @{ Path='deviceManagement/deviceCompliancePolicies';           DisplayProp='displayName' }
    '04_ScriptsPowerShell'     = @{ Path='deviceManagement/deviceManagementScripts';            DisplayProp='displayName' }
    '05_ScriptsShell'          = @{ Path='deviceManagement/deviceShellScripts';                 DisplayProp='displayName' }
    '06_Remediations'          = @{ Path='deviceManagement/deviceHealthScripts';                DisplayProp='displayName' }
    '09_Apps'                  = @{ Path='deviceAppManagement/mobileApps';                      DisplayProp='displayName' }
    '10_AppConfigurations'     = @{ Path='deviceAppManagement/mobileAppConfigurations';         DisplayProp='displayName' }
    '11_AppProtection'         = @{ Path='deviceAppManagement/managedAppPolicies';              DisplayProp='displayName' }
    '12_AutopilotProfiles'     = @{ Path='deviceManagement/windowsAutopilotDeploymentProfiles'; DisplayProp='displayName' }
}

function Invoke-AssignPhase {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($TargetTenantId)) { throw 'TargetTenantId requis pour la phase Assign.' }
    $assignPath = Join-Path $Root 'assignments-map.json'
    if (-not (Test-Path $assignPath)) { throw "assignments-map.json introuvable dans $Root (lancer la phase Export d'abord)." }
    $records = @(Get-Content $assignPath -Raw | ConvertFrom-Json)
    if ($OnlyFamilies) { $records = @($records | Where-Object { $OnlyFamilies -contains $_.Family }) }

    $srcTenant = $null
    $manifestPath = Join-Path $Root 'manifest-assignments.json'
    if (Test-Path $manifestPath) { try { $srcTenant = (Get-Content $manifestPath -Raw | ConvertFrom-Json).TenantId } catch {} }

    $groupNameByOldId = @{}
    $catalogPath = Join-Path $Root 'groups-catalog.json'
    if (Test-Path $catalogPath) {
        foreach ($g in @(Get-Content $catalogPath -Raw | ConvertFrom-Json)) { if ($g.oldId) { $groupNameByOldId[$g.oldId] = $g.displayName } }
    }
    $newIdByOldId = @{}
    $idmapPath = Join-Path $Root 'groups-idmap.json'
    if (Test-Path $idmapPath) {
        foreach ($m in @(Get-Content $idmapPath -Raw | ConvertFrom-Json)) { if ($m.oldId -and $m.newId) { $newIdByOldId[$m.oldId] = $m.newId } }
        Write-Info ("Mapping de groupes charge : {0} correspondance(s)." -f $newIdByOldId.Count)
    } else { Write-Warn2 'groups-idmap.json absent : remap uniquement par recherche live des noms.' }

    $filterNameByOldId = @{}
    $filtersPath = Join-Path $Root 'filters-catalog.json'
    if (Test-Path $filtersPath) {
        foreach ($f in @(Get-Content $filtersPath -Raw | ConvertFrom-Json)) { if ($f.oldId) { $filterNameByOldId[$f.oldId] = $f.displayName } }
    }

    Write-Info "Phase ASSIGN - connexion app-only CIBLE ($TargetTenantId)"
    Connect-GraphForIntuneAutomation -TenantId $TargetTenantId -Scopes @(
        'DeviceManagementConfiguration.ReadWrite.All','DeviceManagementApps.ReadWrite.All',
        'DeviceManagementServiceConfig.ReadWrite.All','Group.Read.All')
    $ctxTid = (Get-MgContext).TenantId
    if ($srcTenant -and ($ctxTid.ToLowerInvariant() -eq $srcTenant.ToLowerInvariant())) {
        throw "GARDE-FOU : la CIBLE ($ctxTid) est identique a la SOURCE de l'export. Ecriture refusee."
    }
    Write-Ok ("CIBLE : {0}" -f $ctxTid)

    # Index live cible : groupes par nom, filtres par nom
    $tgtGroupsByName=@{}
    foreach ($g in @(Get-All 'groups?$select=id,displayName')) { if ($g.displayName) { $tgtGroupsByName[$g.displayName.ToLowerInvariant()] = $g.id } }
    $tgtFiltersByName=@{}
    foreach ($f in @(Get-All 'deviceManagement/assignmentFilters')) { if ($f.displayName) { $tgtFiltersByName[$f.displayName.ToLowerInvariant()] = $f.id } }
    Write-Ok ("{0} groupe(s), {1} filtre(s) dans la cible" -f $tgtGroupsByName.Count, $tgtFiltersByName.Count)

    $resolveGroup = {
        param($OldId)
        if ($newIdByOldId.ContainsKey($OldId) -and $newIdByOldId[$OldId]) { return $newIdByOldId[$OldId] }
        if ($groupNameByOldId.ContainsKey($OldId)) {
            $nm = $groupNameByOldId[$OldId]
            if ($nm -and $tgtGroupsByName.ContainsKey($nm.ToLowerInvariant())) { return $tgtGroupsByName[$nm.ToLowerInvariant()] }
        }
        return $null
    }
    $resolveFilter = {
        param($OldId)
        if ($filterNameByOldId.ContainsKey($OldId)) {
            $nm = $filterNameByOldId[$OldId]
            if ($nm -and $tgtFiltersByName.ContainsKey($nm.ToLowerInvariant())) { return $tgtFiltersByName[$nm.ToLowerInvariant()] }
        }
        return $null
    }

    $unresolved = @()
    foreach ($fam in ($records | Group-Object Family)) {
        $famName = $fam.Name
        if (-not $FamilyMap.ContainsKey($famName)) { continue }
        $path = $FamilyMap[$famName].Path
        $disp = $FamilyMap[$famName].DisplayProp
        Write-Info ("--- {0} ({1} objet(s) avec affectation) ---" -f $famName, $fam.Count)

        $tgtByName=@{}
        foreach ($o in @(Get-All ("{0}?`$select=id,{1}" -f $path, $disp))) {
            $n = (Get-Prop $o $disp); if (-not $n -and $o.displayName) { $n = $o.displayName }
            if ($n) { $tgtByName[$n.ToLowerInvariant()] = $o.id }
        }

        foreach ($rec in $fam.Group) {
            $nameKey = if ($rec.ObjectName) { $rec.ObjectName.ToLowerInvariant() } else { $null }
            if (-not $nameKey -or -not $tgtByName.ContainsKey($nameKey)) {
                Add-Log $famName $rec.ObjectName 'SKIPPED' 'objet absent de la cible'; continue
            }
            $targetId = $tgtByName[$nameKey]

            $newAssignments=@(); $droppedHere=0
            foreach ($a in @($rec.Assignments)) {
                $t = $a.target; if (-not $t) { continue }
                $type = $t.'@odata.type'
                $newTarget = [ordered]@{ '@odata.type' = $type }
                if ($type -match 'groupAssignmentTarget' -or $type -match 'exclusionGroupAssignmentTarget') {
                    $newGid = & $resolveGroup $t.groupId
                    if (-not $newGid) {
                        $droppedHere++
                        $unresolved += [pscustomobject]@{ Family=$famName; Object=$rec.ObjectName; Kind='GROUPE'; OldId=$t.groupId; Name=$groupNameByOldId[$t.groupId] }
                        continue
                    }
                    $newTarget.groupId = $newGid
                }
                $oldFilterId = $t.deviceAndAppManagementAssignmentFilterId
                if ($oldFilterId -and $oldFilterId -ne '00000000-0000-0000-0000-000000000000') {
                    $newFid = & $resolveFilter $oldFilterId
                    if ($newFid) {
                        $newTarget.deviceAndAppManagementAssignmentFilterId = $newFid
                        $newTarget.deviceAndAppManagementAssignmentFilterType = $t.deviceAndAppManagementAssignmentFilterType
                    } else {
                        $unresolved += [pscustomobject]@{ Family=$famName; Object=$rec.ObjectName; Kind='FILTRE (retire)'; OldId=$oldFilterId; Name=$filterNameByOldId[$oldFilterId] }
                    }
                }
                $entry = [ordered]@{ target = $newTarget }
                if ($a.intent) { $entry.intent = $a.intent }
                $newAssignments += $entry
            }

            if ($newAssignments.Count -eq 0) {
                Add-Log $famName $rec.ObjectName 'SKIPPED' ("aucune affectation resolue ({0} abandonnee(s))" -f $droppedHere); continue
            }
            if (-not $Execute) {
                Add-Log $famName $rec.ObjectName 'PREVIEW' ("{0} affectation(s) (dont {1} abandonnee(s))" -f $newAssignments.Count, $droppedHere)
                Write-Host ("  [prev] {0} -> {1} affectation(s)" -f $rec.ObjectName, $newAssignments.Count) -ForegroundColor DarkCyan
                continue
            }
            $json = (@{ assignments = $newAssignments } | ConvertTo-Json -Depth 40)
            try {
                $null = Invoke-MgGraphRequest -Method POST -Uri ("{0}/{1}/{2}/assign" -f $GraphBase, $path, $targetId) -Body $json -ContentType 'application/json'
                Add-Log $famName $rec.ObjectName 'APPLIED' ("{0} affectation(s)" -f $newAssignments.Count)
                Write-Ok ("+ {0} ({1} affectation(s))" -f $rec.ObjectName, $newAssignments.Count)
            } catch {
                Add-Log $famName $rec.ObjectName 'ERROR' $_.Exception.Message
                Write-Bad ("{0} -- {1}" -f $rec.ObjectName, $_.Exception.Message)
            }
        }
    }
    if ($unresolved.Count -gt 0) {
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
        ($unresolved | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $Root "assignments-unresolved_$stamp.json") -Encoding UTF8
        Write-Warn2 ("{0} cible(s) non resolue(s) -> assignments-unresolved_{1}.json" -f $unresolved.Count, $stamp)
    }
}

# =========================================================================
# MAIN
# =========================================================================
try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # Determination du dossier de travail Assignments_*
    if ($AssignmentsPath) { $root = $AssignmentsPath }
    elseif ($Phase -in 'Export','All') { $root = Join-Path $WorkRoot ("Assignments_{0}" -f (Get-Date -Format 'yyyy-MM-dd_HHmm')) }
    else {
        if (-not (Test-Path $WorkRoot)) { throw "WorkRoot introuvable : $WorkRoot" }
        $latest = Get-ChildItem $WorkRoot -Directory -Filter 'Assignments_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "Aucun dossier Assignments_* trouve dans $WorkRoot" }
        $root = $latest.FullName
    }
    New-Item -ItemType Directory -Force $root | Out-Null
    if (-not $LogPath) { $LogPath = Join-Path $root ("assignments-log_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host ("MIGRATION AFFECTATIONS (app-only) - Phase {0} - {1}" -f $Phase, $(if($Execute){'EXECUTE'}else{'PREVIEW'})) -ForegroundColor Green
    Write-Host ("Dossier : {0}" -f $root) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor DarkGray

    if ($Phase -in 'Export','All') { Invoke-ExportPhase -Root $root }
    if ($Phase -in 'Groups','All') { Invoke-GroupsPhase -Root $root }
    if ($Phase -in 'Assign','All') { Invoke-AssignPhase -Root $root }

    $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Ok ("Journal CSV : {0}" -f $LogPath)
    $script:Log | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Name, $_.Count) -ForegroundColor Gray }
}
catch {
    try { $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8 } catch {}
    Write-Bad $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    throw
}

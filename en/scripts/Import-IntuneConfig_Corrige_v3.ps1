#Requires -Version 7.0
<#
.SYNOPSIS
    Intune import engine CORRECTED (v3) — clone SOURCE -> TARGET.
    Fixes the confirmed bugs of v1.1/v1.2:
      - Settings Catalog: SINGLE POST with INLINE settings (never the two-step /{id}/settings).
      - Strict preservation of arrays (children:[], roleScopeTagIds): read with -AsHashtable,
        NO recursive tree reconstruction.
      - Compliance: removal of empty arrays + INJECTION of scheduledActionsForRule (action block).
      - Device Config with a secret (secretReferenceValueId): SKIP (manual processing).
      - Scripts/Remediations with empty content: SKIP (rehydrate first).
      - Idempotence by name (EXISTS -> SKIP), CSV log, PREVIEW by default.

    PREREQUISITES: PowerShell 7, Microsoft.Graph.Authentication module, Connect-MgGraph connection
    already established on the TARGET tenant (TEST) before the call (see the RUNBOOK).

    IMPORTANT: ALWAYS run in PREVIEW (without -Execute) first. Check the CSV, then -Execute.

.PARAMETER SourcePath
    Folder of the REHYDRATED export (FixedExport) containing 01_.. 13_.. .

.PARAMETER TargetTenantId
    GUID of the target tenant (TEST). Safeguard: refuses if the current context != this value.

.PARAMETER SourceTenantId
    GUID of the source tenant (PROD). Safeguard: refuses if target == source.

.PARAMETER Phase
    Foundation | Apps | Policies | Scripts | Mobile | All   (default All)

.PARAMETER Execute
    Real write. Absent = PREVIEW (no POST).

.PARAMETER IncludeScopeTags
    Keeps roleScopeTagIds (otherwise removed -> Graph applies the default ["0"]).

.PARAMETER LogPath
    CSV log file. Default: .\logs\import_v3_<timestamp>.csv

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
$script:SourceFileCount = 0        # P1-1: independent count of SOURCE files enumerated per processed folder (real completeness guard)
$script:SourceSeenCount = 0        # P1-1: count of SOURCE objects actually iterated (completeness invariant)
$script:ReconExitCode   = 0        # P1-1: 2 => security-critical NOT applied (set at the very end, -Execute only)
$script:RemapLog        = $null    # P1-1: per-object old->new id remap trail (reset in the file loop)
# 14_AdminTemplates (ADMX) — target catalog caches + per-object stash of the source definitionValues.
# definitionValues MUST be captured BEFORE Build-Payload strips them (Remove-TopKeys mutates $obj in place),
# so New-AdminTemplatePayload stashes them here for the post-create/PREVIEW dry-run to consume.
$script:AdmxDefCache    = $null    # dict: 'displayName|classType|categoryPath' (lower) -> TARGET groupPolicyDefinition id
$script:AdmxPresCache   = @{}      # dict: TARGET def id -> array of that definition's TARGET presentations
$script:AdminDefValues  = @()      # per-object stash of the SOURCE definitionValues (reset in the file loop)

function Invoke-GraphWithRetry {
    # P1-3: transient retry on throttling / server errors (429/503/504). A transient 429 must NOT
    # surface as an ERROR/Failed. HTTP-code detection is defensive (Invoke-MgGraphRequest raises
    # different exception shapes across module versions) with a message-based fallback.
    param([Parameter(Mandatory)][scriptblock]$Call,[int]$MaxAttempts=5)
    for ($i=1;;$i++) {
        try { return & $Call }
        catch {
            $ex = $_.Exception
            $code = 0
            # a) classic HttpResponseMessage.StatusCode
            try { if ($ex.Response -and $ex.Response.StatusCode) { $code = [int]$ex.Response.StatusCode } } catch {}
            # b) some versions expose StatusCode directly on the exception
            if ($code -eq 0) { try { if ($ex.StatusCode) { $code = [int]$ex.StatusCode } } catch {} }
            # c) fallback: sniff the code / label out of the message
            if ($code -eq 0) {
                $msg = [string]$ex.Message
                if     ($msg -match '(?i)\b429\b|too\s*many\s*requests|throttl') { $code = 429 }
                elseif ($msg -match '(?i)\b503\b|service\s*unavailable')         { $code = 503 }
                elseif ($msg -match '(?i)\b504\b|gateway\s*time-?out')           { $code = 504 }
            }
            if (($code -in 429,503,504) -and ($i -lt $MaxAttempts)) {
                $ra = 0
                try { if ($ex.Response.Headers.RetryAfter.Delta) { $ra = [int]$ex.Response.Headers.RetryAfter.Delta.TotalSeconds } } catch {}
                if ($ra -le 0) { $ra = [int][Math]::Min([Math]::Pow(2,$i),60) }   # capped exponential backoff
                Start-Sleep -Seconds ([int]$ra + (Get-Random -Minimum 0 -Maximum 2))
                continue
            }
            throw
        }
    }
}

# SourceId -> TargetId app map (to remap targetedMobileApps in AppConfigurations).
$script:AppIdMap = @{}
if ($AppIdMapPath -and (Test-Path -LiteralPath $AppIdMapPath)) {
    try { Import-Csv -LiteralPath $AppIdMapPath | ForEach-Object { if ($_.SourceId) { $script:AppIdMap[[string]$_.SourceId] = [string]$_.TargetId } } }
    catch { Write-Host ("  [!] AppIdMap unreadable ({0}) : {1}" -f $AppIdMapPath,$_.Exception.Message) -ForegroundColor Yellow }
}

# --- Conditional Access reference remap (P0-5): flat SOURCE-GUID -> TARGET-GUID map for TENANT-SCOPED
#     CA references (groups, users, named-locations, custom enterprise apps, terms-of-use). Loaded from
#     an optional CSV (columns SourceId,TargetId). FAIL-CLOSED: any tenant-scoped reference absent from
#     this map (or with no map at all) is treated as UNRESOLVED and the CA policy is REFUSED (never
#     emitted with a source GUID). Inter-tenant CONSTANTS (role templates, well-known Microsoft apps,
#     special tokens) pass through unchanged and are NEVER looked up here.
$script:CaIdMap = @{}
if ($CaIdMapPath -and (Test-Path -LiteralPath $CaIdMapPath)) {
    try { Import-Csv -LiteralPath $CaIdMapPath | ForEach-Object { if ($_.SourceId) { $script:CaIdMap[[string]$_.SourceId] = [string]$_.TargetId } } }
    catch { Write-Host ("  [!] CaIdMap unreadable ({0}) : {1}" -f $CaIdMapPath,$_.Exception.Message) -ForegroundColor Yellow }
}
# Inter-tenant CONSTANTS that must pass through a CA policy unchanged (NOT tenant-scoped GUIDs).
$script:CaSpecialUsers     = @('All','None','GuestsOrExternalUsers')
$script:CaSpecialLocations = @('All','AllTrusted')
# Well-known first-party Microsoft appIds are GLOBAL (identical in every tenant) -> pass unchanged.
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
# Built-in authentication strength policy ids are GLOBAL constants (identical in every tenant) -> pass unchanged.
$script:CaBuiltInAuthStrength = @(
    '00000000-0000-0000-0000-000000000002', # Multifactor authentication
    '00000000-0000-0000-0000-000000000003', # Passwordless MFA
    '00000000-0000-0000-0000-000000000004'  # Phishing-resistant MFA
)

# App types NOT clonable by metadata alone (binary content / license) -> manual.
$AppTypesManual = @(
    '#microsoft.graph.win32LobApp','#microsoft.graph.win32CatalogApp','#microsoft.graph.iosLobApp',
    '#microsoft.graph.androidLobApp','#microsoft.graph.windowsMobileMSI','#microsoft.graph.windowsAppX',
    '#microsoft.graph.windowsUniversalAppX','#microsoft.graph.macOSLobApp','#microsoft.graph.macOSPkgApp',
    '#microsoft.graph.macOSDmgApp','#microsoft.graph.iosVppApp','#microsoft.graph.macOsVppApp',
    '#microsoft.graph.androidManagedStoreApp'
)

# Catalog: folder -> endpoint, name property, phase, fields to remove on create.
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

# FAIL-CLOSED guard-rail (design: Endpoint Security). 15_EndpointSecurity must NEVER be wired into $Catalog:
# deviceManagement/intents (and the legacy templates API) were FROZEN by Microsoft (~03/2025). Modern Endpoint
# Security is a configurationPolicy already handled by family 02; residual legacy intents are recreated
# manually / via AI-assist, never by an intents importer. If someone rebrands one here, refuse to run.
if (@($Catalog | Where-Object { $_.Folder -eq '15_EndpointSecurity' }).Count -gt 0) {
    throw "SAFEGUARD: 15_EndpointSecurity must not be in `$Catalog (deviceManagement/intents is frozen; modern ES = family 02, legacy intents = manual/AI-assist)."
}

# OutOfScope reason overrides: for folders present in the export but deliberately absent from $Catalog, give a
# SPECIFIC honest reason instead of the generic 'no endpoint mapping'. 15_EndpointSecurity is the notable case.
$script:OutOfScopeReasons = @{
    '15_EndpointSecurity' = 'Endpoint Security legacy intents: deviceManagement/intents API frozen by Microsoft (~03/2025). Modern ES is recreated via family 02 (configurationPolicies); legacy intents = manual / AI-assist runbook. Not recreatable by API.'
}

function Add-Result {
    # P1-1 enriched record. Historical columns (Timestamp/Family/Name/Status/Reason/GraphId/Error) are
    # kept VERBATIM for CSV backward-compat; the new columns describe RESULTS (backend-neutral):
    #   SourceName  = non-prefixed source name,  AppliedName = name actually pushed (prefixed),
    #   IdentityKey = logical key on the non-prefixed source name,  TargetId = the target id (== GraphId),
    #   Remap       = array of {kind,oldId,newId} (default @()).
    param($Family,$Name,$Status,$Reason,$GraphId,$Err,$SourceName,$AppliedName,$IdentityKey,$Remap=@())
    if (-not $SourceName)  { $SourceName  = $Name }
    if (-not $AppliedName) { $AppliedName = $Name }
    # Normalize Remap to an object[] WITHOUT the @() operator: @() on a List[object] throws
    # "Argument types do not match" on PowerShell 7.5 / .NET 9 (RemapLog is a List).
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
    if ($TargetTenantId -eq $SourceTenantId) { throw "SAFEGUARD: target == source ($TargetTenantId). Refused." }
    $ctx = Get-MgContext
    if (-not $ctx) { throw "No Graph connection. Run Connect-MgGraph -TenantId $TargetTenantId ... first." }
    if ($ctx.TenantId -ne $TargetTenantId) { throw "SAFEGUARD: current context $($ctx.TenantId) != target $TargetTenantId." }
    Write-Host ("  [OK] Target context confirmed: {0} ({1})" -f $ctx.TenantId,$ctx.Account) -ForegroundColor Green
}

function Read-JsonFile { param($Path) (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -AsHashtable -Depth 100 }

function Get-IdempotencyKey {
    # Idempotence key: name (+ type/platform discriminator when $Cat.Key is defined). Avoids false
    # EXISTS / duplicates on same-name objects of different types (e.g. iosVppApp vs androidManagedStoreApp,
    # iOS vs iOSMobileApplicationManagement filters). ".$prop" access works for SOURCE (hashtable) and
    # TARGET (Graph object). $NameOverride lets the caller pass the already-prefixed name.
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
    # Stream the elements (defence in depth). The sole caller pipes "| ForEach-Object", so ",$all"
    # worked, but "return $all" removes any collapse risk if that call site ever changes.
    return $all
}

function Build-TargetAppIdMap {
    # P1-4: in a single -Phase All run the AppIdMap is not supplied at the moment the AppConfigurations
    # are imported. Build it HERE, AFTER the Apps wave and BEFORE the AppConfigurations, by querying the
    # TARGET tenant (apps already created) and matching by displayName + @odata.type (name-only fallback)
    # -- same logic as Build-IntuneAppIdMap.ps1. Feeds $script:AppIdMap (SourceId -> TargetId). Never
    # overwrites entries already loaded from -AppIdMapPath.
    $appsFolder = Join-Path $SourcePath '09_Apps'
    if (-not (Test-Path -LiteralPath $appsFolder)) { return }
    $srcFiles = @(Get-ChildItem -LiteralPath $appsFolder -Filter *.json -File -ErrorAction SilentlyContinue)
    if ($srcFiles.Count -eq 0) { return }
    try { $targetApps = @(Get-AllValues -Path 'deviceAppManagement/mobileApps') }
    catch { Write-Host ("  [!] AppIdMap auto: cannot read target apps: {0}" -f $_.Exception.Message) -ForegroundColor Yellow; return }
    $added = 0
    foreach ($sf in $srcFiles) {
        try { $src = Read-JsonFile $sf.FullName } catch { continue }
        $sid = [string]$src.'id'; $sname = [string]$src.'displayName'; $stype = [string]$src.'@odata.type'
        if (-not $sid -or -not $sname) { continue }
        if ($script:AppIdMap.ContainsKey($sid)) { continue }   # never overwrite a -AppIdMapPath entry
        $match = $null
        $byNameType = @($targetApps | Where-Object { [string]$_.'displayName' -eq $sname -and [string]$_.'@odata.type' -eq $stype })
        if ($byNameType.Count -eq 1) { $match = $byNameType[0] }
        elseif ($byNameType.Count -eq 0) {
            $byName = @($targetApps | Where-Object { [string]$_.'displayName' -eq $sname })
            if ($byName.Count -eq 1) { $match = $byName[0] }
        }
        if ($match) { $script:AppIdMap[$sid] = [string]$match.'id'; $added++ }
    }
    Write-Host ("  [i] AppIdMap auto-built from target tenant: {0} match(es)." -f $added) -ForegroundColor DarkCyan
}

function Remove-TopKeys { param([hashtable]$H,[string[]]$Keys) foreach($k in $Keys){ if($H.ContainsKey($k)){ [void]$H.Remove($k) } } }

function Set-RoleScopeTagIds {
    param([hashtable]$H)
    if (-not $IncludeScopeTags) { if($H.ContainsKey('roleScopeTagIds')){ [void]$H.Remove('roleScopeTagIds') }; return }
    if ($H.ContainsKey('roleScopeTagIds')) { $H['roleScopeTagIds'] = [string[]]@($H['roleScopeTagIds']) }
}

# ---- Payload builders (NO recursive reconstruction: we do NOT descend into settingInstance) ----
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
    # templateReference: @odata.type with '#', keep verbatim
    if ($O['templateReference'] -is [hashtable]) {
        $O['templateReference']['@odata.type'] = '#microsoft.graph.deviceManagementConfigurationPolicyTemplateReference'
    }
    # Wrap each settings[i]: remove 'id' from the wrapper, inject @odata.type, settingInstance VERBATIM
    $wrapped = foreach ($s in @($O['settings'])) {
        [ordered]@{
            '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
            'settingInstance' = $s['settingInstance']
        }
    }
    $O['settings'] = @($wrapped)   # array even with 0/1 element (PS7 preserves)
    ,$O
}

function New-CompliancePayload {
    param([hashtable]$O,$Cat)
    Remove-TopKeys -H $O -Keys $Cat.Strip
    # 1st pass: strip roleScopeTagIds (PROD scope tags 1/3 absent from TEST)
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
                        gracePeriodHours         = 0     # <-- BUSINESS DECISION: adjust (e.g. 24-72) before PROD
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
    if (Test-HasEncryptedSecret -O $O) { throw 'SKIP_SECRET : profile with secretReferenceValueId -> manual processing (re-enter cleartext).' }
    New-GenericPayload -O $O -Cat $Cat
}

function New-ContentScriptPayload {
    param([hashtable]$O,$Cat,[string[]]$Fields)
    foreach ($f in $Fields) {
        $v = $O[$f]
        if ([string]::IsNullOrEmpty($v)) { throw "SKIP_EMPTY : $f empty -> rehydrate the content from PROD before import." }
    }
    New-GenericPayload -O $O -Cat $Cat
}

# ---- 16_Enrollment: skip-and-flag BEFORE any POST (fail-closed) -----------------------------------
function New-EnrollmentPayload {
    # deviceEnrollmentConfigurations: one endpoint, sub-type carried by @odata.type in the body. The export
    # lists defaults + targeted profiles unfiltered; classify here. Only TARGETED profiles are POSTed
    # (ESP/limit/singlePlatformRestriction/notifications). Tenant defaults & singletons are SKIPPED (a POST
    # would collide or break priority). priority is read-only on create -> stripped & logged, never reordered
    # (setPriority would also reshuffle profiles already present in the target). assignments -> deferred to
    # Invoke-IntuneAssignments (never post a source group GUID). @odata.type is KEPT so the server routes the sub-type.
    param([hashtable]$O,$Cat)
    $t   = [string]$O['@odata.type']
    $ect = [string]$O['deviceEnrollmentConfigurationType']
    $prio = $O['priority']
    # priority deserializes as Int64 via ConvertFrom-Json -AsHashtable: a literal '-is [int]' MISSES 0 and would
    # fail-OPEN on a tenant default. Guard null first (absent priority must NOT read as 0), then compare as Int64.
    $prioIsZero = $false
    if ($null -ne $prio) { try { $prioIsZero = ([int64]$prio -eq 0) } catch { $prioIsZero = $false } }
    $singletons = @(
      '#microsoft.graph.deviceEnrollmentWindowsHelloForBusinessConfiguration',
      '#microsoft.graph.deviceComanagementAuthorityConfiguration',
      '#microsoft.graph.windowsRestoreDeviceEnrollmentConfiguration')
    # 1) Tenant defaults / singletons: NEVER duplicate.
    if ($ect -like 'default*' -or $prioIsZero -or ($singletons -contains $t)) {
        throw "SKIP_DEFAULT_SINGLETON : enrollment default/singleton ($ect/$t) -- target collision or breaks priority."
    }
    # 2) Legacy combined multi-platform restriction: manual review (recreate/convert to singlePlatformRestriction).
    if ($t -eq '#microsoft.graph.deviceEnrollmentPlatformRestrictionsConfiguration') {
        throw "SKIP_FLAG_REVIEW : legacy combined platformRestrictions -- recreate/convert to singlePlatformRestriction."
    }
    return (New-GenericPayload -O $O -Cat $Cat)   # strips priority/id/... -> never a source GUID; @odata.type kept
}

# ---- 14_AdminTemplates (ADMX): create the shell, then remap-or-skip each definitionValue -----------
function Get-AdmxDefinitionCache {
    # Load the TARGET groupPolicyDefinitions ONCE and index by 'displayName|classType|categoryPath' (lower).
    # Definition ids DIFFER between tenants even for the same ADMX -> we resolve by attributes, never by source GUID.
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
    # TARGET presentations of one definition (cached). Used to remap presentation@odata.bind by label + @odata.type.
    param([string]$DefId)
    if ($script:AdmxPresCache.ContainsKey($DefId)) { return $script:AdmxPresCache[$DefId] }
    $pres = @(Get-AllValues -Path ("deviceManagement/groupPolicyDefinitions('{0}')/presentations" -f $DefId))
    $script:AdmxPresCache[$DefId] = $pres
    return $pres
}

function Resolve-AdmxDefinitionValue {
    # Build the remapped POST body for ONE source definitionValue, or THROW SKIP_UNRESOLVED_DEF (fail-closed).
    # Never emit a source-tenant definition/presentation id: the definition is resolved by attributes and every
    # presentation@odata.bind is nested under the resolved TARGET definition. A single unresolved presentation
    # SKIPS the whole definitionValue (a partial value 400s / corrupts the policy).
    param([hashtable]$Dv)
    $def = $Dv['definition']
    if (-not ($def -is [hashtable])) { throw "SKIP_UNRESOLVED_DEF : definitionValue without an embedded definition (rehydrate the export)." }
    $dName = [string]$def['displayName']; $dClass = [string]$def['classType']; $dCat = [string]$def['categoryPath']
    $dkey = ('{0}|{1}|{2}' -f $dName,$dClass,$dCat).ToLowerInvariant()
    $cache = Get-AdmxDefinitionCache
    $tgtDefId = $null
    if ($cache.ContainsKey($dkey)) { $tgtDefId = $cache[$dkey] }
    if ([string]::IsNullOrWhiteSpace($tgtDefId)) {
        throw "SKIP_UNRESOLVED_DEF : ADMX definition '$dName' (classType=$dClass, category=$dCat) not found in target catalog (custom/non-ingested ADMX)."
    }
    $body = [ordered]@{
        'enabled'               = [bool]$Dv['enabled']
        'definition@odata.bind' = "$GraphBase/deviceManagement/groupPolicyDefinitions('$tgtDefId')"
    }
    $srcPvs = @($Dv['presentationValues'])
    if ($srcPvs.Count -gt 0) {
        $tgtPres = @(Get-AdmxPresentations -DefId $tgtDefId)
        $typeCounter = @{}   # per-@odata.type consumption counter for the ordered fallback
        $pvOut = @()
        foreach ($pv in $srcPvs) {
            $srcPres  = $pv['presentation']
            $srcLabel = if ($srcPres -is [hashtable]) { [string]$srcPres['label'] } else { '' }
            $srcType  = if ($srcPres -is [hashtable]) { [string]$srcPres['@odata.type'] } else { '' }
            $idx = 0; if ($typeCounter.ContainsKey($srcType)) { $idx = [int]$typeCounter[$srcType] }
            $typeCounter[$srcType] = $idx + 1
            $tgtPresId = $null
            # primary: match on label + @odata.type
            $cand = @($tgtPres | Where-Object { [string]$_.label -eq $srcLabel -and [string]$_.'@odata.type' -eq $srcType })
            if ($cand.Count -ge 1) { $tgtPresId = [string]$cand[0].id }
            else {
                # fallback: same ORDER among target presentations of the same @odata.type
                $sameType = @($tgtPres | Where-Object { [string]$_.'@odata.type' -eq $srcType })
                if ($sameType.Count -eq 1) { $tgtPresId = [string]$sameType[0].id }   # unambiguous only; refuse to guess by order (wrong-presentation risk -> SKIP)
            }
            if ([string]::IsNullOrWhiteSpace($tgtPresId)) {
                throw "SKIP_UNRESOLVED_DEF : presentation '$srcLabel' ($srcType) unresolved for definition '$dName' -- whole definitionValue skipped."
            }
            # keep the presentationValue verbatim (@odata.type Decimal/Text/List/... + value/values), drop only
            # the source presentation/id/timestamps, then nest presentation@odata.bind under the TARGET definition.
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
    # Build the CONFIG SHELL only (POST /groupPolicyConfigurations = {displayName, description, roleScopeTagIds}).
    # definitionValues are Strip'd from the create body and POSTed AFTER creation (see the post-create block).
    # They are captured HERE first, because Remove-TopKeys (New-GenericPayload) mutates $O in place -> reading
    # $O['definitionValues'] after Build-Payload would return nothing.
    param([hashtable]$O,$Cat)
    $script:AdminDefValues = @($O['definitionValues'])
    return (New-GenericPayload -O $O -Cat $Cat)
}

# ---- Conditional Access remap-or-refuse (P0-5) ----------------------------------------------------
function Resolve-CaRefList {
    # Remap a list of CA references: pass CONSTANTS through unchanged, remap tenant-scoped GUIDs via the
    # CA id-map, THROW (fail-closed) on any unresolved tenant-scoped reference. Every emitted value (remapped
    # target OR passed-through constant) is recorded in $script:CaEmitted so the fail-closed backstop below
    # can tell a legitimate constant from a leaked source id. -AllConstant marks a whole class as inter-tenant
    # constant (e.g. include/excludeRoles = directory role TEMPLATE ids).
    param($List,[string[]]$Constants,[string]$Slot,[switch]$AllConstant)
    $out = @()
    foreach ($ref in @($List)) {
        $s = [string]$ref
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($AllConstant -or ($Constants -contains $s)) { $out += $s; [void]$script:CaEmitted.Add($s); continue }
        $t = $script:CaIdMap[$s]
        if ([string]::IsNullOrWhiteSpace($t)) {
            throw "SKIP_UNRESOLVED_CA_REF : $Slot reference '$s' has no target mapping (CaIdMap) -> CA policy refused (fail-closed)."
        }
        $out += $t; [void]$script:CaEmitted.Add([string]$t)
        if ($null -ne $script:RemapLog) { [void]$script:RemapLog.Add([pscustomobject]@{ kind=$Slot; oldId=$s; newId=[string]$t }) }  # P1-1 remap trail
    }
    return ,@($out)
}

function Resolve-CaReferences {
    # Remap EVERY tenant-scoped reference class of a CA policy IN PLACE; throw to refuse the whole policy
    # if any reference cannot be resolved. Role TEMPLATES, well-known Microsoft apps and built-in auth
    # strengths pass unchanged. A fail-closed BACKSTOP then scans the conditions/grantControls subtrees and
    # refuses the policy if ANY GUID we did not deliberately emit survives (unhandled/unmapped source ref) --
    # this catches slots we do not remap explicitly (external tenants, custom auth strength, device states...).
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
                # Directory role TEMPLATE ids are inter-tenant constants: pass unchanged (never route through an Intune map).
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
                # service principals are tenant-scoped: remap via CaIdMap or refuse (fail-closed).
                if ($capps.ContainsKey($slot)) { $capps[$slot] = Resolve-CaRefList -List $capps[$slot] -Constants @('ServicePrincipalsInMyTenant','None') -Slot "clientApplications.$slot" }
            }
        }
        $locs = $cond['locations']
        if ($locs -is [hashtable]) {
            foreach ($slot in 'includeLocations','excludeLocations') {
                # named-locations: no dedicated map => refs fall through to CaIdMap; absent => refused (fail-closed).
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
            # built-in auth strengths are global constants; a custom (tenant-scoped) id has no target map -> refused.
            $as['id'] = @(Resolve-CaRefList -List @($as['id']) -Constants $script:CaBuiltInAuthStrength -Slot 'grantControls.authenticationStrength.id')[0]
        }
    }
    # Fail-closed backstop: no source-tenant GUID may survive in the conditions/grantControls subtrees.
    # Everything we deliberately remapped or passed through is in $script:CaEmitted; a GUID left in an
    # unhandled/unmapped slot is refused rather than emitted. (Top-level id/templateId/dates are NOT scanned.)
    foreach ($sub in @($O['conditions'], $O['grantControls'])) {
        if ($null -eq $sub) { continue }
        $blob = ($sub | ConvertTo-Json -Depth 100 -Compress)
        foreach ($mm in ([regex]'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches($blob)) {
            $g = $mm.Value
            if ($script:CaEmitted.Contains($g)) { continue }
            if ($script:CaWellKnownAppIds -contains $g) { continue }
            throw "SKIP_UNRESOLVED_CA_REF : GUID '$g' in an unhandled/unmapped CA slot -> CA policy refused (fail-closed; never emit a source-tenant id)."
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
            if ($AppTypesManual -contains $t) { throw "SKIP_MANUAL : app type not clonable ($t)." }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'AppConfig' {
            # Remap targetedMobileApps (SOURCE app IDs -> target) via AppIdMap; SKIP_UNMAPPED if unmapped
            # (otherwise we would POST PROD app IDs that are invalid in the target tenant). The map comes
            # from -AppIdMapPath OR is auto-built from the target tenant (P1-4, single -Phase All run).
            if ($O.ContainsKey('targetedMobileApps') -and @($O['targetedMobileApps']).Count -gt 0) {   # P1-4: unconditional -> an unmapped app is SKIP_UNMAPPED, never a source GUID POSTed
                $mapped = @()
                foreach ($sid in @($O['targetedMobileApps'])) {
                    $tid = $script:AppIdMap[[string]$sid]
                    if ([string]::IsNullOrWhiteSpace($tid)) { throw "SKIP_UNMAPPED : source app $sid has no target equivalent in AppIdMap.csv -> config not imported." }
                    $mapped += $tid
                    if ($null -ne $script:RemapLog) { [void]$script:RemapLog.Add([pscustomobject]@{ kind='targetedMobileApps'; oldId=[string]$sid; newId=$tid }) }  # P1-1 remap trail
                }
                $O['targetedMobileApps'] = @($mapped)
            }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'RoleDefinition' {
            if ($O['isBuiltIn'] -or $O['isBuiltInRoleDefinition']) { throw 'SKIP_BUILTIN : built-in role definition (not creatable).' }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'ConditionalAccess' {
            # P0-5 : remap-or-refuse. Create DISABLED, and NEVER emit a source-tenant GUID in ANY slot.
            $O['state'] = 'disabled'
            Resolve-CaReferences -O $O
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'Enrollment'    { return (New-EnrollmentPayload    -O $O -Cat $Cat) }
        'AdminTemplate' { return (New-AdminTemplatePayload -O $O -Cat $Cat) }
        default { return (New-GenericPayload -O $O -Cat $Cat) }
    }
}

# ---- P1-1 Reconciliation report (the durable differentiator; describes RESULTS, not transport) -----
function ConvertTo-HtmlText { param([string]$s) if ($null -eq $s) { return '' } ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }

function Get-CanonicalOutcome {
    # Map a raw engine Status to a canonical, backend-neutral OUTCOME.
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
    # Emit reconcile.json / reconcile.html / reconcile.csv next to the CSV log ($LogPath). Result-centric,
    # backend-neutral. Enforces the completeness invariant and raises the SECURITY-CRITICAL banner + exit 2.
    $reconDir = Split-Path -Parent $LogPath
    if (-not $reconDir) { $reconDir = (Get-Location).Path }
    if (-not (Test-Path $reconDir)) { New-Item -ItemType Directory -Force -Path $reconDir | Out-Null }
    $jsonPath = Join-Path $reconDir 'reconcile.json'
    $htmlPath = Join-Path $reconDir 'reconcile.html'
    $csvPath  = Join-Path $reconDir 'reconcile.csv'

    # 1) Canonical records from the engine results (exclude '/msg' + '/defval' transport sub-records: these are
    #    per-message / per-ADMX-value details of a parent object, not top-level source objects for the invariant).
    $canon = @(foreach ($r in @($script:Results | Where-Object { $_.Family -notlike '*/msg' -and $_.Family -notlike '*/defval' })) {
        [pscustomobject]@{
            family=$r.Family; sourceName=$r.SourceName; appliedName=$r.AppliedName
            identityKey=$r.IdentityKey; outcome=(Get-CanonicalOutcome $r.Status); reason=$r.Reason
            targetId=$r.TargetId; remap=@($r.Remap); timestamp=$r.Timestamp; status=$r.Status
        }
    })

    # 2) OutOfScope: folders PRESENT in the export but ABSENT from $Catalog (no endpoint mapping).
    $catalogFolders = @($Catalog | ForEach-Object { $_.Folder })
    $outRecords = @()
    if (Test-Path -LiteralPath $SourcePath) {
        foreach ($d in @(Get-ChildItem -LiteralPath $SourcePath -Directory -ErrorAction SilentlyContinue)) {
            if ($catalogFolders -contains $d.Name) { continue }
            foreach ($jf in @(Get-ChildItem -LiteralPath $d.FullName -Filter *.json -File -ErrorAction SilentlyContinue)) {
                $sn = $jf.BaseName
                try { $o = Read-JsonFile $jf.FullName; if ($o['displayName']) { $sn=[string]$o['displayName'] } elseif ($o['name']) { $sn=[string]$o['name'] } } catch {}
                $oosReason = $script:OutOfScopeReasons[$d.Name]
                if ([string]::IsNullOrWhiteSpace($oosReason)) { $oosReason = 'Folder present in export but absent from import Catalog (no endpoint mapping)' }
                $outRecords += [pscustomobject]@{
                    family=$d.Name; sourceName=$sn; appliedName=$sn; identityKey=''
                    outcome='OutOfScope'; reason=$oosReason
                    targetId=''; remap=@(); timestamp=(Get-Date).ToString('o'); status='OUTOFSCOPE'
                }
            }
        }
    }
    $allCanon = @($canon) + @($outRecords)

    # 3) Completeness invariant: every SOURCE object seen == exactly one outcome (OutOfScope included).
    $seen = $script:SourceFileCount + @($outRecords).Count
    $invariantOK = (@($allCanon).Count -eq $seen)

    # 4) Summary counts per canonical outcome.
    $summary = [ordered]@{}
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) { $summary[$o] = 0 }
    foreach ($grp in ($allCanon | Group-Object outcome)) { $summary[$grp.Name] = $grp.Count }

    # 5) SECURITY-CRITICAL: Special = Compliance|ConditionalAccess, or a security baseline (name *aseline*).
    $specialByFolder = @{}
    foreach ($c in $Catalog) { if ($c.Special) { $specialByFolder[$c.Folder] = $c.Special } }
    $criticalNotApplied = @(foreach ($r in $allCanon) {
        $sp = $specialByFolder[$r.family]
        $isCrit = ($sp -eq 'Compliance' -or $sp -eq 'ConditionalAccess' `
            -or $r.family -match '(?i)EndpointSecurity|Baseline' `
            -or $r.status -eq 'SKIP_FLAG_REVIEW' `
            -or $r.sourceName -like '*aseline*' -or $r.appliedName -like '*aseline*')
        if (-not $isCrit) { continue }
        # OutOfScope counts too: a security-critical object silently dropped (not in $Catalog) must NOT read as "all clear".
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

    # ---- reconcile.csv (canonical columns) ----
    $allCanon | Select-Object family,sourceName,appliedName,identityKey,outcome,reason,targetId |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    # ---- reconcile.html ----
    $colorOf = @{ Matched='#2e7d32'; Created='#1565c0'; Failed='#c62828'; Skipped='#ef6c00'; Preview='#616161'; OutOfScope='#6a1b9a' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Intune Reconciliation</title>')
    [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{margin:0 0 4px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:8px 0 24px}th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;text-align:left;vertical-align:top}')
    [void]$sb.AppendLine('th{background:#f5f5f5}.pill{color:#fff;border-radius:10px;padding:2px 8px;font-size:12px;white-space:nowrap}')
    [void]$sb.AppendLine('.crit{background:#c62828;color:#fff;padding:12px 16px;border-radius:6px;margin:12px 0}.ok{background:#2e7d32;color:#fff;padding:12px 16px;border-radius:6px;margin:12px 0}')
    [void]$sb.AppendLine('.meta{color:#555;font-size:13px}code{background:#f0f0f0;padding:1px 4px;border-radius:3px}</style></head><body>')
    [void]$sb.AppendLine(("<h1>Intune Reconciliation Report</h1><div class='meta'>backend=graph-beta &middot; phase={0} &middot; target={1} &middot; generated {2}</div>" -f (ConvertTo-HtmlText $Phase),(ConvertTo-HtmlText $TargetTenantId),(ConvertTo-HtmlText ((Get-Date).ToString('o')))))
    # Header section: SECURITY-CRITICAL NOT APPLIED
    if ($criticalNotApplied.Count -gt 0) {
        [void]$sb.AppendLine(("<div class='crit'><b>&#9888; SECURITY-CRITICAL NOT APPLIED ({0})</b><br>Critical security objects (Compliance / Conditional Access / baselines) that were NOT applied.</div>" -f $criticalNotApplied.Count))
        [void]$sb.AppendLine('<table><tr><th>Family</th><th>Source</th><th>Applied</th><th>Outcome</th><th>Reason</th></tr>')
        foreach ($r in $criticalNotApplied) {
            [void]$sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><span class='pill' style='background:{3}'>{4}</span></td><td>{5}</td></tr>" -f (ConvertTo-HtmlText $r.family),(ConvertTo-HtmlText $r.sourceName),(ConvertTo-HtmlText $r.appliedName),($colorOf[$r.outcome]),(ConvertTo-HtmlText $r.outcome),(ConvertTo-HtmlText $r.reason)))
        }
        [void]$sb.AppendLine('</table>')
    } else {
        [void]$sb.AppendLine("<div class='ok'>&#10003; SECURITY-CRITICAL NOT APPLIED: none. No critical security object left unapplied.</div>")
    }
    # Summary + invariant
    [void]$sb.Append("<div class='meta'>Summary: ")
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) {
        [void]$sb.Append(("<span class='pill' style='background:{0}'>{1}: {2}</span> " -f ($colorOf[$o]),$o,$summary[$o]))
    }
    [void]$sb.AppendLine(("</div><div class='meta'>Completeness invariant: {0} outcome(s) == {1} source object(s) seen -&gt; {2}</div>" -f @($allCanon).Count,$seen,($(if($invariantOK){'OK'}else{'FAIL'}))))
    # Per-family tables
    foreach ($grp in ($allCanon | Group-Object family | Sort-Object Name)) {
        [void]$sb.AppendLine(("<h3>{0} ({1})</h3>" -f (ConvertTo-HtmlText $grp.Name),$grp.Count))
        [void]$sb.AppendLine('<table><tr><th>Outcome</th><th>Source name</th><th>Applied name</th><th>IdentityKey</th><th>Target id</th><th>Reason</th></tr>')
        foreach ($r in $grp.Group) {
            [void]$sb.AppendLine(("<tr><td><span class='pill' style='background:{0}'>{1}</span></td><td>{2}</td><td>{3}</td><td><code>{4}</code></td><td><code>{5}</code></td><td>{6}</td></tr>" -f ($colorOf[$r.outcome]),(ConvertTo-HtmlText $r.outcome),(ConvertTo-HtmlText $r.sourceName),(ConvertTo-HtmlText $r.appliedName),(ConvertTo-HtmlText $r.identityKey),(ConvertTo-HtmlText $r.targetId),(ConvertTo-HtmlText $r.reason)))
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine('</body></html>')
    Set-Content -LiteralPath $htmlPath -Value $sb.ToString() -Encoding UTF8

    # ---- console + exit code ----
    Write-Host ""
    Write-Host "=== Reconciliation ===" -ForegroundColor Magenta
    foreach ($o in @('Matched','Created','Failed','Skipped','Preview','OutOfScope')) { Write-Host ("  {0,-11}: {1}" -f $o,$summary[$o]) }
    Write-Host ("  Completeness : {0} outcomes == {1} seen -> {2}" -f @($allCanon).Count,$seen,($(if($invariantOK){'OK'}else{'FAIL'}))) -ForegroundColor ($(if($invariantOK){'Green'}else{'Red'}))
    Write-Host ("  reconcile.json : {0}" -f $jsonPath) -ForegroundColor Cyan
    Write-Host ("  reconcile.html : {0}" -f $htmlPath) -ForegroundColor Cyan
    Write-Host ("  reconcile.csv  : {0}" -f $csvPath)  -ForegroundColor Cyan

    if ($criticalNotApplied.Count -gt 0 -and $Execute) {
        Write-Host ""
        Write-Host "################################################################" -ForegroundColor Red
        Write-Host "#  SECURITY-CRITICAL NOT APPLIED  --  MANUAL ACTION REQUIRED    #" -ForegroundColor Red
        Write-Host "################################################################" -ForegroundColor Red
        foreach ($r in $criticalNotApplied) { Write-Host ("  [!] {0} | {1} -> {2} ({3})" -f $r.family,$r.sourceName,$r.outcome,$r.reason) -ForegroundColor Red }
        $script:ReconExitCode = 2
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Intune Import CORRECTED v3 ===  Phase=$Phase  Execute=$($Execute.IsPresent)" -ForegroundColor Magenta
if (-not $Execute) { Write-Host "PREVIEW MODE : no write. Add -Execute to import." -ForegroundColor Yellow }
Assert-Target

$selected = if ($Phase -eq 'All') { $Catalog } else { $Catalog | Where-Object { $_.Phase -eq $Phase } }

foreach ($cat in $selected) {
    $folder = Join-Path $SourcePath $cat.Folder
    if (-not (Test-Path $folder)) { continue }
    $files = @(Get-ChildItem $folder -Filter *.json -File)
    if ($files.Count -eq 0) { continue }
    $script:SourceFileCount += $files.Count   # P1-1: enumerated independently of Add-Result -> a dropped file makes the invariant FAIL

    Write-Host ""
    Write-Host ("--- {0} ({1} file(s)) ---" -f $cat.Folder,$files.Count) -ForegroundColor Cyan

    # P1-4: right before the AppConfigurations, if no AppIdMap was supplied/loaded, build it from the
    # TARGET tenant (apps created during the Apps wave of this same run) so configs whose target app
    # exists import instead of a blanket SKIP_UNMAPPED.
    if ($cat.Special -eq 'AppConfig' -and $script:AppIdMap.Count -eq 0) { Build-TargetAppIdMap }

    # Idempotence: existing key (name + type/platform discriminator) -> TARGET id in the target tenant.
    # P1-1: Dictionary key->targetId (was a HashSet) so a MATCHED source can PROVE the pre-existing target it maps to.
    $existingKeys = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    try {
        foreach ($e in @(Get-AllValues -Path $cat.Path)) {
            $k = Get-IdempotencyKey -Obj $e -Cat $cat
            if ($k) { $existingKeys[$k] = [string]$e.id }   # store the target object id (last wins on dup key)
        }
    } catch { Write-Host ("  [!] Cannot read existing items ({0}) : {1}" -f $cat.Path,$_.Exception.Message) -ForegroundColor Yellow }

    # P1-1: source IdentityKeys already produced in THIS run (per family) -> hard-fail duplicate source files.
    $seenIdentity = @{}

    foreach ($f in $files) {
        $script:RemapLog = New-Object System.Collections.Generic.List[object]   # P1-1: remap trail for THIS object
        $script:AdminDefValues = @()                                            # ADMX: reset the per-object definitionValues stash
        $obj  = Read-JsonFile $f.FullName
        $script:SourceSeenCount++                                               # P1-1 completeness: one SOURCE object seen
        # SourceName = the NON-prefixed source name; AppliedName ($name) = the name actually pushed (prefixed).
        $sourceName = if ($obj[$cat.Name]) { [string]$obj[$cat.Name] } elseif ($obj['displayName']) { [string]$obj['displayName'] } else { [string]$obj['name'] }
        $name = $sourceName
        if ($NamePrefix) { $name = $NamePrefix + $name }
        # IdentityKey RECORDED = logical key on the NON-prefixed source name (backend-neutral, prefix-independent).
        $identityKey = Get-IdempotencyKey -Obj $obj -Cat $cat
        # $key = MATCH key against the target (prefixed inside a prefixed run) -- target matching is UNCHANGED.
        $key  = Get-IdempotencyKey -Obj $obj -Cat $cat -NameOverride $name

        # P1-1 collision: two DIFFERENT source files with the same logical IdentityKey -> hard-fail the second
        # (do NOT let it be silently absorbed as EXISTS). Checked BEFORE the EXISTS match on purpose.
        if ($identityKey -and $seenIdentity.ContainsKey($identityKey)) {
            $dupReason = "Duplicate IdentityKey '$identityKey' already produced by source '$($seenIdentity[$identityKey])' in this run"
            Add-Result $cat.Folder $name 'SKIP_DUP_KEY' $dupReason $null $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
            Write-Host ("  [!] SKIP_DUP_KEY {0} -- {1}" -f $name,$dupReason) -ForegroundColor Red
            continue
        }
        if ($identityKey) { $seenIdentity[$identityKey] = $f.Name }

        if ($existingKeys.ContainsKey($key)) {
            $tid = $existingKeys[$key]
            Add-Result $cat.Folder $name 'EXISTS' 'Same key (name+type) already present' $tid $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey
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
                     elseif ($cat.Special -eq 'ConditionalAccess') { 'DISABLED / manual-enable-required' }
                     elseif ($cat.Special -eq 'AdminTemplate') {
                        # ADMX dry-run: resolve each definitionValue against the TARGET catalog WITHOUT posting.
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
                # Distinct outcome: a CA created DISABLED with remapped refs is NEVER a completed clone (manual enable required).
                Add-Result $cat.Folder $name 'CREATED-DISABLED' 'Created-DISABLED / references-remapped / manual-enable-required' $created.id $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey -Remap $script:RemapLog
            } else {
                Add-Result $cat.Folder $name 'CREATED' '' $created.id $null -SourceName $sourceName -AppliedName $name -IdentityKey $identityKey -Remap $script:RemapLog
            }
            $existingKeys[$key] = [string]$created.id   # avoid a duplicate if 2 source files share the same key in one run
            Write-Host ("  [+] {0}" -f $name) -ForegroundColor Green

            # Notification templates: POST localized messages after creation
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

            # ADMX: after the shell is created, POST each definitionValue with TARGET-remapped @odata.bind.
            # Each value is independent (try/catch) so an unresolved one is SKIP'd without breaking the others;
            # the config shell already exists, so the tenant is never bricked -- only unmappable values are missing.
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

# Log
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$script:Results | Select-Object * -ExcludeProperty Remap | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== Summary ($Phase) ===" -ForegroundColor Magenta
$script:Results | Group-Object Status | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize
Write-Host ("CSV Log : {0}" -f $LogPath) -ForegroundColor Cyan

# P1-1: reconciliation report (reconcile.json/html/csv) + SECURITY-CRITICAL gate. exit 2 only in -Execute.
Write-Reconciliation
if ($script:ReconExitCode -ne 0) {
    exit $script:ReconExitCode   # standalone: non-zero exit. In the module build this line becomes 'return' (never exit the host).
}

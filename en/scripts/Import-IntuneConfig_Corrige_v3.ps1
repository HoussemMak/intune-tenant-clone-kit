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
    [string]$LogPath = (Join-Path (Get-Location) ("logs\import_v3_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')))
)

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://graph.microsoft.com/beta'
$script:Results = New-Object System.Collections.Generic.List[object]

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
    @{ Folder='07_Filters';               Path='deviceManagement/assignmentFilters';                 Name='displayName'; Phase='Foundation'; Strip=@('id','createdDateTime','lastModifiedDateTime','payloads','assignments','exportWarnings') }
    @{ Folder='08_ScopeTags';             Path='deviceManagement/roleScopeTags';                      Name='displayName'; Phase='Foundation'; Strip=@('id','isBuiltIn','exportWarnings') }
    @{ Folder='09_Apps';                  Path='deviceAppManagement/mobileApps';                      Name='displayName'; Phase='Apps';       Strip=@('id','createdDateTime','lastModifiedDateTime','uploadState','publishingState','isAssigned','dependentAppCount','supersedingAppCount','supersededAppCount','committedContentVersion','size','assignments','revokeLicenseActionResults','exportWarnings'); Special='App' }
    @{ Folder='01_DeviceConfigurations';  Path='deviceManagement/deviceConfigurations';               Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','version','supportsScopeTags','assignments','exportWarnings'); Special='DeviceConfig' }
    @{ Folder='02_ConfigurationPolicies'; Path='deviceManagement/configurationPolicies';              Name='name';        Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','settingCount','assignments','isAssigned','exportWarnings'); Special='SettingsCatalog' }
    @{ Folder='03_CompliancePolicies';    Path='deviceManagement/deviceCompliancePolicies';           Name='displayName'; Phase='Policies';   Strip=@('id','createdDateTime','lastModifiedDateTime','version','assignments','exportWarnings'); Special='Compliance' }
    @{ Folder='04_ScriptsPowerShell';     Path='deviceManagement/deviceManagementScripts';            Name='displayName'; Phase='Scripts';    Strip=@('id','createdDateTime','lastModifiedDateTime','assignments','exportWarnings'); Special='Script' }
    @{ Folder='06_Remediations';          Path='deviceManagement/deviceHealthScripts';                Name='displayName'; Phase='Scripts';    Strip=@('id','createdDateTime','lastModifiedDateTime','highestAvailableVersion','isGlobalScript','assignments','exportWarnings'); Special='Remediation' }
    @{ Folder='10_AppConfigurations';     Path='deviceAppManagement/mobileAppConfigurations';         Name='displayName'; Phase='Mobile';     Strip=@('id','createdDateTime','lastModifiedDateTime','version','assignments','exportWarnings') }
    @{ Folder='11_AppProtection';         Path='deviceAppManagement/managedAppPolicies';              Name='displayName'; Phase='Mobile';     Strip=@('id','createdDateTime','lastModifiedDateTime','version','deployedAppCount','assignments','exportWarnings') }
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
    if ($TargetTenantId -eq $SourceTenantId) { throw "SAFEGUARD: target == source ($TargetTenantId). Refused." }
    $ctx = Get-MgContext
    if (-not $ctx) { throw "No Graph connection. Run Connect-MgGraph -TenantId $TargetTenantId ... first." }
    if ($ctx.TenantId -ne $TargetTenantId) { throw "SAFEGUARD: current context $($ctx.TenantId) != target $TargetTenantId." }
    Write-Host ("  [OK] Target context confirmed: {0} ({1})" -f $ctx.TenantId,$ctx.Account) -ForegroundColor Green
}

function Read-JsonFile { param($Path) (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json -AsHashtable -Depth 100 }

function Get-AllValues {
    param($Path)
    $all=@(); $u="$GraphBase/$Path"
    do {
        $r = Invoke-MgGraphRequest -Method GET -Uri $u
        if ($r.value) { $all += @($r.value) }
        $u = $r.'@odata.nextLink'
    } while ($u)
    # Stream the elements (defence in depth). The sole caller pipes "| ForEach-Object", so ",$all"
    # worked, but "return $all" removes any collapse risk if that call site ever changes.
    return $all
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
        'RoleDefinition' {
            if ($O['isBuiltIn'] -or $O['isBuiltInRoleDefinition']) { throw 'SKIP_BUILTIN : built-in role definition (not creatable).' }
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        'ConditionalAccess' {
            $O['state'] = 'disabled'   # create disabled for safety; references are source-tenant IDs to remap
            return (New-GenericPayload -O $O -Cat $Cat)
        }
        default { return (New-GenericPayload -O $O -Cat $Cat) }
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

    Write-Host ""
    Write-Host ("--- {0} ({1} file(s)) ---" -f $cat.Folder,$files.Count) -ForegroundColor Cyan

    # Idempotence: existing names in the target
    $existing = @()
    try { $existing = @(Get-AllValues -Path $cat.Path | ForEach-Object { $_.$($cat.Name) } | Where-Object { $_ } | ForEach-Object { $_.ToString().ToLowerInvariant() }) }
    catch { Write-Host ("  [!] Cannot read existing items ({0}) : {1}" -f $cat.Path,$_.Exception.Message) -ForegroundColor Yellow }

    foreach ($f in $files) {
        $obj  = Read-JsonFile $f.FullName
        $name = if ($obj[$cat.Name]) { [string]$obj[$cat.Name] } elseif ($obj['displayName']) { [string]$obj['displayName'] } else { [string]$obj['name'] }
        if ($NamePrefix) { $name = $NamePrefix + $name }

        if ($existing -contains $name.ToLowerInvariant()) {
            Add-Result $cat.Folder $name 'EXISTS' 'Same name already present' $null $null
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
            $extra = if ($cat.Special -eq 'SettingsCatalog') { "settings=$((@($payload['settings'])).Count)" } else { '' }
            Add-Result $cat.Folder $name 'PREVIEW' $extra $null $null
            Write-Host ("  [.] PREVIEW {0} {1}" -f $name,$extra) -ForegroundColor Gray
            continue
        }

        try {
            $json = $payload | ConvertTo-Json -Depth 100
            $created = Invoke-MgGraphRequest -Method POST -Uri "$GraphBase/$($cat.Path)" -Body $json -ContentType 'application/json'
            Add-Result $cat.Folder $name 'CREATED' '' $created.id $null
            Write-Host ("  [+] {0}" -f $name) -ForegroundColor Green

            # Notification templates: POST localized messages after creation
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

# Log
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$script:Results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "=== Summary ($Phase) ===" -ForegroundColor Magenta
$script:Results | Group-Object Status | Sort-Object Count -Descending | Format-Table Name,Count -AutoSize
Write-Host ("CSV Log : {0}" -f $LogPath) -ForegroundColor Cyan

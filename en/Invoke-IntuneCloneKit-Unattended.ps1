#Requires -Version 7.0
<#
.SYNOPSIS
    ZERO-TOUCH orchestrator for the intune-tenant-clone-kit: Export -> (Cleanup) -> Import by waves
    -> Assignments -> Verification -> HTML report, WITHOUT ANY HUMAN INTERVENTION.

.DESCRIPTION
    Automatically chains, in a single command and with no prompt, the entire cycle described in
    EXECUTER.md :
      0. Prepares the Microsoft.Graph.Authentication module.
      1. App-only CERTIFICATE connection to the SOURCE tenant + FRESH rehydrated export.
      2. App-only CERTIFICATE connection to the TARGET tenant + backup of the collections.
      3. (Optional) Cleanup of a previous failed import (from a report).
      4. Full prevalidation (no writes).
      5. Import by waves: Foundation, Apps, (AppIdMap), Policies, Scripts, Mobile.
      6. (Optional) Assignments: Entra groups + assignments remapped by NAME.
      7. (Optional) Final verification SOURCE vs TARGET (counts per endpoint).
      8. HTML report + CSV summary + transcript.

    100% non-interactive: app-only certificate authentication (no popup), no Read-Host.
    Global PREVIEW available via -Preview (no writes anywhere).

    App-only credentials read, in order : parameters -> config.ps1 -> environment variables.

.PARAMETER SourceTenantId / TargetTenantId
    GUID of the SOURCE (read) and TARGET (write) tenants. Falls back to config.ps1.

.PARAMETER SourceClientId / SourceCertThumbprint / TargetClientId / TargetCertThumbprint
    App registration + certificate thumbprint per tenant (app-only). If a single multi-tenant app
    is used, provide -ClientId / -CertThumbprint (applied to both).

.PARAMETER ClientId / CertThumbprint
    App-only identity common to both tenants (fallback if per-tenant values are absent).

.PARAMETER SourcePath
    Already rehydrated export folder to import. If absent : a FRESH export is produced from the SOURCE.

.PARAMETER ImportReport
    (Optional) RAPPORT-IMPORT*.txt report from a previous import : triggers the prior cleanup.

.PARAMETER ImportStartUtc / ImportEndUtc
    Time window for the cleanup (safeguard against deleting preexisting objects).

.PARAMETER Preview
    Global simulation : no writes (export + preflight + previews only).

.PARAMETER AllowInteractive
    Allows falling back to interactive connection if no app-only identity is provided.
    TO BE AVOIDED in scheduled mode (breaks zero-touch).

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
# Paths & constants
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
# Display
# --------------------------------------------------------------------------
function Write-Banner { param([string]$T,[string]$C='Cyan')
    Write-Host ''; Write-Host ('=' * 92) -ForegroundColor DarkGray
    Write-Host $T -ForegroundColor $C; Write-Host ('=' * 92) -ForegroundColor DarkGray }
function Write-Info { param([string]$T) Write-Host ("[INFO] {0}" -f $T) -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host ("[OK]   {0}" -f $T) -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host ("[WARN] {0}" -f $T) -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host ("[ERR]  {0}" -f $T) -ForegroundColor Red }

$script:StepRows = New-Object System.Collections.Generic.List[object]
$script:ReconSnapshots = New-Object System.Collections.Generic.List[string]   # P1-2: per-wave reconcile.json snapshots (verification source of truth)
function Add-StepResult { param([string]$Step,[string]$Status,[string]$LogPath,[string]$Details)
    $script:StepRows.Add([pscustomobject]@{
        DateUtc=(Get-Date).ToUniversalTime().ToString('s')+'Z'; Step=$Step; Status=$Status; LogPath=$LogPath; Details=$Details }) | Out-Null }

function Ensure-Folder { param([string]$P) if (-not (Test-Path -LiteralPath $P)) { New-Item -ItemType Directory -Path $P -Force | Out-Null } }
function Get-NewestFile { param([string]$Dir,[string]$Filter)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    Get-ChildItem -Path $Dir -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

# --------------------------------------------------------------------------
# Config & app-only identities
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
    Write-Banner 'Step 0 - Module Microsoft.Graph.Authentication'
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Info 'Installing the module (CurrentUser).'
        try { if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null } } catch {}
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication -Force
    Get-ChildItem $ScriptsDir -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    Write-Ok 'Module ready; scripts unblocked.'
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
        Write-Warn2 ("No app-only identity for {0} : interactive fallback (NOT zero-touch)." -f $Label)
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
    } else {
        throw "No app-only identity (ClientId + CertThumbprint) for tenant $TenantId ($Label). Provide the parameters/config or -AllowInteractive."
    }
    $ctx = Get-MgContext
    if (-not $ctx -or -not $ctx.TenantId) { throw "Invalid Graph connection for $Label." }
    if ($ctx.TenantId.ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) {
        throw "Connection $Label on wrong tenant. Expected=$TenantId ; connected=$($ctx.TenantId)" }
    $org = $null; try { $org = (Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' }).value | Select-Object -First 1 } catch {}
    $acct = if ($ctx.Account) { $ctx.Account } else { 'app-only' }
    Write-Ok ("{0} : {1} (Tenant {2}, {3})" -f $Label, $org.displayName, $ctx.TenantId, $acct)
}

# --------------------------------------------------------------------------
# Graph resilience : 429/503/504 backoff + full pagination + identity helpers
# --------------------------------------------------------------------------
function Invoke-GraphWithRetry {
    # P1-3: replays a Graph call on transient throttling (429) or gateway errors (503/504). Honors Retry-After
    # when exposed, else exponential backoff capped at 60s + jitter. A transient 429 no longer yields Failed/ERROR.
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
                Write-Warn2 ("Graph throttling (HTTP {0}) : attempt {1}/{2}, waiting {3}s." -f $code,$i,$MaxAttempts,$ra)
                Start-Sleep -Seconds ([int]$ra + (Get-Random -Minimum 0 -Maximum 2))
                continue
            }
            throw
        }
    }
}

function Get-GraphAllPages {
    # P1-2: follow @odata.nextLink to return EVERY object (backup/verify must never truncate beyond 999).
    param([Parameter(Mandatory)][string]$Uri)
    $all = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-GraphWithRetry { Invoke-MgGraphRequest -Method GET -Uri $next }
        foreach ($it in @($resp.value)) { [void]$all.Add($it) }
        $next = $resp.'@odata.nextLink'
    }
    return $all.ToArray()   # unrolled on purpose: every caller re-collects with @(...)
}

function Get-VerifyName {
    # Human-readable identity of an Intune object (displayName, else name).
    param($Obj)
    foreach ($p in 'displayName','name') { $v = $Obj.$p; if ($v) { return [string]$v } }
    return '(unnamed)'
}
function Get-VerifyKey {
    # Normalized identity key used to cross-check SOURCE vs TARGET presence.
    param($Obj)
    foreach ($p in 'displayName','name') { $v = $Obj.$p; if ($v) { return ([string]$v).Trim().ToLowerInvariant() } }
    return $null
}
function Test-CriticalRecord {
    # Mirrors the engine heuristic: Compliance / Conditional Access / Endpoint Security / security baselines.
    param($Rec)
    $fam = [string]$Rec.family; $sn = [string]$Rec.sourceName; $an = [string]$Rec.appliedName
    return ($fam -match '(?i)Compliance|ConditionalAccess|EndpointSecurity|Baseline' -or $sn -like '*aseline*' -or $an -like '*aseline*')
}

# --------------------------------------------------------------------------
# Logs
# --------------------------------------------------------------------------
function Get-StatusSummaryText { param([string]$CsvPath)
    if ([string]::IsNullOrWhiteSpace($CsvPath) -or -not (Test-Path -LiteralPath $CsvPath)) { return 'Log missing' }
    try {
        $rows = @(Import-Csv -LiteralPath $CsvPath)
        if ($rows.Count -eq 0) { return '0 row' }
        if (-not ($rows[0].PSObject.Properties.Name -contains 'Status')) { return ("{0} row(s)" -f $rows.Count) }
        return (@($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name,$_.Count }) -join '; ')
    } catch { return ("Cannot read log: {0}" -f $_.Exception.Message) } }

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
# Business steps
# --------------------------------------------------------------------------
function Assert-GoodExport {
    # Guard: halt BEFORE any target write if the export is empty or carries the export-bug signature
    # (invalid URL / failed families). Prevents a misleadingly "successful" empty run.
    param([Parameter(Mandatory)][string]$Path)
    $manifestPath = Join-Path $Path 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Export guard: manifest.json missing in $Path. Import aborted." }
    $mf = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $total = 0
    foreach ($fam in @($mf.Families)) { if ($fam.PSObject.Properties.Name -contains 'Count') { $total += [int]$fam.Count } }
    $warnPath = Join-Path $Path 'export_warnings.txt'
    if (Test-Path -LiteralPath $warnPath) {
        $w = Get-Content -LiteralPath $warnPath -Raw
        if ($w -match 'The provided URL is not valid|list FAILED|item .* FAILED') {
            throw "Export guard: $warnPath contains Graph/URL errors (export-bug signature). Import aborted."
        }
    }
    if ($total -le 0) { throw "Export guard: 0 objects exported. Empty export, import aborted. See $Path\export_warnings.txt." }
    Write-Ok ("Export validated: {0} objects." -f $total)
}

function Invoke-Export {
    if ($SourcePath) {
        if (-not (Test-Path -LiteralPath (Join-Path $SourcePath 'manifest.json'))) { throw "SourcePath without manifest.json : $SourcePath" }
        $script:ActiveSource = $SourcePath
        Add-StepResult -Step 'Step 1 - Export' -Status 'SKIPPED' -LogPath '' -Details "Export skipped, source provided : $SourcePath"
        Write-Warn2 ("Export skipped. Import source = {0}" -f $SourcePath)
        return
    }
    $out = Join-Path $WorkDir ("input\Export_{0}" -f $RunStamp)
    Invoke-Step -Name 'Step 1 - FRESH export from SOURCE (read-only)' -Critical -LogPath '' -Action {
        Connect-Tenant -TenantId $SourceTenantId -Label 'SOURCE' -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All')
        & $Exporter -SourceTenantId $SourceTenantId -OutputPath $out
        Assert-GoodExport -Path $out
        $script:ActiveSource = $out
        if ($RecoverSecrets -and (Test-Path $RecoverSec)) { Write-Info 'Recovering OMA secrets from source...'; & $RecoverSec -ExportPath $out -SourceTenantId $SourceTenantId -AssumeYes }
    }
    Write-Info ("Import source : {0}" -f $script:ActiveSource)
}

function Invoke-Backup {
    if ($SkipBackup) { Write-Warn2 'Target backup skipped.'; return }
    Invoke-Step -Name 'Step 2 - Backup of TARGET collections' -LogPath '' -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET' -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All')
        Ensure-Folder $BackupDir
        foreach ($e in @('deviceManagement/deviceConfigurations','deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts','deviceManagement/roleScopeTags','deviceManagement/assignmentFilters','deviceAppManagement/mobileApps','deviceAppManagement/mobileAppConfigurations','deviceAppManagement/managedAppPolicies')) {
            try {
                $v = @(Get-GraphAllPages -Uri ("https://graph.microsoft.com/beta/{0}?`$top=999" -f $e))
                ($v | ConvertTo-Json -Depth 100) | Set-Content (Join-Path $BackupDir ("{0}.json" -f ($e -replace '/','_'))) -Encoding UTF8
            } catch { Write-Warn2 ("Backup {0} : {1}" -f $e, $_.Exception.Message) }
        }
        Write-Ok ("Backup written : {0}" -f $BackupDir)
    }
}

function Invoke-Cleanup {
    if ($SkipCleanup -or [string]::IsNullOrWhiteSpace($ImportReport)) { Write-Warn2 'Cleanup skipped (no report).'; return }
    if (-not (Test-Path -LiteralPath $ImportReport)) { Write-Warn2 ("Cleanup report not found : {0}" -f $ImportReport); return }
    $previewLog = Join-Path $LogsDir '01_cleanup_preview.csv'
    $execLog    = Join-Path $LogsDir '02_cleanup_execute.csv'
    $cleanArgs = @{ ReportPath=$ImportReport; TargetTenantId=$TargetTenantId }
    if ($PSBoundParameters.ContainsKey('ImportStartUtc')) { $cleanArgs['ImportStartUtc'] = $ImportStartUtc }
    if ($PSBoundParameters.ContainsKey('ImportEndUtc'))   { $cleanArgs['ImportEndUtc']   = $ImportEndUtc }

    Invoke-Step -Name 'Step 3A - Cleanup (preview)' -Critical -LogPath $previewLog -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET'
        & $Cleanup @cleanArgs -LogPath $previewLog }
    if ($Preview) { Write-Warn2 'Preview mode : real cleanup skipped.'; return }
    Invoke-Step -Name 'Step 3B - Cleanup (execution)' -Critical -LogPath $execLog -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET'
        & $Cleanup @cleanArgs -Execute -Force -LogPath $execLog }
}

function Invoke-Preflight {
    if ($SkipPreflight) { Write-Warn2 'Preflight skipped.'; return }
    $log = Join-Path $LogsDir '04_preflight_all.csv'
    $extra = @{}; if ($IncludeScopeTags) { $extra['IncludeScopeTags'] = $true }
    Invoke-Step -Name 'Step 4 - Full prevalidation (no writes)' -Critical -LogPath $log -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET'
        & $Engine -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase All -LogPath $log @extra }
}

function Invoke-Wave {
    param([string]$Phase,[string]$LogName)
    $log = Join-Path $LogsDir $LogName
    $recon = Join-Path $LogsDir 'reconcile.json'
    $extra = @{}; if ($IncludeScopeTags) { $extra['IncludeScopeTags'] = $true }
    if (-not $Preview) { $extra['Execute'] = $true }
    Remove-Item -LiteralPath $recon -Force -ErrorAction SilentlyContinue   # avoid snapshotting a stale (preflight/previous-wave) reconcile
    Invoke-Step -Name ("Step 5 - Import wave : {0}{1}" -f $Phase, $(if($Preview){' (PREVIEW)'}else{''})) -LogPath $log -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET'
        & $Engine -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase $Phase -AppIdMapPath (Join-Path $LogsDir 'AppIdMap.csv') -LogPath $log @extra }
    if (Test-Path -LiteralPath $recon) {   # P1-2: keep THIS wave's reconcile.json as verification source of truth
        $snap = Join-Path $LogsDir ("reconcile_{0}.json" -f $Phase)
        Copy-Item -LiteralPath $recon -Destination $snap -Force
        if (-not $script:ReconSnapshots.Contains($snap)) { $script:ReconSnapshots.Add($snap) | Out-Null }
    }
    $err = Get-StatusCount -CsvPath $log -Status 'ERROR'
    if ($err -gt 0 -and $StopOnImportErrors) { throw "Import $Phase : $err error(s) and -StopOnImportErrors active." }
}

function Invoke-AppIdMap {
    if ($SkipAppIdMap) { return }
    $csv = Join-Path $LogsDir 'AppIdMap.csv'
    Invoke-Step -Name 'Step 5C - Application mapping SourceId -> TargetId (audit)' -LogPath '' -Action {
        Connect-Tenant -TenantId $TargetTenantId -Label 'TARGET'
        & $AppMap -SourcePath $script:ActiveSource -TargetTenantId $TargetTenantId -OutputCsv $csv
        Write-Ok ("AppIdMap : {0}" -f $csv) }
}

function Invoke-Assignments {
    if ($SkipAssignments) { Write-Warn2 'Assignments skipped.'; return }
    Ensure-Folder $AssignRoot
    $log = Join-Path $LogsDir '10_assignments.csv'
    $extra = @{}
    if (-not $Preview) { $extra['Execute'] = $true }
    if ($StaticOnlyGroups) { $extra['StaticOnlyGroups'] = $true }
    Invoke-Step -Name ("Step 6 - Assignments (groups + assignments){0}" -f $(if($Preview){' (PREVIEW)'}else{''})) -LogPath $log -Action {
        & $Assign -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All -AssignmentsPath $AssignmentsDir -LogPath $log @extra }
}

function Invoke-Verification {
    if ($SkipVerification) { Write-Warn2 'Final verification skipped.'; return }
    $log = Join-Path $LogsDir '11_verification.csv'
    Invoke-Step -Name 'Step 7 - Final verification SOURCE vs TARGET (identity/outcome)' -LogPath $log -Action {
        $rows = @()
        # Preferred source of truth: per-wave reconcile.json snapshots (P1-1). Outcome-based, never naive counts
        # (a preexisting target object cannot mask a missing import; Failed/Skipped/OutOfScope are surfaced by NAME).
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
                # A CA created DISABLED (reason 'manual-enable-required') is NOT a completed clone -> count it as a gap, not applied.
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
            Write-Info ("Reconcile (import truth) : Matched={0} Created={1} Failed={2} Skipped={3} Preview={4} OutOfScope={5}" -f $agg.Matched,$agg.Created,$agg.Failed,$agg.Skipped,$agg.Preview,$agg.OutOfScope)
            if ($critLines.Count -gt 0) {
                Write-Bad ("SECURITY-CRITICAL not applied ({0}) :" -f $critLines.Count)
                foreach ($l in $critLines) { Write-Bad ("  [!] {0}" -f $l) }
            } elseif (($agg.Failed + $agg.Skipped + $agg.OutOfScope) -gt 0) {
                Write-Warn2 ("Gaps to review (Failed/Skipped/OutOfScope) : {0}" -f ($agg.Failed + $agg.Skipped + $agg.OutOfScope))
            }
        } else {
            # Fallback (no reconcile.json produced): cross-check SOURCE vs TARGET by IDENTITY key (name). A
            # preexisting target object cannot mask a missing import: every unmatched source key is named (ECART).
            function Read-EndpointObjects { param([string]$TenantId,[string]$Label)
                Connect-Tenant -TenantId $TenantId -Label $Label -Scopes @('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All')
                $h = @{}
                foreach ($e in $VerifyEndpoints) {
                    try { $h[$e] = @(Get-GraphAllPages -Uri ("https://graph.microsoft.com/beta/{0}?`$top=999" -f $e)) }
                    catch { $h[$e] = $null }
                }
                return $h
            }
            $srcMap = Read-EndpointObjects -TenantId $SourceTenantId -Label 'SOURCE (verify)'
            $tgtMap = Read-EndpointObjects -TenantId $TargetTenantId -Label 'TARGET (verify)'
            foreach ($e in $VerifyEndpoints) {
                $srcObjs = $srcMap[$e]; $tgtObjs = $tgtMap[$e]
                if ($null -eq $srcObjs -or $null -eq $tgtObjs) {
                    $rows += [pscustomobject]@{ Endpoint=$e; Source=$(if($null -eq $srcObjs){'ERR'}else{@($srcObjs).Count}); Cible=$(if($null -eq $tgtObjs){'ERR'}else{@($tgtObjs).Count}); Missing='read error'; Status='ERROR-READ' }
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
                if ($missing.Count -gt 0) { Write-Warn2 ("{0} : {1} source object(s) absent from target -> {2}" -f $e,$missing.Count,($missing -join '; ')) }
            }
        }
        $rows | Export-Csv -LiteralPath $log -NoTypeInformation -Encoding UTF8
        $rows | Format-Table -Auto | Out-Host
    }
}

# --------------------------------------------------------------------------
# HTML report
# --------------------------------------------------------------------------
function HtmlEnc { param([string]$T) if ($null -eq $T) { return '' } [System.Net.WebUtility]::HtmlEncode($T) }

function New-FinalReport {
    Write-Banner 'Final report'
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
    } else { '<tr><td colspan="4">No errors in the logs.</td></tr>' }

    $verifyHtml = ''
    $verifyLog = Join-Path $LogsDir '11_verification.csv'
    if (Test-Path -LiteralPath $verifyLog) {
        $verifyHtml = (@(Import-Csv -LiteralPath $verifyLog) | ForEach-Object {
            $st = [string]$_.Status
            $cls = if ($st -eq 'OK') { 'ok' } elseif ($st -like 'SKIP*') { 'skipped' } else { 'error' }
            '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td><span class="badge {4}">{5}</span></td></tr>' -f (HtmlEnc $_.Endpoint), (HtmlEnc $_.Source), (HtmlEnc $_.Cible), (HtmlEnc $_.Missing), $cls, (HtmlEnc $st) }) -join "`n"
    }
    $verifySection = if ($verifyHtml) {
        "<section class='card'><h2>Verification SOURCE vs TARGET (identity/outcome)</h2><table><thead><tr><th>Scope</th><th>Source</th><th>Target</th><th>Missing / gap</th><th>Status</th></tr></thead><tbody>$verifyHtml</tbody></table></section>"
    } else { '' }

    $mode = if ($Preview) { 'PREVIEW (no writes)' } else { 'EXECUTION' }
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Zero-touch execution report - intune-tenant-clone-kit</title>
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
<header><h1>Zero-touch execution - Intune clone SOURCE to TARGET</h1>
<div class="sub">Run $RunStamp - Mode $mode - Source $(HtmlEnc $SourceTenantId) -> Target $(HtmlEnc $TargetTenantId)</div></header>
<div class="wrap">
  <div class="grid">
    <div class="card"><div class="label">CREATED</div><div class="metric oktext">$nCreated</div></div>
    <div class="card"><div class="label">EXISTS</div><div class="metric">$nExists</div></div>
    <div class="card"><div class="label">APPLIED (assign.)</div><div class="metric oktext">$nApplied</div></div>
    <div class="card"><div class="label">SKIPPED / manual</div><div class="metric warn">$nSkipped</div></div>
    <div class="card"><div class="label">ERROR</div><div class="metric bad">$nErrors</div></div>
  </div>
  <section class="card"><h2>Executed steps</h2>
    <table><thead><tr><th>Step</th><th>Status</th><th>Details</th><th>Log</th></tr></thead><tbody>$stepHtml</tbody></table></section>
  <section class="card"><h2>Summary per log</h2>
    <table><thead><tr><th>Log</th><th>Status</th><th>Count</th></tr></thead><tbody>$statusHtml</tbody></table></section>
  $verifySection
  <section class="card"><h2>Errors to address</h2>
    <table><thead><tr><th>Log</th><th>Family</th><th>Object</th><th>Message</th></tr></thead><tbody>$errorHtml</tbody></table></section>
  <section class="card"><h2>Manual remainder (Intune limitations)</h2>
    <p class="note">Secret-bearing profiles (Wi-Fi/PSK, AppLocker/WDAC, encrypted OMA), LOB/Win32/VPP apps (binaries),
    Admin Templates, Endpoint Security (intents) and Enrollment are not clonable by metadata alone and
    must be recreated manually. PREVIEW=$nPreview simulated object(s).</p></section>
</div></body></html>
"@
    Set-Content -LiteralPath $FinalReport -Value $html -Encoding UTF8
    Write-Ok ("HTML report : {0}" -f $FinalReport)
    Write-Ok ("CSV summary : {0}" -f $SummaryCsv)
}

# --------------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------------
try {
    Ensure-Folder $WorkDir; Ensure-Folder $LogsDir; Ensure-Folder $OutputDir
    Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null

    # Config -> fills in parameters not provided
    $cfg = Import-KitConfig -Path $ConfigFile
    foreach ($k in $cfg.Keys) { if (-not $PSBoundParameters.ContainsKey($k) -and -not (Get-Variable $k -ValueOnly -EA SilentlyContinue)) { Set-Variable -Name $k -Value $cfg[$k] } }

    Write-Banner 'ZERO-TOUCH ORCHESTRATOR - intune-tenant-clone-kit' 'Green'
    Write-Info ("KitRoot : {0}" -f $KitRoot)
    Write-Info ("WorkDir : {0}" -f $WorkDir)
    Write-Info ("Mode    : {0}" -f $(if($Preview){'PREVIEW (no writes)'}else{'EXECUTION'}))

    if (-not $SourceTenantId) { throw 'SourceTenantId missing (parameter or config.ps1).' }
    if (-not $TargetTenantId) { throw 'TargetTenantId missing (parameter or config.ps1).' }
    if ($SourceTenantId -eq $TargetTenantId) { throw 'SOURCE and TARGET identical : refused.' }
    foreach ($p in @($Engine,$Exporter,$Cleanup,$AppMap,$Assign)) { if (-not (Test-Path -LiteralPath $p)) { throw "Required script not found : $p" } }

    $src = Get-AppCred -TenantId $SourceTenantId
    $tgt = Get-AppCred -TenantId $TargetTenantId
    if (-not $AllowInteractive) {
        if (-not ($src.ClientId -and $src.Thumb)) { throw "App-only SOURCE identity missing (SourceClientId/SourceCertThumbprint or ClientId/CertThumbprint)." }
        if (-not ($tgt.ClientId -and $tgt.Thumb)) { throw "App-only TARGET identity missing (TargetClientId/TargetCertThumbprint or ClientId/CertThumbprint)." }
    }

    Set-AppOnlyEnvironment
    Ensure-GraphModule

    # Auto-detect the cleanup report if not provided
    if (-not $SkipCleanup -and [string]::IsNullOrWhiteSpace($ImportReport)) {
        $auto = Get-NewestFile -Directory (Join-Path $KitRoot 'input') -Filter 'RAPPORT-IMPORT*.txt'
        if ($auto) { $ImportReport = $auto.FullName; Write-Info ("Cleanup report detected : {0}" -f $ImportReport) }
    }

    $script:ActiveSource = $null
    Invoke-Export
    Invoke-Backup
    Invoke-Cleanup
    Invoke-Preflight

    Invoke-Wave -Phase 'Foundation' -LogName '05_import_foundation.csv'
    if (-not $SkipApps) { Invoke-Wave -Phase 'Apps' -LogName '06_import_apps.csv' } else { Write-Warn2 'Apps import skipped.' }
    Invoke-AppIdMap
    Invoke-Wave -Phase 'Policies' -LogName '07_import_policies.csv'
    if (-not $SkipScripts) { Invoke-Wave -Phase 'Scripts' -LogName '08_import_scripts.csv' } else { Write-Warn2 'Scripts import skipped.' }
    if (-not $SkipMobile)  { Invoke-Wave -Phase 'Mobile'  -LogName '09_import_mobile.csv' }  else { Write-Warn2 'Mobile import skipped.' }

    Invoke-Assignments
    Invoke-Verification

    if ($UseAIAssist) {
        # AI step runs DRY-RUN by design: no -SendToProvider => ZERO external calls (it only writes
        # redacted metadata locally). External send stays an explicit, separate human decision.
        # Even if -RecoverSecrets rehydrated OMA secrets on disk under $script:ActiveSource, nothing
        # leaves the machine here because -SendToProvider is deliberately NOT passed.
        Invoke-Step -Name 'Step 8 - AI recreation assistant (optional)' -LogPath '' -Action {
            & $AIAssist -ExportPath $script:ActiveSource -OutputPath (Join-Path $OutputDir 'ai') -Language 'en'
        }
    }

    New-FinalReport
    Write-Banner 'Execution finished' 'Green'
    Write-Host ("Report  : {0}" -f $FinalReport) -ForegroundColor Green
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

> [🇫🇷 Version française](../fr/EXECUTER.md)

# EXECUTER — Full cycle Export → Fix → Import (SOURCE tenant → TARGET tenant)

PowerShell 7 (pwsh). Run the steps in order. Copy-paste each block.
At each connection, the display shows **the connected tenant and account** + the **expected** account: check before continuing.

> Prerequisite: have copied `config.example.ps1` to `config.ps1` and filled in your tenant GUIDs.

---

### Step 1 — Variables (paste once; edit `$Kit`)
```powershell
$Kit='C:\path\to\intune-tenant-clone-kit'         # <-- edit
. "$Kit\config.ps1"                               # loads $SourceTenantId,$TargetTenantId,$SourceDomain,$TargetDomain,$AppId
$Stamp=(Get-Date -f yyyy-MM-dd_HHmm)
$Src="$Kit\input\Export_$Stamp"; $Fixed=$Src; $Logs="$Kit\logs"; $Backup="$Kit\backup_$Stamp"
$Report="$Kit\input\import-report.txt"           # (optional) report of a previous failed import, for the cleanup step
$Pkg="$Kit\scripts"; $Engine="$Pkg\Import-IntuneConfig_Corrige_v3.ps1"; $Exporter="$Pkg\Export-IntuneConfig_FraisComplet_v1.ps1"
$Scopes    =@('DeviceManagementConfiguration.ReadWrite.All','DeviceManagementApps.ReadWrite.All','DeviceManagementServiceConfig.ReadWrite.All','DeviceManagementRBAC.ReadWrite.All')  # least-privilege write set (ManagedDevices dropped); add 'Policy.ReadWrite.ConditionalAccess' only if you clone Conditional Access
$ScopesRead=@('DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All','Policy.Read.All')

function Show-Tenant($expect){ $c=Get-MgContext; $o=$null; try{$o=(Invoke-MgGraphRequest GET 'https://graph.microsoft.com/v1.0/organization').value[0]}catch{}
  Write-Host ("--> CONNECTED TO : {0}   (TenantId {1})" -f $o.displayName,$c.TenantId) -ForegroundColor Cyan
  Write-Host ("    Account      : {0}" -f $c.Account) -ForegroundColor Cyan
  Write-Host ("    EXPECTED     : {0}" -f $expect) -ForegroundColor Yellow }
function Connect-Source { Disconnect-MgGraph -EA SilentlyContinue|Out-Null; $p=@{TenantId=$SourceTenantId;Scopes=$ScopesRead;NoWelcome=$true}; if($SourceAppId){$p.ClientId=$SourceAppId}; Connect-MgGraph @p; Show-Tenant "SOURCE — admin account @ $SourceDomain (read-only)" }
function Connect-Target { Disconnect-MgGraph -EA SilentlyContinue|Out-Null; $p=@{TenantId=$TargetTenantId;Scopes=$Scopes;NoWelcome=$true}; if($TargetAppId){$p.ClientId=$TargetAppId}; Connect-MgGraph @p; Show-Tenant "TARGET — admin account @ $TargetDomain (write)" }
function Assert-Source  { if((Get-MgContext).TenantId -ne $SourceTenantId){throw 'STOP: not connected to SOURCE tenant'}; 'OK SOURCE' }
function Assert-Target  { if((Get-MgContext).TenantId -ne $TargetTenantId){throw 'STOP: not connected to TARGET tenant'};  'OK TARGET' }
```
> **Least-privilege scopes.** The write set (`$Scopes`) deliberately drops `DeviceManagementManagedDevices.*` — devices re-enroll on the target, they are not cloned. Conditional Access is **opt-in**: add `Policy.ReadWrite.ConditionalAccess` only if you clone CA (cloned CA policies are always **created DISABLED** — review, then enable by hand). If you provision a dedicated app registration instead of interactive sign-in, gate that same scope with `New-IntuneCloneKitAppRegistration.ps1 -EnableConditionalAccess` (off by default).

### Step 2 — Module + unblocking the scripts
```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force; Import-Module Microsoft.Graph.Authentication
Get-ChildItem $Pkg -Filter *.ps1 | Unblock-File
New-Item -ItemType Directory -Force $Logs,$Backup | Out-Null
```

### Step 3 — Connect SOURCE + FRESH EXPORT (read-only) → `$Src`
```powershell
Connect-Source                     # <-- sign in with a SOURCE admin account ; CHECK the "CONNECTED TO / EXPECTED" display
Assert-Source
& $Exporter -SourceTenantId $SourceTenantId -OutputPath $Src
```
> Produces a same-day export, **already rehydrated** (settings, script contents, compliance actions). This is the import source (`$Fixed`).

### Step 4 — Connect TARGET + backup
```powershell
Connect-Target                     # <-- sign in with a TARGET admin account ; CHECK the display
Assert-Target
'deviceManagement/deviceConfigurations','deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts','deviceManagement/roleScopeTags','deviceManagement/assignmentFilters','deviceAppManagement/mobileApps','deviceAppManagement/mobileAppConfigurations','deviceAppManagement/managedAppPolicies'|%{
 (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/$_`?`$top=999").value|ConvertTo-Json -Depth 100|Set-Content "$Backup\$($_ -replace '/','_').json" -Encoding UTF8}
```

### Step 5 — (OPTIONAL) Clean up a previous failed import — preview
> Only if you already have a failed import to clean up (report in `$Report`). Otherwise, skip to step 7.
```powershell
& "$Pkg\Invoke-IntuneImportCleanupFromReport.ps1" -ReportPath $Report -TargetTenantId $TargetTenantId -LogPath "$Logs\01_preview.csv"
```

### Step 6 — (OPTIONAL) Cleanup — execute
```powershell
& "$Pkg\Invoke-IntuneImportCleanupFromReport.ps1" -ReportPath $Report -TargetTenantId $TargetTenantId -Execute -Force -LogPath "$Logs\02_exec.csv"
```

### Step 7 — Preview the policies (no writes)
```powershell
Connect-Target; Assert-Target
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Policies -LogPath "$Logs\03_preflight.csv"
```

### Step 8 — Import (preview each wave: remove `-Execute`)
```powershell
Connect-Target; Assert-Target
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Foundation -Execute -LogPath "$Logs\05_foundation.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Apps       -Execute -LogPath "$Logs\06_apps.csv"
& "$Pkg\Build-IntuneAppIdMap.ps1" -TargetTenantId $TargetTenantId -SourceExportPath "$Fixed\09_Apps" -OutCsv "$Kit\AppIdMap.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Policies   -Execute -LogPath "$Logs\07_policies.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Scripts    -Execute -LogPath "$Logs\08_scripts.csv"
& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Mobile     -Execute -LogPath "$Logs\09_mobile.csv"
```
> **Reconciliation report — review it.** Each wave now writes `reconcile.json` / `reconcile.html` / `reconcile.csv` next to its CSV log (in `$Logs`). It lists every object with its outcome (`Matched` / `Created` / `Failed` / `Skipped` / `Preview` / `OutOfScope`), the reason, the `targetId` and any remap. **Open `reconcile.html`** after each wave. If a security-critical object (Compliance / Conditional Access / Endpoint Security / baseline) is left `Failed` / `Skipped` / `OutOfScope` — or a CA policy was created disabled — a red **SECURITY-CRITICAL NOT APPLIED** banner is shown and the run exits **non-zero** under `-Execute`: act on those items before going live.

### Step 9 — Import summary
```powershell
Get-ChildItem "$Logs\0*.csv"|%{"`n$($_.Name)";Import-Csv $_|Group-Object Status|Format-Table Name,Count -Auto}
```

### Step 10 — Assignments: groups + assignments, remap by NAME (PREVIEW then `-Execute`)
```powershell
# PREVIEW (no writes): source export + groups plan + assignments plan
& "$Pkg\Invoke-IntuneAssignments_Graph.ps1" -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All
# Execution: creates the missing groups (by name) and applies the remapped assignments
& "$Pkg\Invoke-IntuneAssignments_Graph.ps1" -SourceTenantId $SourceTenantId -TargetTenantId $TargetTenantId -Phase All -Execute
```
> In manual mode, this script connects interactively (SOURCE for the export, TARGET for the write). For a fully unattended run, see [`EXECUTER_AUTO.md`](EXECUTER_AUTO.md).
>
> **Assignments are fail-closed.** An object whose target can't be fully resolved is **BLOCKED**, never silently widened. Unresolved **exclusions or filters** always block (a partial `/assign` would broaden scope — create the missing filter/exclusion group on the target, then re-run). If the *only* unresolved targets are **inclusion** groups (the resolved subset is same-or-narrower in scope), add `-AllowPartialInclusionsOnly` to apply that reduced subset instead of blocking.

### Step 11 — Final verification (SOURCE vs TARGET counts)
```powershell
function C($t,$e){Disconnect-MgGraph -EA SilentlyContinue|Out-Null;Connect-MgGraph -TenantId $t -Scopes $ScopesRead -NoWelcome|Out-Null;(Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/$e`?`$top=999").value.Count}
'deviceManagement/configurationPolicies','deviceManagement/deviceCompliancePolicies','deviceManagement/deviceConfigurations','deviceManagement/deviceManagementScripts','deviceManagement/deviceHealthScripts'|%{[pscustomobject]@{Endpoint=$_;Source=(C $SourceTenantId $_);Target=(C $TargetTenantId $_)}}|Format-Table -Auto
```

### Step 12 — Manual (to do by hand, outside the script — Intune limits)
```
- Secret-bearing profiles (Wi-Fi/PSK, AppLocker/WDAC, encrypted OMA values): re-enter the value and recreate.
- LOB / Win32 / VPP apps: re-upload the binary.
- Admin Templates, Endpoint Security (intents), Enrollment: recreate in the portal.
```

### AI assist (optional) — draft recreation help for the manual items
```powershell
# Generate a review-first recreation runbook + PowerShell scaffolds for items that could NOT be
# auto-imported (secrets, ADMX, Endpoint Security intents...). Requires AI settings in config.ps1
# (your own API key). Secrets are redacted; it NEVER writes to a tenant.
& "$Pkg\Invoke-IntuneAIAssist.ps1" -ExportPath $Fixed -ImportLog "$Logs\07_policies.csv" -Language en
# -> ai-output\RUNBOOK.md + ai-output\scaffolds\*.ps1  (review before running anything)
```

### Recover OMA secrets (optional) — before switching to the target
```powershell
# While still connected to the SOURCE, pull the clear value of encrypted OMA-URI secrets and re-inject
# them into the export, so those profiles import automatically (Intune re-encrypts on the target).
# Needs source read rights. Writes plaintext secrets to the export on disk — protect it, never commit.
Connect-Source ; Assert-Source
& "$Pkg\Recover-IntuneOmaSecrets.ps1" -ExportPath $Fixed -SourceTenantId $SourceTenantId
```

### Portal capture → AI recreation (optional) — for objects a Graph token can't export
```powershell
# For Device Inventory policies / gated endpoints: capture the JSON in the browser (F12 -> Network)
# on the source, then let the AI draft a recreation script (review-first, never writes to a tenant).
& "$Pkg\Invoke-IntunePortalCaptureToScript.ps1" -CaptureFile .\capture.json -Description "Device Inventory policy" -Language en
```

### Publish a Win32 app (optional, EXPERIMENTAL) — you provide the .intunewin
```powershell
# App binaries are never exported. Provide the .intunewin + metadata; this orchestrates the upload.
# PREVIEW by default; add -Execute only on a sandbox tenant.
& "$Pkg\Publish-IntuneApp.ps1" -AppMetadataJson .\app.json -IntuneWinFile .\app.intunewin -TargetTenantId $TargetTenantId
```

### Verify export integrity (optional) — offline
```powershell
# SHA-256 integrity check of the export: flags modified / missing / untracked files. No Graph needed.
& "$Pkg\Verify-IntuneExport.ps1" -Path $Fixed
```

### Compare two exports — drift (optional) — offline
```powershell
# What changed between two exports (added / removed / changed per object), e.g. before vs after.
& "$Pkg\Compare-IntuneExport.ps1" -Reference .\input\Export_old -Difference $Fixed -OutputJson "$Logs\drift.json"
```

> **Safe test import without name collisions**: add `-NamePrefix "[Migrated] "` to any import wave to
> create objects with a prefix (dry-run against an already-populated tenant), e.g.
> `& $Engine -SourcePath $Fixed -TargetTenantId $TargetTenantId -SourceTenantId $SourceTenantId -Phase Policies -Execute -NamePrefix "[Migrated] "`

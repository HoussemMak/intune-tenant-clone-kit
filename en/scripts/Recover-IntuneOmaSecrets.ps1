#Requires -Version 7.0
<#
.SYNOPSIS
    OPT-IN: recover encrypted custom OMA-URI secret values from the SOURCE tenant and re-inject them
    into the exported device configuration profiles, so those profiles can be recreated automatically.

.DESCRIPTION
    For every exported 01_DeviceConfigurations profile that contains encrypted omaSettings
    (isEncrypted = true + a secretReferenceValueId), this calls the source-tenant action
    POST deviceManagement/deviceConfigurations/{id}/getOmaSettingPlainTextValue to retrieve the clear
    value, writes it into `value`, and REMOVES the (tenant-specific) secretReferenceValueId. On import,
    Intune re-encrypts the value and generates a fresh pointer in the target tenant — so no admin needs
    to re-type the secret.

    ⚠️ SECURITY: this writes PLAINTEXT secrets into the export files on disk. Keep the export folder
    protected, delete it after import, and NEVER commit it (the kit's .gitignore excludes input/ and
    exports). Requires an active Graph connection to the SOURCE tenant with
    DeviceManagementConfiguration.Read.All (the getOmaSettingPlainTextValue action).

.PARAMETER ExportPath
    The (Fixed)Export folder containing 01_DeviceConfigurations.

.PARAMETER SourceTenantId
    GUID of the SOURCE tenant. Guardrail: refuses if the current Graph context is a different tenant.

.PARAMETER AssumeYes
    Skip the confirmation prompt (for automation).

.EXAMPLE
    # after connecting to the SOURCE tenant:
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
if (-not $ctx) { throw "No Graph connection. Connect to the SOURCE tenant first (Connect-MgGraph -TenantId $SourceTenantId ...)." }
if ($ctx.TenantId -ne $SourceTenantId) { throw "GUARDRAIL: current context $($ctx.TenantId) != source $SourceTenantId. Connect to the SOURCE tenant." }

$dir = Join-Path $ExportPath '01_DeviceConfigurations'
if (-not (Test-Path -LiteralPath $dir)) { Write-Host "No 01_DeviceConfigurations folder in $ExportPath." -ForegroundColor Yellow; return }

Write-Host ""
Write-Host "RECOVER OMA SECRETS (opt-in)" -ForegroundColor Magenta
Write-Host "This writes PLAINTEXT secrets into the export on disk. Protect and delete it after import; never commit it." -ForegroundColor Yellow
if (-not $AssumeYes) { $r = Read-Host "Proceed? [y/N]"; if ($r -notmatch '^[yYoO]') { Write-Host 'Cancelled.'; return } }

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
            $oma.PSObject.Properties.Remove('secretReferenceValueId')   # tenant-specific pointer must not be POSTed
            $recovered++; $changed = $true
        } catch {
            $failed++
            Write-Host ("  [X] {0} / {1}: {2}" -f $o.displayName, $oma.omaUri, $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ($changed) {
        ($o | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $f.FullName -Encoding UTF8
        Write-Host ("  [+] {0} — secrets re-injected" -f $o.displayName) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host ("Profiles with secrets: {0} | recovered settings: {1} | failed: {2}" -f $profiles, $recovered, $failed) -ForegroundColor Cyan
Write-Host "These device-config profiles will now import automatically (Intune re-encrypts on the target)." -ForegroundColor Green
if ($failed -gt 0) { Write-Host "Some values could not be recovered (rights or rotated secrets) — recreate those manually." -ForegroundColor Yellow }

#Requires -Version 7.0
<#
.SYNOPSIS
    Prepare, IN A SINGLE STEP, the app-only identity (app registration + certificate + admin consent)
    required for the ZERO-TOUCH execution of the kit in a tenant.

.DESCRIPTION
    To be run once per tenant, signed in as an administrator (Global Admin or
    Privileged Role Admin + Application Admin). This is the ONLY interactive step of the whole chain:
    the orchestrator then runs without any intervention.

    The script:
      1. connects to Graph in delegated mode (Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All);
      2. creates (or reuses) a self-signed certificate in Cert:\CurrentUser\My;
      3. creates the app registration with the certificate as credential;
      4. adds the APPLICATION Microsoft Graph permissions suited to the role
         (SOURCE = read, TARGET = write);
      5. creates the service principal and grants ADMIN CONSENT (appRoleAssignments);
      6. displays the ClientId + the thumbprint to paste into config.ps1.

.PARAMETER TenantId
    GUID of the tenant to prepare.

.PARAMETER Role
    Source (READ permissions) or Target (WRITE permissions).

.PARAMETER DisplayName
    Name of the app registration. Default: IntuneCloneKit-<Role>.

.PARAMETER CertThumbprint
    Reuse an existing certificate (thumbprint) instead of creating one.

.PARAMETER CertYears
    Validity period of the created certificate (default 2 years).

.PARAMETER SkipConsent
    Do not attempt admin consent via script (to be done afterwards in the portal).

.EXAMPLE
    .\New-IntuneCloneKitAppRegistration.ps1 -TenantId <SRC> -Role Source
    .\New-IntuneCloneKitAppRegistration.ps1 -TenantId <TGT> -Role Target
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,
    [string]$DisplayName,
    [string]$CertThumbprint,
    [int]$CertYears = 2,
    [switch]$SkipConsent
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$GraphAppId = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph
if (-not $DisplayName) { $DisplayName = "IntuneCloneKit-$Role" }

# Application permissions (app roles) required, per role.
$PermsSource = @(
    'DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All',
    'DeviceManagementServiceConfig.Read.All','DeviceManagementRBAC.Read.All',
    'DeviceManagementManagedDevices.Read.All','Group.Read.All','Organization.Read.All'
)
$PermsTarget = @(
    'DeviceManagementConfiguration.ReadWrite.All','DeviceManagementApps.ReadWrite.All',
    'DeviceManagementServiceConfig.ReadWrite.All','DeviceManagementRBAC.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All','Group.ReadWrite.All','Organization.Read.All'
)
$Perms = if ($Role -eq 'Source') { $PermsSource } else { $PermsTarget }

function Info { param($T) Write-Host ("[INFO] {0}" -f $T) -ForegroundColor Cyan }
function Ok   { param($T) Write-Host ("[OK]   {0}" -f $T) -ForegroundColor Green }
function Warn { param($T) Write-Host ("[WARN] {0}" -f $T) -ForegroundColor Yellow }

Write-Host ''
Write-Host ('=' * 84) -ForegroundColor DarkGray
Write-Host ("APP-ONLY PREPARATION - Tenant {0} - Role {1}" -f $TenantId, $Role) -ForegroundColor Green
Write-Host ('=' * 84) -ForegroundColor DarkGray

# --- Module ---
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Info 'Installing Microsoft.Graph.Authentication (CurrentUser).'
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Authentication -Force

# --- Admin connection (interactive, one-time) ---
Info 'Administrator connection to the tenant (a sign-in window may open)...'
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All' -NoWelcome
$ctx = Get-MgContext
if (-not $ctx -or $ctx.TenantId.ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) { throw "Connected to the wrong tenant. Expected $TenantId, connected $($ctx.TenantId)" }
Ok ("Connected: {0} (Tenant {1})" -f $ctx.Account, $ctx.TenantId)

# --- Microsoft Graph service principal + app role resolution ---
Info 'Resolving Microsoft Graph permission identifiers...'
$graphSp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$GraphAppId')"
$roleByValue = @{}
foreach ($r in $graphSp.appRoles) { if ($r.allowedMemberTypes -contains 'Application') { $roleByValue[$r.value] = $r.id } }
$resourceAccess = @()
$resolved = @()
foreach ($p in $Perms) {
    if ($roleByValue.ContainsKey($p)) { $resourceAccess += @{ id = $roleByValue[$p]; type = 'Role' }; $resolved += $p }
    else { Warn ("Permission not found in this tenant: {0} (ignored)" -f $p) }
}
Ok ("{0} application permission(s) resolved." -f $resourceAccess.Count)

# --- Certificate ---
if ($CertThumbprint) {
    $cert = Get-Item ("Cert:\CurrentUser\My\{0}" -f $CertThumbprint) -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Certificate $CertThumbprint not found in Cert:\CurrentUser\My" }
    Ok ("Certificate reused: {0}" -f $cert.Thumbprint)
} else {
    $subject = "CN=IntuneCloneKit-$Role"
    Info ("Creating a self-signed certificate {0} (valid {1} year(s))..." -f $subject, $CertYears)
    $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($CertYears)
    Ok ("Certificate created: {0}" -f $cert.Thumbprint)
}
$certB64 = [Convert]::ToBase64String($cert.GetRawCertData())

# --- App registration (creation or reuse by displayName) ---
$existing = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$DisplayName'").value
if ($existing -and $existing.Count -gt 0) {
    $app = $existing[0]
    Warn ("App '{0}' already exists (AppId {1}): updating permissions + adding the certificate." -f $DisplayName, $app.appId)
    $patch = @{
        requiredResourceAccess = @(@{ resourceAppId = $GraphAppId; resourceAccess = $resourceAccess })
        keyCredentials = @(@{ type='AsymmetricX509Cert'; usage='Verify'; key=$certB64; displayName=$cert.Subject })
    }
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body ($patch | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
    $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)"
} else {
    Info ("Creating the app registration '{0}'..." -f $DisplayName)
    $body = @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
        requiredResourceAccess = @(@{ resourceAppId = $GraphAppId; resourceAccess = $resourceAccess })
        keyCredentials = @(@{ type='AsymmetricX509Cert'; usage='Verify'; key=$certB64; displayName=$cert.Subject })
    }
    $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    Ok ("App created: AppId {0}" -f $app.appId)
}

# --- App service principal ---
$sp = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
if (-not $sp) {
    Info 'Creating the service principal...'
    $sp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body (@{ appId = $app.appId } | ConvertTo-Json) -ContentType 'application/json'
}
Ok ("Service principal: {0}" -f $sp.id)

# --- Admin consent (appRoleAssignments) ---
if ($SkipConsent) {
    Warn 'Admin consent not attempted (-SkipConsent). To grant in the portal: Azure AD > App registrations > API permissions > Grant admin consent.'
} else {
    Info 'Granting admin consent (may require a few seconds of replication)...'
    $existingAssign = @()
    try { $existingAssign = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments").value } catch {}
    $already = @($existingAssign | ForEach-Object { $_.appRoleId })
    $granted = 0; $failed = @()
    foreach ($ra in $resourceAccess) {
        if ($already -contains $ra.id) { $granted++; continue }
        $assign = @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $ra.id }
        $done = $false
        for ($try = 1; $try -le 5 -and -not $done; $try++) {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -Body ($assign | ConvertTo-Json) -ContentType 'application/json' | Out-Null
                $done = $true; $granted++
            } catch {
                if ($try -lt 5) { Start-Sleep -Seconds 5 } else { $failed += $ra.id }
            }
        }
    }
    if ($failed.Count -eq 0) { Ok ("Admin consent granted ({0} permission(s))." -f $granted) }
    else { Warn ("{0} permission(s) granted, {1} failed. Finish in the portal via 'Grant admin consent'." -f $granted, $failed.Count) }
}

# --- Output ---
Write-Host ''
Write-Host ('-' * 84) -ForegroundColor DarkGray
Write-Host 'TO PASTE INTO config.ps1:' -ForegroundColor Green
if ($Role -eq 'Source') {
    Write-Host ("`$SourceClientId       = '{0}'" -f $app.appId) -ForegroundColor White
    Write-Host ("`$SourceCertThumbprint = '{0}'" -f $cert.Thumbprint) -ForegroundColor White
} else {
    Write-Host ("`$TargetClientId       = '{0}'" -f $app.appId) -ForegroundColor White
    Write-Host ("`$TargetCertThumbprint = '{0}'" -f $cert.Thumbprint) -ForegroundColor White
}
Write-Host ('-' * 84) -ForegroundColor DarkGray
Write-Host ''
Info 'Reminder: the certificate must remain in the store of the account/machine that will launch the orchestrator.'
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

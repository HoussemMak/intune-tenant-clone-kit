#Requires -Version 7.0
<#
.SYNOPSIS
    Prepare, EN UNE SEULE FOIS, l'identite app-only (app registration + certificat + consentement admin)
    necessaire a l'execution ZERO-TOUCH du kit dans un tenant.

.DESCRIPTION
    A executer une fois par tenant, connecte en tant qu'administrateur (Global Admin ou
    Privileged Role Admin + Application Admin). C'est le SEUL geste interactif de toute la chaine :
    l'orchestrateur, ensuite, tourne sans aucune intervention.

    Le script :
      1. se connecte a Graph en delegue (Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All) ;
      2. cree (ou reutilise) un certificat auto-signe dans Cert:\CurrentUser\My ;
      3. cree l'app registration avec le certificat en credential ;
      4. ajoute les permissions APPLICATIVES Microsoft Graph adaptees au role
         (SOURCE = lecture, CIBLE = ecriture) ;
      5. cree le service principal et accorde le CONSENTEMENT ADMIN (appRoleAssignments) ;
      6. affiche le ClientId + l'empreinte a coller dans config.ps1.

.PARAMETER TenantId
    GUID du tenant a preparer.

.PARAMETER Role
    Source (permissions LECTURE) ou Target (permissions ECRITURE).

.PARAMETER DisplayName
    Nom de l'app registration. Defaut : IntuneCloneKit-<Role>.

.PARAMETER CertThumbprint
    Reutiliser un certificat existant (empreinte) au lieu d'en creer un.

.PARAMETER CertYears
    Duree de validite du certificat cree (defaut 2 ans).

.PARAMETER SkipConsent
    Ne pas tenter le consentement admin par script (a faire ensuite au portail).

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

# Permissions applicatives (app roles) requises, par role.
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
Write-Host ("PREPARATION APP-ONLY - Tenant {0} - Role {1}" -f $TenantId, $Role) -ForegroundColor Green
Write-Host ('=' * 84) -ForegroundColor DarkGray

# --- Module ---
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Info 'Installation de Microsoft.Graph.Authentication (CurrentUser).'
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Authentication -Force

# --- Connexion admin (interactive, unique) ---
Info 'Connexion administrateur au tenant (une fenetre de connexion peut s ouvrir)...'
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','Directory.Read.All' -NoWelcome
$ctx = Get-MgContext
if (-not $ctx -or $ctx.TenantId.ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) { throw "Connexion sur mauvais tenant. Attendu $TenantId, connecte $($ctx.TenantId)" }
Ok ("Connecte : {0} (Tenant {1})" -f $ctx.Account, $ctx.TenantId)

# --- Service principal Microsoft Graph + resolution des app roles ---
Info 'Resolution des identifiants de permissions Microsoft Graph...'
$graphSp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$GraphAppId')"
$roleByValue = @{}
foreach ($r in $graphSp.appRoles) { if ($r.allowedMemberTypes -contains 'Application') { $roleByValue[$r.value] = $r.id } }
$resourceAccess = @()
$resolved = @()
foreach ($p in $Perms) {
    if ($roleByValue.ContainsKey($p)) { $resourceAccess += @{ id = $roleByValue[$p]; type = 'Role' }; $resolved += $p }
    else { Warn ("Permission introuvable dans ce tenant : {0} (ignoree)" -f $p) }
}
Ok ("{0} permission(s) applicative(s) resolue(s)." -f $resourceAccess.Count)

# --- Certificat ---
if ($CertThumbprint) {
    $cert = Get-Item ("Cert:\CurrentUser\My\{0}" -f $CertThumbprint) -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Certificat $CertThumbprint introuvable dans Cert:\CurrentUser\My" }
    Ok ("Certificat reutilise : {0}" -f $cert.Thumbprint)
} else {
    $subject = "CN=IntuneCloneKit-$Role"
    Info ("Creation d'un certificat auto-signe {0} (valide {1} an(s))..." -f $subject, $CertYears)
    $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($CertYears)
    Ok ("Certificat cree : {0}" -f $cert.Thumbprint)
}
$certB64 = [Convert]::ToBase64String($cert.GetRawCertData())

# --- App registration (creation ou reutilisation par displayName) ---
$existing = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$DisplayName'").value
if ($existing -and $existing.Count -gt 0) {
    $app = $existing[0]
    Warn ("App '{0}' deja existante (AppId {1}) : mise a jour des permissions + ajout du certificat." -f $DisplayName, $app.appId)
    $patch = @{
        requiredResourceAccess = @(@{ resourceAppId = $GraphAppId; resourceAccess = $resourceAccess })
        keyCredentials = @(@{ type='AsymmetricX509Cert'; usage='Verify'; key=$certB64; displayName=$cert.Subject })
    }
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body ($patch | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
    $app = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)"
} else {
    Info ("Creation de l'app registration '{0}'..." -f $DisplayName)
    $body = @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
        requiredResourceAccess = @(@{ resourceAppId = $GraphAppId; resourceAccess = $resourceAccess })
        keyCredentials = @(@{ type='AsymmetricX509Cert'; usage='Verify'; key=$certB64; displayName=$cert.Subject })
    }
    $app = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    Ok ("App creee : AppId {0}" -f $app.appId)
}

# --- Service principal de l'app ---
$sp = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
if (-not $sp) {
    Info 'Creation du service principal...'
    $sp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' -Body (@{ appId = $app.appId } | ConvertTo-Json) -ContentType 'application/json'
}
Ok ("Service principal : {0}" -f $sp.id)

# --- Consentement admin (appRoleAssignments) ---
if ($SkipConsent) {
    Warn 'Consentement admin non tente (-SkipConsent). A accorder au portail : Azure AD > App registrations > API permissions > Grant admin consent.'
} else {
    Info 'Attribution du consentement admin (peut necessiter quelques secondes de replication)...'
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
    if ($failed.Count -eq 0) { Ok ("Consentement admin accorde ({0} permission(s))." -f $granted) }
    else { Warn ("{0} permission(s) accordee(s), {1} en echec. Terminer au portail via 'Grant admin consent'." -f $granted, $failed.Count) }
}

# --- Restitution ---
Write-Host ''
Write-Host ('-' * 84) -ForegroundColor DarkGray
Write-Host 'A COLLER DANS config.ps1 :' -ForegroundColor Green
if ($Role -eq 'Source') {
    Write-Host ("`$SourceClientId       = '{0}'" -f $app.appId) -ForegroundColor White
    Write-Host ("`$SourceCertThumbprint = '{0}'" -f $cert.Thumbprint) -ForegroundColor White
} else {
    Write-Host ("`$TargetClientId       = '{0}'" -f $app.appId) -ForegroundColor White
    Write-Host ("`$TargetCertThumbprint = '{0}'" -f $cert.Thumbprint) -ForegroundColor White
}
Write-Host ('-' * 84) -ForegroundColor DarkGray
Write-Host ''
Info 'Rappel : le certificat doit rester dans le magasin du compte/machine qui lancera l orchestrateur.'
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

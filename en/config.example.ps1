# ============================================================================
#  config.example.ps1
#  -> Copy this file to "config.ps1" then fill in YOUR values.
#  -> config.ps1 is ignored by git (.gitignore): it will NEVER be published.
# ============================================================================

$SourceTenantId = '<SOURCE_TENANT_ID>'      # GUID of the SOURCE tenant (e.g. production)
$TargetTenantId = '<TARGET_TENANT_ID>'      # GUID of the TARGET tenant (e.g. test / sandbox)

# Domains: used ONLY to display which account to use at login time (manual mode).
$SourceDomain   = 'source.onmicrosoft.com'
$TargetDomain   = 'target.onmicrosoft.com'

# ----------------------------------------------------------------------------
#  ZERO-TOUCH MODE (app-only certificate) — used by Invoke-IntuneCloneKit-Unattended.ps1
#  Unattended execution requires an app registration + certificate per tenant,
#  with admin consent for APPLICATION permissions (not delegated).
#  Generate all of this once with: tools\New-IntuneCloneKitAppRegistration.ps1
# ----------------------------------------------------------------------------

# App registration on the SOURCE side (READ permissions):
$SourceClientId          = ''   # ClientId (AppId) of the app in the SOURCE tenant
$SourceCertThumbprint    = ''   # Thumbprint of the certificate installed in Cert:\CurrentUser\My

# App registration on the TARGET side (WRITE permissions):
$TargetClientId          = ''   # ClientId (AppId) of the app in the TARGET tenant
$TargetCertThumbprint    = ''   # Thumbprint of the certificate installed in Cert:\CurrentUser\My

# Fallback: a single MULTI-TENANT app + a single certificate, valid for both tenants.
# Fill this in ONLY if you are not using the per-tenant values above.
$ClientId       = ''
$CertThumbprint = ''

# Optional (legacy manual mode): App registration for interactive Connect-MgGraph.
$AppId          = ''

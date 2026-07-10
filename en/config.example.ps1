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

# Optional PER-TENANT app registration for the MANUAL (delegated / interactive) mode. Use these if
# each tenant has its OWN approved public-client app for sign-in. Empty = default Microsoft Graph
# PowerShell app (works cross-tenant). (Zero-touch uses SourceClientId/TargetClientId above instead.)
$SourceAppId = ''   # delegated ClientId approved in the SOURCE tenant
$TargetAppId = ''   # delegated ClientId approved in the TARGET tenant

# ----------------------------------------------------------------------------
#  AI ASSIST (optional, experimental) — used by scripts\Invoke-IntuneAIAssist.ps1
#  Drafts recreation runbooks/scaffolds for items the kit cannot auto-import.
#  The API key is YOURS and is never shipped with the kit (config.ps1 is gitignored).
#  Prefer Azure OpenAI so the data stays in your tenant.
# ----------------------------------------------------------------------------
$AiProvider = ''   # 'AzureOpenAI' | 'OpenAI' | 'Custom'
$AiEndpoint = ''   # full chat/completions URL (required for AzureOpenAI / Custom)
$AiApiKey   = ''   # YOUR API key
$AiModel    = ''   # model / deployment name

# ============================================================================
#  config.example.ps1
#  -> Copier ce fichier en "config.ps1" puis renseigner VOS valeurs.
#  -> config.ps1 est ignoré par git (.gitignore) : il ne sera JAMAIS publié.
# ============================================================================

$SourceTenantId = '<SOURCE_TENANT_ID>'      # GUID du tenant SOURCE (ex. production)
$TargetTenantId = '<TARGET_TENANT_ID>'      # GUID du tenant CIBLE  (ex. test / bac à sable)

# Domaines : servent UNIQUEMENT à afficher quel compte utiliser au moment du login (mode manuel).
$SourceDomain   = 'source.onmicrosoft.com'
$TargetDomain   = 'target.onmicrosoft.com'

# ----------------------------------------------------------------------------
#  MODE ZERO-TOUCH (app-only certificat) — utilisé par Invoke-IntuneCloneKit-Unattended.ps1
#  L'exécution non-surveillée exige une app registration + certificat par tenant,
#  avec consentement admin des permissions APPLICATIVES (pas déléguées).
#  Générez tout cela une seule fois avec : tools\New-IntuneCloneKitAppRegistration.ps1
# ----------------------------------------------------------------------------

# App registration côté SOURCE (permissions en LECTURE) :
$SourceClientId          = ''   # ClientId (AppId) de l'app dans le tenant SOURCE
$SourceCertThumbprint    = ''   # Empreinte du certificat installé dans Cert:\CurrentUser\My

# App registration côté CIBLE (permissions en ÉCRITURE) :
$TargetClientId          = ''   # ClientId (AppId) de l'app dans le tenant CIBLE
$TargetCertThumbprint    = ''   # Empreinte du certificat installé dans Cert:\CurrentUser\My

# Repli : une seule app MULTI-TENANT + un seul certificat, valables pour les deux tenants.
# Renseignez ceci UNIQUEMENT si vous n'utilisez pas les valeurs par tenant ci-dessus.
$ClientId       = ''
$CertThumbprint = ''

# Optionnel (mode manuel legacy) : App registration pour Connect-MgGraph interactif.
$AppId          = ''

# ----------------------------------------------------------------------------
#  ASSISTANT IA (optionnel, expérimental) — utilisé par scripts\Invoke-IntuneAIAssist.ps1
#  Rédige des runbooks/scaffolds de recréation pour les éléments non importables automatiquement.
#  La clé API est LA VÔTRE et n'est jamais livrée avec le kit (config.ps1 est gitignoré).
#  Préférez Azure OpenAI pour que les données restent dans votre tenant.
# ----------------------------------------------------------------------------
$AiProvider = ''   # 'AzureOpenAI' | 'OpenAI' | 'Custom'
$AiEndpoint = ''   # URL complète chat/completions (requis pour AzureOpenAI / Custom)
$AiApiKey   = ''   # VOTRE clé API
$AiModel    = ''   # nom du modèle / déploiement

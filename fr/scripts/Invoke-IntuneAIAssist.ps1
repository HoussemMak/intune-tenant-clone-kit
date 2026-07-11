#Requires -Version 7.0
<#
.SYNOPSIS
    ASSISTANT IA de recréation, EXPÉRIMENTAL et OPT-IN, pour les éléments que le kit ne peut pas importer automatiquement.

.DESCRIPTION
    Pour chaque élément MANUEL / IGNORÉ (profils à secret chiffré, Modèles d'administration, intents
    Endpoint Security, ou toute ligne SKIP_* d'un journal d'import), cet outil demande à un endpoint IA
    CONFIGURABLE de rédiger :
      1. un guide de recréation court pour l'admin du tenant cible (étapes portail), et
      2. un scaffold PowerShell + Microsoft Graph (avec -WhatIf et <PLACEHOLDER> pour les secrets).
    La sortie est écrite dans .\ai-output (un runbook + des fichiers scaffold .ps1) pour REVUE HUMAINE.

    IL N'ÉCRIT JAMAIS DANS UN TENANT et n'exécute rien automatiquement. Objectif : réduire le travail
    manuel au portail, pas remplacer le jugement humain.

    CONFIDENTIALITÉ : les MÉTADONNÉES des objets sont envoyées à l'endpoint IA que vous configurez. Les
    valeurs secrètes sont expurgées avant l'envoi. C'est OPT-IN. Préférez Azure OpenAI (les données
    restent dans votre tenant) à une API publique.

.PARAMETER ExportPath
    Dossier d'export produit par le kit (contient manifest.json + familles NN_*).

.PARAMETER ImportLog
    (Optionnel) Journal CSV du moteur d'import ; les lignes SKIP_* / ERROR pilotent la liste d'éléments.

.PARAMETER OutputPath
    Où écrire le runbook + scaffolds. Défaut : .\ai-output

.PARAMETER Language
    Langue du runbook généré : en | fr. Défaut en.

.PARAMETER MaxItems
    Garde-fou sur le nombre d'éléments envoyés à l'IA. Défaut 25.

.PARAMETER ExcludeFamilies
    Familles à ignorer (ex. 01_DeviceConfigurations).

.PARAMETER AssumeYes
    Saute la confirmation de confidentialité (pour l'automatisation).

.PARAMETER SendToProvider
    Opt-in explicite pour contacter réellement l'endpoint IA sur le réseau. SANS ce switch, l'outil
    tourne en DRY-RUN : il expurge et écrit les métadonnées localement et ne fait AUCUN appel réseau.

.NOTES
    Les réglages IA sont lus depuis config.ps1 (gitignoré) ou des variables d'environnement. La clé API
    n'est JAMAIS livrée avec le kit :
      $AiProvider = 'AzureOpenAI' | 'OpenAI' | 'Custom'      (env : INTUNE_AI_PROVIDER)
      $AiEndpoint = '<URL complète chat/completions>'        (env : INTUNE_AI_ENDPOINT)
      $AiApiKey   = '<votre clé>'                            (env : INTUNE_AI_API_KEY)
      $AiModel    = '<nom du modèle / déploiement>'          (env : INTUNE_AI_MODEL)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExportPath,
    [string]$ImportLog,
    [string]$OutputPath = (Join-Path (Get-Location) 'ai-output'),
    [ValidateSet('en','fr')][string]$Language = 'en',
    [int]$MaxItems = 25,
    [string[]]$ExcludeFamilies,
    [switch]$AssumeYes,
    [switch]$SendToProvider
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Configuration IA (config.ps1 à la racine du bundle, sinon variables d'environnement). Clé jamais livrée. ---
$cfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }
$AiProvider = if ($AiProvider) { $AiProvider } elseif ($env:INTUNE_AI_PROVIDER) { $env:INTUNE_AI_PROVIDER } else { 'OpenAI' }
$AiEndpoint = if ($AiEndpoint) { $AiEndpoint } else { $env:INTUNE_AI_ENDPOINT }
$AiApiKey   = if ($AiApiKey)   { $AiApiKey }   else { $env:INTUNE_AI_API_KEY }
$AiModel    = if ($AiModel)    { $AiModel }    else { $env:INTUNE_AI_MODEL }

if ($SendToProvider -and -not $AiApiKey) {
    throw "Aucune clé API IA. Renseignez `$AiApiKey (et `$AiEndpoint / `$AiModel / `$AiProvider) dans config.ps1, ou les variables d'environnement INTUNE_AI_*. La clé est fournie par VOUS et n'est jamais livrée avec le kit. (Une clé n'est requise qu'avec -SendToProvider ; le dry-run n'en a pas besoin.)"
}

# --- Garde-fou de confidentialité (opt-in) ---
Write-Host ""
Write-Host "ASSISTANT IA DE RECRÉATION (expérimental)" -ForegroundColor Magenta
if ($SendToProvider) {
    Write-Host "Les MÉTADONNÉES des objets (secrets expurgés) SERONT envoyées à : $AiProvider" -ForegroundColor Yellow
} else {
    Write-Host "DRY-RUN : -SendToProvider absent. RIEN n'est envoyé ; les métadonnées expurgées sont écrites localement uniquement." -ForegroundColor Yellow
}
Write-Host "Cet outil n'écrit JAMAIS dans un tenant. La sortie est pour revue uniquement." -ForegroundColor Yellow
if ($SendToProvider -and -not $AssumeYes) {
    $r = Read-Host "Continuer ? [o/N]"
    if ($r -notmatch '^[yYoO]') { Write-Host "Annulé."; return }
}

# --- Expurgation : retirer les valeurs secrètes avant tout envoi hors de la machine ---
# Noms de propriété / clé dont la valeur est TOUJOURS expurgée (défense en profondeur).
$secretKeys = @(
    'secretReferenceValueId','value','password','omaSettingBase64',
    'scriptContent','detectionScriptContent','remediationScriptContent',
    'privateKey','certificate','token','connectionString','clientSecret'
)
function Remove-Secrets {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string]) -and -not ($Obj -is [System.Collections.IDictionary])) {
        return @($Obj | ForEach-Object { Remove-Secrets $_ })
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Obj.Keys) {
            if ($k -in $secretKeys) { $o[$k] = '<REDACTED>' }
            else { $o[$k] = Remove-Secrets $Obj[$k] }
        }
        return $o
    }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) {
            if ($p.Name -in $secretKeys) { $o[$p.Name] = '<REDACTED>' }
            else { $o[$p.Name] = Remove-Secrets $p.Value }
        }
        return [pscustomobject]$o
    }
    return $Obj
}

# --- Pré-scan strict : refuser de transmettre tout ce qui ressemble encore à un secret ---
function Assert-NoSecret {
    param([string]$Payload)
    foreach ($pat in @('-----BEGIN','MII[A-Za-z0-9+/]{200,}','\b[0-9A-Fa-f]{40}\b')) {
        if ($Payload -match $pat) {
            throw "Pré-scan secret déclenché ('$pat') : interruption AVANT tout appel réseau. Rien n'a été envoyé."
        }
    }
}

# --- Appel chat provider-agnostique (compatible OpenAI) ---
function Invoke-AiChat {
    param([string]$System,[string]$User)
    $body = @{ messages = @(@{ role='system'; content=$System }, @{ role='user'; content=$User }); temperature = 0.2 }
    switch ($AiProvider) {
        'AzureOpenAI' {
            if (-not $AiEndpoint) { throw 'AzureOpenAI exige $AiEndpoint (URL complète chat/completions avec api-version).' }
            $uri = $AiEndpoint; $headers = @{ 'api-key' = $AiApiKey }
        }
        'OpenAI' {
            $body.model = if ($AiModel) { $AiModel } else { 'gpt-4.1-mini' }
            $uri = if ($AiEndpoint) { $AiEndpoint } else { 'https://api.openai.com/v1/chat/completions' }
            $headers = @{ Authorization = "Bearer $AiApiKey" }
        }
        default { # Endpoint personnalisé compatible OpenAI
            if (-not $AiEndpoint) { throw 'Le provider Custom exige $AiEndpoint.' }
            if ($AiModel) { $body.model = $AiModel }
            $uri = $AiEndpoint; $headers = @{ Authorization = "Bearer $AiApiKey" }
        }
    }
    # Défense en profondeur : expurger TOUT le payload récursivement avant qu'il ne quitte la machine.
    $body = Remove-Secrets $body
    $payloadJson = ($body | ConvertTo-Json -Depth 12)
    # Pré-scan strict sur le payload sérialisé : un secret témoin interrompt ici, AVANT tout Invoke-RestMethod.
    Assert-NoSecret -Payload $payloadJson
    # Garde-fou opt-in réseau : sans -SendToProvider, AUCUNE sortie réseau (dry-run).
    if (-not $SendToProvider) {
        return "[DRY-RUN] -SendToProvider absent : aucun appel IA externe effectué. Métadonnées expurgées uniquement."
    }
    $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -ContentType 'application/json' -Body $payloadJson
    return [string]$resp.choices[0].message.content
}

# --- Construire la liste des éléments MANUELS / ignorés ---
function Get-ManualItems {
    $items = @()
    if ($ImportLog -and (Test-Path -LiteralPath $ImportLog)) {
        foreach ($r in (Import-Csv -LiteralPath $ImportLog)) {
            if ($r.Status -and ($r.Status -like 'SKIP*' -or $r.Status -eq 'ERROR')) {
                $items += [pscustomobject]@{ Family=$r.Family; Name=$r.Name; Reason=($r.Reason + ' ' + $r.Error + ' ' + $r.ErrorMessage).Trim() }
            }
        }
    }
    # Repli / complément : parcourir l'export pour les familles manuelles connues.
    foreach ($fam in '01_DeviceConfigurations','14_AdminTemplates','15_EndpointSecurity') {
        if ($ExcludeFamilies -contains $fam) { continue }
        $dir = Join-Path $ExportPath $fam
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -Filter *.json -File)) {
            $o = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $isSecret = $fam -eq '01_DeviceConfigurations' -and @($o.omaSettings | Where-Object { $_.secretReferenceValueId }).Count -gt 0
            if ($fam -eq '01_DeviceConfigurations' -and -not $isSecret) { continue }  # les device configs sans secret sont importées automatiquement
            $name = if ($o.displayName) { $o.displayName } else { $o.name }
            if ($items.Name -notcontains $name) {
                $items += [pscustomobject]@{ Family=$fam; Name=$name; Reason='Famille manuelle / non importable automatiquement'; _file=$f.FullName }
            }
        }
    }
    return $items | Select-Object -First $MaxItems
}

# --- Programme principal ---
New-Item -ItemType Directory -Force -Path $OutputPath, (Join-Path $OutputPath 'scaffolds') | Out-Null
$manual = @(Get-ManualItems)
if ($manual.Count -eq 0) { Write-Host "Aucun élément manuel/ignoré trouvé." -ForegroundColor Green; return }
Write-Host ("Rédaction de l'aide de recréation pour {0} élément(s)..." -f $manual.Count) -ForegroundColor Cyan

$system = @"
Tu es un ingénieur senior Microsoft Intune et Microsoft Graph. Pour un objet Intune exporté qui n'a
PAS pu être importé automatiquement dans un tenant cible, rédige ta réponse en $Language et produis :
1. Un guide de recréation concis et numéroté pour l'admin du tenant cible (étapes portail Intune).
2. Un scaffold PowerShell + Microsoft Graph (Invoke-MgGraphRequest, beta) qui le recrée, avec -WhatIf
   quand c'est pertinent et un <PLACEHOLDER> clairement marqué pour tout secret absent de l'export.
N'invente jamais de valeur secrète. Reste pratique et court. Renvoie du Markdown et place le script
dans un unique bloc de code balisé 'powershell'.
"@

$runbook = New-Object System.Text.StringBuilder
[void]$runbook.AppendLine("# Runbook de recréation IA (à relire avant usage)`n")
[void]$runbook.AppendLine("> Généré par Invoke-IntuneAIAssist.ps1. **Relisez chaque étape et script avant exécution.** Rien ici n'a été exécuté dans un tenant.`n")

$i = 0
foreach ($it in $manual) {
    $i++
    Write-Host ("  [{0}/{1}] {2}" -f $i, $manual.Count, $it.Name) -ForegroundColor DarkCyan
    $meta = @{ family=$it.Family; name=$it.Name; reason=$it.Reason }
    if ($it._file) { $meta.object = (Remove-Secrets (Get-Content $it._file -Raw | ConvertFrom-Json)) }
    $user = "Famille : $($it.Family)`nNom : $($it.Name)`nRaison de l'exclusion : $($it.Reason)`nMétadonnées objet expurgées (JSON) :`n" + ($meta | ConvertTo-Json -Depth 20)
    try {
        $answer = Invoke-AiChat -System $system -User $user
    } catch {
        [void]$runbook.AppendLine("## $($it.Name) ($($it.Family))`n_Appel IA échoué : $($_.Exception.Message)_`n")
        continue
    }
    [void]$runbook.AppendLine("## $($it.Name)  ·  _$($it.Family)_`n")
    [void]$runbook.AppendLine($answer + "`n")
    if (-not $SendToProvider) {
        [void]$runbook.AppendLine("`n> DRY-RUN - rien n'a été envoyé. Métadonnées expurgées qui SERAIENT envoyées :`n")
        [void]$runbook.AppendLine('```json')
        [void]$runbook.AppendLine(($meta | ConvertTo-Json -Depth 20))
        [void]$runbook.AppendLine('```')
    }
    [void]$runbook.AppendLine("`n---`n")
    $m = [regex]::Match($answer, '(?s)```powershell(.*?)```')
    if ($m.Success) {
        $safe = ($it.Name -replace '[^\w\.\- ]','_').Trim(); if ($safe.Length -gt 60) { $safe = $safe.Substring(0,60) }
        $sf = Join-Path $OutputPath ("scaffolds\{0}.ps1" -f $safe)
        ("# À RELIRE AVANT EXÉCUTION - scaffold généré par IA. Ne jamais exécuter à l'aveugle dans un tenant.`n" + $m.Groups[1].Value.Trim()) |
            Set-Content -LiteralPath $sf -Encoding UTF8
    }
}

$rbPath = Join-Path $OutputPath 'RUNBOOK.md'
Set-Content -LiteralPath $rbPath -Value $runbook.ToString() -Encoding UTF8
Write-Host ""
Write-Host ("Runbook : {0}" -f $rbPath) -ForegroundColor Green
Write-Host ("Scaffolds : {0}" -f (Join-Path $OutputPath 'scaffolds')) -ForegroundColor Green
Write-Host "RELISEZ tout avant d'exécuter le moindre script généré." -ForegroundColor Yellow

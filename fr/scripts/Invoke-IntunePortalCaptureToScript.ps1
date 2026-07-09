#Requires -Version 7.0
<#
.SYNOPSIS
    EXPÉRIMENTAL, OPT-IN : transforme une charge utile JSON capturée depuis le portail Intune (pour les objets que le
    jeton Graph standard ne peut pas exporter — par ex. stratégies d'inventaire d'appareils, points de terminaison internes/restreints) en
    script de recréation à réviser en priorité, à l'aide d'un point de terminaison IA configurable.

.DESCRIPTION
    Certaines fonctionnalités Intune sont pilotées par le jeton interne du portail et ne sont pas renvoyées par un jeton Graph
    application/délégué classique. Vous pouvez tout de même capturer le JSON de la requête/réponse depuis le navigateur
    (F12 → Réseau) sur le tenant SOURCE. Fournissez ce JSON ici ; l'IA rédige un script de recréation PowerShell + Microsoft
    Graph pour le tenant CIBLE. La sortie est destinée à une RÉVISION HUMAINE — rien n'est exécuté.

    Les paramètres IA proviennent de config.ps1 (ignoré par git) ou des variables d'environnement INTUNE_AI_*. La clé d'API
    est LA VÔTRE et n'est jamais livrée avec le kit.

.PARAMETER CaptureFile
    Chemin vers le JSON capturé depuis le portail.

.PARAMETER Description
    Brève description de ce qu'est le JSON (par ex. « stratégie d'inventaire d'appareils / catalogue de propriétés »).

.PARAMETER OutputPath
    Emplacement où écrire le script de recréation + les notes. Par défaut : .\ai-output\captured

.PARAMETER Language
    Langue des notes générées : en | fr. Par défaut en.

.EXAMPLE
    .\Invoke-IntunePortalCaptureToScript.ps1 -CaptureFile .\device-inventory.json -Description "Device Inventory policy"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaptureFile,
    [string]$Description = 'captured Intune portal object',
    [string]$OutputPath = (Join-Path (Get-Location) 'ai-output\captured'),
    [ValidateSet('en','fr')][string]$Language = 'en'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $CaptureFile)) { throw "Fichier de capture introuvable : $CaptureFile" }

# --- Config IA (config.ps1 à la racine du bundle, sinon environnement). Clé jamais incluse dans le bundle. ---
$cfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }
$AiProvider = if ($AiProvider) { $AiProvider } elseif ($env:INTUNE_AI_PROVIDER) { $env:INTUNE_AI_PROVIDER } else { 'OpenAI' }
$AiEndpoint = if ($AiEndpoint) { $AiEndpoint } else { $env:INTUNE_AI_ENDPOINT }
$AiApiKey   = if ($AiApiKey)   { $AiApiKey }   else { $env:INTUNE_AI_API_KEY }
$AiModel    = if ($AiModel)    { $AiModel }    else { $env:INTUNE_AI_MODEL }
if (-not $AiApiKey) { throw "Aucune clé d'API IA. Définissez `$AiApiKey (et `$AiEndpoint / `$AiModel / `$AiProvider) dans config.ps1 ou les variables d'environnement INTUNE_AI_*." }

function Invoke-AiChat {
    param([string]$System,[string]$User)
    $body = @{ messages = @(@{ role='system'; content=$System }, @{ role='user'; content=$User }); temperature = 0.2 }
    switch ($AiProvider) {
        'AzureOpenAI' { if (-not $AiEndpoint) { throw 'AzureOpenAI nécessite $AiEndpoint.' }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ 'api-key' = $AiApiKey } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
        'OpenAI' { $body.model = if ($AiModel) { $AiModel } else { 'gpt-4.1-mini' }
            $uri = if ($AiEndpoint) { $AiEndpoint } else { 'https://api.openai.com/v1/chat/completions' }
            $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $AiApiKey" } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
        default { if (-not $AiEndpoint) { throw 'Le fournisseur personnalisé nécessite $AiEndpoint.' }
            if ($AiModel) { $body.model = $AiModel }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ Authorization = "Bearer $AiApiKey" } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
    }
    return [string]$resp.choices[0].message.content
}

$raw = Get-Content -LiteralPath $CaptureFile -Raw
# Masquage léger des clés à l'aspect manifestement sensible avant l'envoi.
$raw = [regex]::Replace($raw, '("(?:value|password|secret|token|key|clientSecret)"\s*:\s*)"[^"]*"', '$1"<REDACTED>"', 'IgnoreCase')

$system = @"
You are a senior Microsoft Intune and Microsoft Graph engineer. You receive a JSON payload captured
from the Intune portal for an object that a standard Graph token cannot export ($Description). Write
the answer in $Language and produce: a short explanation, then a PowerShell + Microsoft Graph
(Invoke-MgGraphRequest, beta) recreation script for the TARGET tenant, using -WhatIf where relevant and
<PLACEHOLDER> for anything secret or tenant-specific. If the endpoint is undocumented, say so and give
the best-effort portal steps. Return Markdown with a single fenced 'powershell' code block.
"@

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
Write-Host "Demande à l'IA de rédiger un script de recréation..." -ForegroundColor Cyan
$answer = Invoke-AiChat -System $system -User $raw

$base = [System.IO.Path]::GetFileNameWithoutExtension($CaptureFile)
Set-Content -LiteralPath (Join-Path $OutputPath ("{0}.notes.md" -f $base)) -Value $answer -Encoding UTF8
$m = [regex]::Match($answer, '(?s)```powershell(.*?)```')
if ($m.Success) {
    Set-Content -LiteralPath (Join-Path $OutputPath ("{0}.recreate.ps1" -f $base)) `
        -Value ("# REVIEW BEFORE RUNNING - AI-generated from a portal capture. Never run blindly.`n" + $m.Groups[1].Value.Trim()) -Encoding UTF8
}
Write-Host ("Sortie : {0}" -f $OutputPath) -ForegroundColor Green
Write-Host "Révisez tout avant d'exécuter le moindre script généré." -ForegroundColor Yellow

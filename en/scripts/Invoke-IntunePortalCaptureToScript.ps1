#Requires -Version 7.0
<#
.SYNOPSIS
    EXPERIMENTAL, OPT-IN: turn a JSON payload captured from the Intune portal (for objects the standard
    Graph token cannot export — e.g. Device Inventory policies, gated/internal endpoints) into a
    review-first recreation script, using a configurable AI endpoint.

.DESCRIPTION
    Some Intune features are driven by the portal's internal token and are not returned by a regular
    Graph app/delegated token. You can still capture the request/response JSON from the browser
    (F12 → Network) on the SOURCE tenant. Feed that JSON here; the AI drafts a PowerShell + Microsoft
    Graph recreation script for the TARGET tenant. Output is for HUMAN REVIEW — nothing is executed.

    AI settings come from config.ps1 (git-ignored) or INTUNE_AI_* environment variables. The API key
    is YOURS and is never shipped with the kit.

.PARAMETER CaptureFile
    Path to the JSON captured from the portal.

.PARAMETER Description
    Short description of what the JSON is (e.g. "Device Inventory policy / properties catalog").

.PARAMETER OutputPath
    Where to write the recreation script + notes. Default: .\ai-output\captured

.PARAMETER Language
    Language of the generated notes: en | fr. Default en.

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

if (-not (Test-Path -LiteralPath $CaptureFile)) { throw "CaptureFile not found: $CaptureFile" }

# --- AI config (config.ps1 at the bundle root, else environment). Key never bundled. ---
$cfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }
$AiProvider = if ($AiProvider) { $AiProvider } elseif ($env:INTUNE_AI_PROVIDER) { $env:INTUNE_AI_PROVIDER } else { 'OpenAI' }
$AiEndpoint = if ($AiEndpoint) { $AiEndpoint } else { $env:INTUNE_AI_ENDPOINT }
$AiApiKey   = if ($AiApiKey)   { $AiApiKey }   else { $env:INTUNE_AI_API_KEY }
$AiModel    = if ($AiModel)    { $AiModel }    else { $env:INTUNE_AI_MODEL }
if (-not $AiApiKey) { throw "No AI API key. Set `$AiApiKey (and `$AiEndpoint / `$AiModel / `$AiProvider) in config.ps1 or INTUNE_AI_* env vars." }

function Invoke-AiChat {
    param([string]$System,[string]$User)
    $body = @{ messages = @(@{ role='system'; content=$System }, @{ role='user'; content=$User }); temperature = 0.2 }
    switch ($AiProvider) {
        'AzureOpenAI' { if (-not $AiEndpoint) { throw 'AzureOpenAI requires $AiEndpoint.' }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ 'api-key' = $AiApiKey } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
        'OpenAI' { $body.model = if ($AiModel) { $AiModel } else { 'gpt-4.1-mini' }
            $uri = if ($AiEndpoint) { $AiEndpoint } else { 'https://api.openai.com/v1/chat/completions' }
            $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $AiApiKey" } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
        default { if (-not $AiEndpoint) { throw 'Custom provider requires $AiEndpoint.' }
            if ($AiModel) { $body.model = $AiModel }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ Authorization = "Bearer $AiApiKey" } -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12) }
    }
    return [string]$resp.choices[0].message.content
}

$raw = Get-Content -LiteralPath $CaptureFile -Raw
# Light redaction of obvious secret-like keys before sending.
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
Write-Host "Asking the AI to draft a recreation script..." -ForegroundColor Cyan
$answer = Invoke-AiChat -System $system -User $raw

$base = [System.IO.Path]::GetFileNameWithoutExtension($CaptureFile)
Set-Content -LiteralPath (Join-Path $OutputPath ("{0}.notes.md" -f $base)) -Value $answer -Encoding UTF8
$m = [regex]::Match($answer, '(?s)```powershell(.*?)```')
if ($m.Success) {
    Set-Content -LiteralPath (Join-Path $OutputPath ("{0}.recreate.ps1" -f $base)) `
        -Value ("# REVIEW BEFORE RUNNING - AI-generated from a portal capture. Never run blindly.`n" + $m.Groups[1].Value.Trim()) -Encoding UTF8
}
Write-Host ("Output: {0}" -f $OutputPath) -ForegroundColor Green
Write-Host "Review everything before running any generated script." -ForegroundColor Yellow

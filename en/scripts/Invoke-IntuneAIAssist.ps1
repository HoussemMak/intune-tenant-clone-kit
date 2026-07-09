#Requires -Version 7.0
<#
.SYNOPSIS
    EXPERIMENTAL, OPT-IN AI recreation ASSISTANT for the items the kit cannot auto-import.

.DESCRIPTION
    For each MANUAL / SKIPPED item (encrypted-secret profiles, Admin Templates, Endpoint Security
    intents, or any SKIP_* row from an import log), this tool asks a CONFIGURABLE AI endpoint to draft:
      1. a short recreation guide for the target-tenant admin (portal steps), and
      2. a PowerShell + Microsoft Graph scaffold (with -WhatIf and <PLACEHOLDER> for secrets).
    Output is written to .\ai-output (a runbook + scaffold .ps1 files) for HUMAN REVIEW.

    IT NEVER WRITES TO ANY TENANT and never auto-executes anything. Goal: reduce manual portal work,
    not replace human judgement.

    PRIVACY: object METADATA is sent to the AI endpoint you configure. Secret values are redacted
    before sending. This is OPT-IN. Prefer Azure OpenAI (data stays in your tenant) over a public API.

.PARAMETER ExportPath
    Export folder produced by the kit (contains manifest.json + NN_* families).

.PARAMETER ImportLog
    (Optional) CSV log from the import engine; SKIP_* / ERROR rows drive the item list.

.PARAMETER OutputPath
    Where to write the runbook + scaffolds. Default: .\ai-output

.PARAMETER Language
    Language of the generated runbook: en | fr. Default en.

.PARAMETER MaxItems
    Safety cap on the number of items sent to the AI. Default 25.

.PARAMETER ExcludeFamilies
    Families to skip (e.g. 01_DeviceConfigurations).

.PARAMETER AssumeYes
    Skip the privacy confirmation prompt (for automation).

.NOTES
    AI settings are read from config.ps1 (git-ignored) or environment variables. The API key is NEVER
    bundled with the kit:
      $AiProvider = 'AzureOpenAI' | 'OpenAI' | 'Custom'      (env: INTUNE_AI_PROVIDER)
      $AiEndpoint = '<full chat/completions URL>'            (env: INTUNE_AI_ENDPOINT)
      $AiApiKey   = '<your key>'                             (env: INTUNE_AI_API_KEY)
      $AiModel    = '<model / deployment name>'              (env: INTUNE_AI_MODEL)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExportPath,
    [string]$ImportLog,
    [string]$OutputPath = (Join-Path (Get-Location) 'ai-output'),
    [ValidateSet('en','fr')][string]$Language = 'en',
    [int]$MaxItems = 25,
    [string[]]$ExcludeFamilies,
    [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- AI configuration (config.ps1 at the bundle root, else environment variables). Key never bundled. ---
$cfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }
$AiProvider = if ($AiProvider) { $AiProvider } elseif ($env:INTUNE_AI_PROVIDER) { $env:INTUNE_AI_PROVIDER } else { 'OpenAI' }
$AiEndpoint = if ($AiEndpoint) { $AiEndpoint } else { $env:INTUNE_AI_ENDPOINT }
$AiApiKey   = if ($AiApiKey)   { $AiApiKey }   else { $env:INTUNE_AI_API_KEY }
$AiModel    = if ($AiModel)    { $AiModel }    else { $env:INTUNE_AI_MODEL }

if (-not $AiApiKey) {
    throw "No AI API key. Set `$AiApiKey (and `$AiEndpoint / `$AiModel / `$AiProvider) in config.ps1, or the INTUNE_AI_* environment variables. The key is provided by YOU and never shipped with the kit."
}

# --- Privacy gate (opt-in) ---
Write-Host ""
Write-Host "AI RECREATION ASSISTANT (experimental)" -ForegroundColor Magenta
Write-Host "Object METADATA (secrets redacted) will be sent to: $AiProvider" -ForegroundColor Yellow
Write-Host "This tool NEVER writes to a tenant. Output is for review only." -ForegroundColor Yellow
if (-not $AssumeYes) {
    $r = Read-Host "Proceed? [y/N]"
    if ($r -notmatch '^[yYoO]') { Write-Host "Cancelled."; return }
}

# --- Redaction: strip secret values before anything leaves the machine ---
function Remove-Secrets {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string]) -and -not ($Obj -is [System.Collections.IDictionary])) {
        return @($Obj | ForEach-Object { Remove-Secrets $_ })
    }
    if ($Obj -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Obj.Keys) {
            if ($k -in 'secretReferenceValueId','value','password','omaSettingBase64','scriptContent','detectionScriptContent','remediationScriptContent') { $o[$k] = '<REDACTED>' }
            else { $o[$k] = Remove-Secrets $Obj[$k] }
        }
        return $o
    }
    return $Obj
}

# --- Provider-agnostic chat call (OpenAI-compatible) ---
function Invoke-AiChat {
    param([string]$System,[string]$User)
    $body = @{ messages = @(@{ role='system'; content=$System }, @{ role='user'; content=$User }); temperature = 0.2 }
    switch ($AiProvider) {
        'AzureOpenAI' {
            if (-not $AiEndpoint) { throw 'AzureOpenAI requires $AiEndpoint (full chat/completions URL with api-version).' }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ 'api-key' = $AiApiKey } `
                -ContentType 'application/json' -Body (($body) | ConvertTo-Json -Depth 12)
        }
        'OpenAI' {
            $body.model = if ($AiModel) { $AiModel } else { 'gpt-4.1-mini' }
            $uri = if ($AiEndpoint) { $AiEndpoint } else { 'https://api.openai.com/v1/chat/completions' }
            $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $AiApiKey" } `
                -ContentType 'application/json' -Body (($body) | ConvertTo-Json -Depth 12)
        }
        default { # Custom OpenAI-compatible endpoint
            if (-not $AiEndpoint) { throw 'Custom provider requires $AiEndpoint.' }
            if ($AiModel) { $body.model = $AiModel }
            $resp = Invoke-RestMethod -Method POST -Uri $AiEndpoint -Headers @{ Authorization = "Bearer $AiApiKey" } `
                -ContentType 'application/json' -Body (($body) | ConvertTo-Json -Depth 12)
        }
    }
    return [string]$resp.choices[0].message.content
}

# --- Build the list of MANUAL / skipped items ---
function Get-ManualItems {
    $items = @()
    if ($ImportLog -and (Test-Path -LiteralPath $ImportLog)) {
        foreach ($r in (Import-Csv -LiteralPath $ImportLog)) {
            if ($r.Status -and ($r.Status -like 'SKIP*' -or $r.Status -eq 'ERROR')) {
                $items += [pscustomobject]@{ Family=$r.Family; Name=$r.Name; Reason=($r.Reason + ' ' + $r.Error + ' ' + $r.ErrorMessage).Trim() }
            }
        }
    }
    # Fallback / complement: scan the export for known manual families.
    foreach ($fam in '01_DeviceConfigurations','14_AdminTemplates','15_EndpointSecurity') {
        if ($ExcludeFamilies -contains $fam) { continue }
        $dir = Join-Path $ExportPath $fam
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -Filter *.json -File)) {
            $o = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $isSecret = $fam -eq '01_DeviceConfigurations' -and @($o.omaSettings | Where-Object { $_.secretReferenceValueId }).Count -gt 0
            if ($fam -eq '01_DeviceConfigurations' -and -not $isSecret) { continue }  # non-secret device configs are auto-imported
            $name = if ($o.displayName) { $o.displayName } else { $o.name }
            if ($items.Name -notcontains $name) {
                $items += [pscustomobject]@{ Family=$fam; Name=$name; Reason='Manual family / not auto-importable'; _file=$f.FullName }
            }
        }
    }
    return $items | Select-Object -First $MaxItems
}

# --- Main ---
New-Item -ItemType Directory -Force -Path $OutputPath, (Join-Path $OutputPath 'scaffolds') | Out-Null
$manual = @(Get-ManualItems)
if ($manual.Count -eq 0) { Write-Host "No manual/skipped items found." -ForegroundColor Green; return }
Write-Host ("Drafting recreation help for {0} item(s)..." -f $manual.Count) -ForegroundColor Cyan

$system = @"
You are a senior Microsoft Intune and Microsoft Graph engineer. For an exported Intune object that
could NOT be auto-imported into a target tenant, write the answer in $Language and produce:
1. A concise, numbered recreation guide for the target-tenant admin (Intune portal steps).
2. A PowerShell + Microsoft Graph (Invoke-MgGraphRequest, beta) scaffold that recreates it, using
   -WhatIf where relevant and a clearly marked <PLACEHOLDER> for any secret the export does not contain.
Never invent secret values. Keep it practical and short. Return Markdown and put the script inside a
single fenced 'powershell' code block.
"@

$runbook = New-Object System.Text.StringBuilder
[void]$runbook.AppendLine("# AI recreation runbook (review before use)`n")
[void]$runbook.AppendLine("> Generated by Invoke-IntuneAIAssist.ps1. **Review every step and script before running.** Nothing here was executed against a tenant.`n")

$i = 0
foreach ($it in $manual) {
    $i++
    Write-Host ("  [{0}/{1}] {2}" -f $i, $manual.Count, $it.Name) -ForegroundColor DarkCyan
    $meta = @{ family=$it.Family; name=$it.Name; reason=$it.Reason }
    if ($it._file) { $meta.object = (Remove-Secrets (Get-Content $it._file -Raw | ConvertFrom-Json)) }
    $user = "Family: $($it.Family)`nName: $($it.Name)`nReason it was skipped: $($it.Reason)`nRedacted object metadata (JSON):`n" + ($meta | ConvertTo-Json -Depth 20)
    try {
        $answer = Invoke-AiChat -System $system -User $user
    } catch {
        [void]$runbook.AppendLine("## $($it.Name) ($($it.Family))`n_AI call failed: $($_.Exception.Message)_`n")
        continue
    }
    [void]$runbook.AppendLine("## $($it.Name)  ·  _$($it.Family)_`n")
    [void]$runbook.AppendLine($answer + "`n---`n")
    $m = [regex]::Match($answer, '(?s)```powershell(.*?)```')
    if ($m.Success) {
        $safe = ($it.Name -replace '[^\w\.\- ]','_').Trim(); if ($safe.Length -gt 60) { $safe = $safe.Substring(0,60) }
        $sf = Join-Path $OutputPath ("scaffolds\{0}.ps1" -f $safe)
        ("# REVIEW BEFORE RUNNING - AI-generated scaffold. Never run blindly against a tenant.`n" + $m.Groups[1].Value.Trim()) |
            Set-Content -LiteralPath $sf -Encoding UTF8
    }
}

$rbPath = Join-Path $OutputPath 'RUNBOOK.md'
Set-Content -LiteralPath $rbPath -Value $runbook.ToString() -Encoding UTF8
Write-Host ""
Write-Host ("Runbook : {0}" -f $rbPath) -ForegroundColor Green
Write-Host ("Scaffolds: {0}" -f (Join-Path $OutputPath 'scaffolds')) -ForegroundColor Green
Write-Host "REVIEW everything before running any generated script." -ForegroundColor Yellow

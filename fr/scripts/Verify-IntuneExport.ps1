#Requires -Version 7.0
<#
.SYNOPSIS
    Contrôle d'intégrité hors-ligne d'un export via son checksums.json (SHA-256).

.DESCRIPTION
    Détecte les fichiers MODIFIÉS, MANQUANTS ou NON SUIVIS depuis le scellement de l'export. Fonctionne
    entièrement hors-ligne (aucune connexion Graph). L'exporteur écrit checksums.json automatiquement ;
    utiliser -Write pour re-sceller un export modifié volontairement. Code de sortie 0 = OK, 1 = écarts.

.PARAMETER Path
    Le dossier d'export (contient les familles NN_* et checksums.json).

.PARAMETER Write
    (Re)génère checksums.json pour le dossier au lieu de vérifier.

.EXAMPLE
    .\Verify-IntuneExport.ps1 -Path .\input\Export_2026-07-15
    .\Verify-IntuneExport.ps1 -Path .\FixedExport -Write
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { throw "Dossier d'export introuvable : $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path
$checkFile = Join-Path $root 'checksums.json'

function Get-RelHash {
    Get-ChildItem $root -Recurse -File | Where-Object { $_.Name -ne 'checksums.json' } | ForEach-Object {
        $rel = ($_.FullName.Substring($root.Length).TrimStart('\','/')) -replace '\\','/'
        [pscustomobject]@{ Rel = $rel; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }
}

if ($Write) {
    $sums = [ordered]@{}
    Get-RelHash | Sort-Object Rel | ForEach-Object { $sums[$_.Rel] = $_.Hash }
    ($sums | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $checkFile -Encoding UTF8
    Write-Host ("Scellé : {0} fichier(s) -> checksums.json" -f $sums.Count) -ForegroundColor Green
    return
}

if (-not (Test-Path -LiteralPath $checkFile)) { throw "checksums.json introuvable dans $root. Lancer avec -Write pour le créer." }
$expected = @{}
(Get-Content -LiteralPath $checkFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $expected[$_.Name] = [string]$_.Value }
$actual = @{}
Get-RelHash | ForEach-Object { $actual[$_.Rel] = $_.Hash }

$modified = @(); $missing = @(); $untracked = @()
foreach ($rel in $expected.Keys) {
    if (-not $actual.ContainsKey($rel)) { $missing += $rel }
    elseif ($actual[$rel] -ne $expected[$rel]) { $modified += $rel }
}
foreach ($rel in $actual.Keys) { if (-not $expected.ContainsKey($rel)) { $untracked += $rel } }

Write-Host ""
Write-Host ("Vérification : {0}" -f $root) -ForegroundColor Cyan
Write-Host ("  suivis : {0} | modifiés : {1} | manquants : {2} | non suivis : {3}" -f $expected.Count, $modified.Count, $missing.Count, $untracked.Count)
foreach ($x in $modified)  { Write-Host ("  [MODIFIE]    {0}" -f $x) -ForegroundColor Yellow }
foreach ($x in $missing)   { Write-Host ("  [MANQUANT]   {0}" -f $x) -ForegroundColor Red }
foreach ($x in $untracked) { Write-Host ("  [NON SUIVI]  {0}" -f $x) -ForegroundColor Magenta }

if ($modified.Count + $missing.Count + $untracked.Count -eq 0) {
    Write-Host "  OK - intégrité de l'export vérifiée." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  Écarts détectés." -ForegroundColor Red
    exit 1
}

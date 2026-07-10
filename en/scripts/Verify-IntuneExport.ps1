#Requires -Version 7.0
<#
.SYNOPSIS
    Offline integrity check of an export against its checksums.json (SHA-256).

.DESCRIPTION
    Detects files that were MODIFIED, MISSING, or UNTRACKED since the export was sealed. Works fully
    offline (no Graph connection). The exporter writes checksums.json automatically; use -Write to
    (re)seal an export you edited on purpose. Exit code 0 = clean, 1 = differences found.

.PARAMETER Path
    The export folder (contains the NN_* families and checksums.json).

.PARAMETER Write
    (Re)generate checksums.json for the folder instead of verifying.

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
if (-not (Test-Path -LiteralPath $Path)) { throw "Export folder not found: $Path" }
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
    Write-Host ("Sealed: {0} file(s) -> checksums.json" -f $sums.Count) -ForegroundColor Green
    return
}

if (-not (Test-Path -LiteralPath $checkFile)) { throw "checksums.json not found in $root. Run with -Write to create it." }
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
Write-Host ("Verify: {0}" -f $root) -ForegroundColor Cyan
Write-Host ("  tracked: {0} | modified: {1} | missing: {2} | untracked: {3}" -f $expected.Count, $modified.Count, $missing.Count, $untracked.Count)
foreach ($x in $modified)  { Write-Host ("  [MODIFIED]  {0}" -f $x) -ForegroundColor Yellow }
foreach ($x in $missing)   { Write-Host ("  [MISSING]   {0}" -f $x) -ForegroundColor Red }
foreach ($x in $untracked) { Write-Host ("  [UNTRACKED] {0}" -f $x) -ForegroundColor Magenta }

if ($modified.Count + $missing.Count + $untracked.Count -eq 0) {
    Write-Host "  OK - export integrity verified." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  Differences found." -ForegroundColor Red
    exit 1
}

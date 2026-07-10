#Requires -Version 7.0
<#
.SYNOPSIS
    Comparaison de dérive hors-ligne entre deux exports (par objet, classée par sévérité).

.DESCRIPTION
    Fait correspondre les objets PAR NOM dans chaque famille et signale, pour chaque famille :
      ADDED    – présent dans l'export DIFFERENCE, absent du REFERENCE (sévérité : medium)
      REMOVED  – présent dans le REFERENCE, absent du DIFFERENCE (sévérité : medium)
      CHANGED  – même nom dans les deux, mais contenu différent après avoir ignoré les champs volatils (sévérité : high)
    Utile avant/après une migration, ou entre deux exports datés. Aucune connexion Graph requise.

.PARAMETER Reference
    Dossier d'export de référence (l'« avant »).

.PARAMETER Difference
    Dossier d'export à comparer à la référence (l'« après »).

.PARAMETER OutputJson
    Chemin optionnel pour écrire la comparaison complète en JSON.

.EXAMPLE
    .\Compare-IntuneExport.ps1 -Reference .\Export_old -Difference .\Export_new -OutputJson .\drift.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Reference,
    [Parameter(Mandatory)][string]$Difference,
    [string]$OutputJson
)

$ErrorActionPreference = 'Stop'
foreach ($p in $Reference, $Difference) { if (-not (Test-Path -LiteralPath $p)) { throw "Dossier introuvable : $p" } }
$refRoot = (Resolve-Path -LiteralPath $Reference).Path
$difRoot = (Resolve-Path -LiteralPath $Difference).Path

# Champs qui changent toujours et qu'il faut ignorer lors de la comparaison de contenu.
$Volatile = 'id','createdDateTime','lastModifiedDateTime','modifiedDateTime','version','settingCount','isAssigned','supportsScopeTags'

function Get-Name { param($o) if ($o.displayName) { [string]$o.displayName } elseif ($o.name) { [string]$o.name } else { $null } }
function Get-Canonical {
    param($o)
    $h = [ordered]@{}
    foreach ($p in ($o.PSObject.Properties.Name | Sort-Object)) {
        if ($Volatile -contains $p) { continue }
        $h[$p] = $o.$p
    }
    ($h | ConvertTo-Json -Depth 100 -Compress)
}
function Load-Family { param($root)
    $map = @{}
    foreach ($dir in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
        $fam = $dir.Name; $map[$fam] = @{}
        foreach ($f in (Get-ChildItem $dir.FullName -Filter *.json -File -ErrorAction SilentlyContinue)) {
            try { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $n = Get-Name $o; if ($n) { $map[$fam][$n] = (Get-Canonical $o) }
        }
    }
    return $map
}

$ref = Load-Family $refRoot
$dif = Load-Family $difRoot
$families = @($ref.Keys + $dif.Keys | Sort-Object -Unique)
$rows = @()

Write-Host ""
Write-Host ("Comparaison  REFERENCE  = {0}" -f $refRoot) -ForegroundColor Cyan
Write-Host ("             DIFFERENCE = {0}" -f $difRoot) -ForegroundColor Cyan
$tAdd=0;$tRem=0;$tChg=0
foreach ($fam in $families) {
    $r = if ($ref.ContainsKey($fam)) { $ref[$fam] } else { @{} }
    $d = if ($dif.ContainsKey($fam)) { $dif[$fam] } else { @{} }
    $added=@(); $removed=@(); $changed=@()
    foreach ($n in $d.Keys) { if (-not $r.ContainsKey($n)) { $added += $n } elseif ($r[$n] -ne $d[$n]) { $changed += $n } }
    foreach ($n in $r.Keys) { if (-not $d.ContainsKey($n)) { $removed += $n } }
    if ($added.Count + $removed.Count + $changed.Count -eq 0) { continue }
    $tAdd+=$added.Count; $tRem+=$removed.Count; $tChg+=$changed.Count
    Write-Host ("--- {0} : +{1} ajouté(s), -{2} retiré(s), ~{3} modifié(s) ---" -f $fam,$added.Count,$removed.Count,$changed.Count) -ForegroundColor White
    foreach ($n in $changed) { Write-Host ("  [MODIFIE] {0}" -f $n) -ForegroundColor Yellow;  $rows += [pscustomobject]@{ Family=$fam; Name=$n; Change='CHANGED'; Severity='high' } }
    foreach ($n in $added)   { Write-Host ("  [AJOUTE]  {0}" -f $n) -ForegroundColor Green;   $rows += [pscustomobject]@{ Family=$fam; Name=$n; Change='ADDED';   Severity='medium' } }
    foreach ($n in $removed) { Write-Host ("  [RETIRE]  {0}" -f $n) -ForegroundColor Red;     $rows += [pscustomobject]@{ Family=$fam; Name=$n; Change='REMOVED'; Severity='medium' } }
}

Write-Host ""
Write-Host ("TOTAL : {0} ajouté(s), {1} retiré(s), {2} modifié(s)" -f $tAdd,$tRem,$tChg) -ForegroundColor Magenta
if ($OutputJson) { ($rows | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $OutputJson -Encoding UTF8; Write-Host ("JSON : {0}" -f $OutputJson) -ForegroundColor Cyan }
exit ([int]($rows.Count -gt 0))

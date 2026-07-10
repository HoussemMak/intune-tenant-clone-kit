#Requires -Version 5.1
<#
  Vérification d'hygiène AVANT publication : signale les identifiants qui « ressemblent » à des
  valeurs réelles (GUID, domaines onmicrosoft, e-mails) afin que vous les revoyiez.

  Ce script ne contient AUCUNE valeur réelle et ne s'exclut PAS de l'analyse (il se vérifie lui-même).
  NB : c'est un garde-fou GÉNÉRIQUE. Il ne peut pas deviner un nom d'organisation : relisez aussi
  manuellement le dépôt pour tout terme propre à votre organisation avant de publier.

  Usage :  pwsh ./tools/check-no-secrets.ps1     (exit 1 si quelque chose est à revoir)
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$patterns = [ordered]@{
  'GUID (à vérifier)'      = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  'Domaine onmicrosoft'    = '[A-Za-z0-9-]+\.onmicrosoft\.com'
  'Adresse e-mail'         = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
}

# Valeurs manifestement fictives / placeholders -> autorisées.
$allow = @(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  '00000003-0000-0000-c000-000000000000',   # Microsoft Graph (appId public bien connu)
  '2dfaf5e5-83c3-4d11-97b5-edc8c1a1bd89',   # GUID du module IntuneTenantCloneKit (id public du manifeste)
  'source.onmicrosoft.com','target.onmicrosoft.com',
  'contoso.example.com','admin@contoso.example.com',
  'noreply@example.com'
)
# Faux positifs structurels (types/URL Graph, jamais des données d'organisation).
$ignoreLine = 'odata|microsoft\.graph|graph\.microsoft\.com'

$files = Get-ChildItem -Path $Root -Recurse -File |
  Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                 $_.Extension -notmatch '(?i)\.(png|jpe?g|gif|ico|bmp|pdf|zip|pfx|cer|p12|woff2?)$' }

$review = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
  foreach ($kv in $patterns.GetEnumerator()) {
    $m = Select-String -Path $f.FullName -Pattern $kv.Value -AllMatches -ErrorAction SilentlyContinue
    foreach ($line in $m) {
      foreach ($mm in $line.Matches) {
        $val = $mm.Value
        if ($allow -contains $val) { continue }
        if ($line.Line -match $ignoreLine) { continue }
        $review.Add([pscustomobject]@{ File=(Split-Path $f.FullName -Leaf); Line=$line.LineNumber; Type=$kv.Key; Value=$val })
      }
    }
  }
}

if ($review.Count -gt 0) {
  Write-Host "A REVOIR : valeur(s) potentiellement identifiante(s) detectee(s) :" -ForegroundColor Red
  $review | Sort-Object File,Line | ForEach-Object { Write-Host ("  {0}:{1}  [{2}]  {3}" -f $_.File,$_.Line,$_.Type,$_.Value) -ForegroundColor Yellow }
  Write-Host "Verifiez que ce sont bien des valeurs fictives avant de publier." -ForegroundColor Red
  exit 1
} else {
  Write-Host "OK : aucun identifiant suspect. (Relisez tout de meme les noms propres a votre organisation.)" -ForegroundColor Green
  exit 0
}

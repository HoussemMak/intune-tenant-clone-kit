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
  'Empreinte de certificat'= '\b[0-9A-Fa-f]{40}\b'
  'Clé privée (PEM)'       = '-----BEGIN (RSA |EC |)PRIVATE KEY-----'
  'Blob base64 PFX/cert'   = 'MII[A-Za-z0-9+/]{200,}'
  'Secret OMA (base64)'    = 'omaSettingBase64"?\s*[:=]\s*"?[A-Za-z0-9+/]{40,}'
}

# Valeurs manifestement fictives / placeholders -> autorisées.
$allow = @(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  '00000003-0000-0000-c000-000000000000',   # Microsoft Graph (appId public bien connu)
  '2dfaf5e5-83c3-4d11-97b5-edc8c1a1bd89',   # GUID du module IntuneTenantCloneKit (id public du manifeste)
  # appId Microsoft first-party bien connus + ids d'auth strength integres : CONSTANTES globales PUBLIQUES
  # (identiques dans chaque tenant, pas des secrets). Declarees dans scripts/Import-IntuneConfig_Corrige_v3.ps1.
  '00000002-0000-0ff1-ce00-000000000000','00000003-0000-0ff1-ce00-000000000000',
  '00000004-0000-0ff1-ce00-000000000000','00000005-0000-0ff1-ce00-000000000000',
  '00000006-0000-0ff1-ce00-000000000000','00000007-0000-0ff1-ce00-000000000000',
  '00000009-0000-0000-c000-000000000000','0000000a-0000-0000-c000-000000000000',
  '00000012-0000-0000-c000-000000000000','797f4846-ba00-4fd7-ba43-dac1f8f63013',
  'c44b4083-3bb0-49c1-b47d-974e53cbdf3c','1fec8e78-bce4-4aaf-ab1b-5451cc387264',
  'cc15fd57-2c6c-4117-a88c-83b1d56b4bbe','d4ebce55-015a-49b5-a083-c84d1797ae8c',
  '00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000004',
  'source.onmicrosoft.com','target.onmicrosoft.com',
  'contoso.example.com','admin@contoso.example.com',
  'noreply@example.com'
)
# Faux positifs structurels : refs @odata.*, noms de type #microsoft.graph.*, et l'hôte Graph.
# NB : on teste la VALEUR, pas la ligne entière -- un vrai GUID de tenant peut se trouver sur une
# ligne d'URL Graph et doit rester signalé ; on n'ignore que le fragment host/type structurel.
$ignoreValue = 'odata\.|microsoft\.graph\.|graph\.microsoft\.com'

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
        if ($val -match $ignoreValue) { continue }
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

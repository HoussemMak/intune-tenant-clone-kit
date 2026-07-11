#Requires -Version 5.1
<#
  Hygiene check BEFORE publishing: flags identifiers that "look like" real
  values (GUIDs, onmicrosoft domains, e-mails) so that you can review them.

  This script contains NO real value and does NOT exclude itself from the scan (it checks itself).
  NB: this is a GENERIC safeguard. It cannot guess an organization name: also review
  the repository manually for any term specific to your organization before publishing.

  Usage:  pwsh ./tools/check-no-secrets.ps1     (exit 1 if something needs review)
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$patterns = [ordered]@{
  'GUID (to review)'       = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  'onmicrosoft domain'     = '[A-Za-z0-9-]+\.onmicrosoft\.com'
  'E-mail address'         = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  'Certificate thumbprint' = '\b[0-9A-Fa-f]{40}\b'
  'Private key (PEM)'      = '-----BEGIN (RSA |EC |)PRIVATE KEY-----'
  'PFX/cert base64 blob'   = 'MII[A-Za-z0-9+/]{200,}'
  'OMA secret (base64)'    = 'omaSettingBase64"?\s*[:=]\s*"?[A-Za-z0-9+/]{40,}'
}

# Obviously fictitious values / placeholders -> allowed.
$allow = @(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  '00000003-0000-0000-c000-000000000000',   # Microsoft Graph (well-known public appId)
  '2dfaf5e5-83c3-4d11-97b5-edc8c1a1bd89',   # IntuneTenantCloneKit module GUID (public manifest id)
  # Well-known first-party Microsoft appIds + built-in auth-strength ids: PUBLIC global constants (identical
  # in every tenant, not secrets). Declared in scripts/Import-IntuneConfig_Corrige_v3.ps1 for CA pass-through.
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
# Structural false positives: @odata.* refs, #microsoft.graph.* type names, and the Graph host.
# NB: matched on the VALUE, not the whole line -- a real tenant GUID can sit on a Graph URL line
# and must still be flagged; we only skip the structural host/type fragment itself.
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
  Write-Host "TO REVIEW : potentially identifying value(s) detected :" -ForegroundColor Red
  $review | Sort-Object File,Line | ForEach-Object { Write-Host ("  {0}:{1}  [{2}]  {3}" -f $_.File,$_.Line,$_.Type,$_.Value) -ForegroundColor Yellow }
  Write-Host "Check that these are indeed fictitious values before publishing." -ForegroundColor Red
  exit 1
} else {
  Write-Host "OK : no suspicious identifier. (Still review the proper names specific to your organization.)" -ForegroundColor Green
  exit 0
}

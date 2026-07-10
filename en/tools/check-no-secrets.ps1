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
}

# Obviously fictitious values / placeholders -> allowed.
$allow = @(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  '00000003-0000-0000-c000-000000000000',   # Microsoft Graph (well-known public appId)
  '2dfaf5e5-83c3-4d11-97b5-edc8c1a1bd89',   # IntuneTenantCloneKit module GUID (public manifest id)
  'source.onmicrosoft.com','target.onmicrosoft.com',
  'contoso.example.com','admin@contoso.example.com',
  'noreply@example.com'
)
# Structural false positives (Graph types/URLs, never organization data).
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
  Write-Host "TO REVIEW : potentially identifying value(s) detected :" -ForegroundColor Red
  $review | Sort-Object File,Line | ForEach-Object { Write-Host ("  {0}:{1}  [{2}]  {3}" -f $_.File,$_.Line,$_.Type,$_.Value) -ForegroundColor Yellow }
  Write-Host "Check that these are indeed fictitious values before publishing." -ForegroundColor Red
  exit 1
} else {
  Write-Host "OK : no suspicious identifier. (Still review the proper names specific to your organization.)" -ForegroundColor Green
  exit 0
}

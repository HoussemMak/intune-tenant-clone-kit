#Requires -Version 7.0
<#
.SYNOPSIS
    EXPERIMENTAL: publish a Win32 app to the TARGET tenant from a local .intunewin file + metadata.

    ⚠️ EXPERIMENTAL — reference implementation of Microsoft's documented Win32 content-upload flow
    (create app → content version → file → Azure Storage SAS → block upload → commit with encryption
    info → set committedContentVersion). It is NOT validated against a live tenant. PREVIEW by default;
    add -Execute only on a SANDBOX tenant and review the result.

.DESCRIPTION
    App binaries (.intunewin) are never returned by the export — you must provide the file. This script
    orchestrates the upload so the admin does not click through the portal. Metadata (the win32LobApp
    JSON: install/uninstall commands, detection rules, requirements) can be an exported 09_Apps profile
    or one drafted by the AI assistant.

.PARAMETER AppMetadataJson
    Path to a JSON file describing the win32LobApp (must include @odata.type = #microsoft.graph.win32LobApp,
    displayName, publisher, installCommandLine, uninstallCommandLine, detectionRules, etc.).

.PARAMETER IntuneWinFile
    Path to the .intunewin package (produced by the Microsoft Win32 Content Prep Tool).

.PARAMETER TargetTenantId
    GUID of the TARGET tenant. Guardrail: refuses if the current Graph context is a different tenant.

.PARAMETER Execute
    Perform the real upload. Without it, PREVIEW only (no write).

.NOTES
    Requires an active Graph connection to the TARGET tenant with DeviceManagementApps.ReadWrite.All.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppMetadataJson,
    [Parameter(Mandatory)][string]$IntuneWinFile,
    [Parameter(Mandatory)][string]$TargetTenantId,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$B = 'https://graph.microsoft.com/beta'

foreach ($p in $AppMetadataJson, $IntuneWinFile) { if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" } }
$ctx = Get-MgContext
if (-not $ctx) { throw "No Graph connection. Connect to the TARGET tenant first." }
if ($ctx.TenantId -ne $TargetTenantId) { throw "GUARDRAIL: current context $($ctx.TenantId) != target $TargetTenantId." }

Write-Host ""
Write-Host "PUBLISH WIN32 APP (EXPERIMENTAL)" -ForegroundColor Magenta
if (-not $Execute) { Write-Host "PREVIEW: no write. Add -Execute on a SANDBOX tenant to upload." -ForegroundColor Yellow }

# --- 1) Read + parse the .intunewin (a zip: Metadata\Detection.xml + Contents\IntunePackage.intunewin) ---
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("intunewin_" + [guid]::NewGuid().Guid)
Expand-Archive -LiteralPath $IntuneWinFile -DestinationPath $tmp -Force
$detXml = Get-ChildItem $tmp -Recurse -Filter 'Detection.xml' | Select-Object -First 1
$encPkg = Get-ChildItem $tmp -Recurse -Filter 'IntunePackage.intunewin' | Select-Object -First 1
if (-not $detXml -or -not $encPkg) { throw 'Invalid .intunewin: Detection.xml / IntunePackage.intunewin not found.' }
[xml]$det = Get-Content $detXml.FullName -Raw
$ai = $det.ApplicationInfo
$enc = $ai.EncryptionInfo
$sizeUnenc = [int64]$ai.UnencryptedContentSize
$sizeEnc   = (Get-Item $encPkg.FullName).Length
Write-Host ("  Package: {0}  | unencrypted {1:N0} B | encrypted {2:N0} B" -f $ai.Name, $sizeUnenc, $sizeEnc) -ForegroundColor Cyan

$meta = Get-Content $AppMetadataJson -Raw | ConvertFrom-Json
$body = [ordered]@{}
foreach ($k in $meta.PSObject.Properties.Name) {
    if ($k -in 'id','createdDateTime','lastModifiedDateTime','uploadState','publishingState','isAssigned','committedContentVersion','size','dependentAppCount','supersedingAppCount','supersededAppCount','assignments') { continue }
    $body[$k] = $meta.$k
}
if (-not $body['@odata.type']) { $body['@odata.type'] = '#microsoft.graph.win32LobApp' }

if (-not $Execute) {
    Write-Host ("  Would create app '{0}' and upload {1:N0} bytes in blocks, then commit." -f $body['displayName'], $sizeEnc) -ForegroundColor Gray
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

function G { param($m,$u,$b) if ($b) { Invoke-MgGraphRequest -Method $m -Uri $u -Body ($b | ConvertTo-Json -Depth 40) -ContentType 'application/json' } else { Invoke-MgGraphRequest -Method $m -Uri $u } }
function Wait-State { param($u,$want) for ($i=0; $i -lt 60; $i++) { $r = G GET $u; if ($r.uploadState -eq $want) { return $r }; if ($r.uploadState -like '*Failed*') { throw "uploadState=$($r.uploadState)" }; Start-Sleep 5 }; throw "timeout waiting for $want" }

# --- 2) Create app, 3) content version, 4) file entry ---
$app = G POST "$B/deviceAppManagement/mobileApps" $body
Write-Host ("  [+] app created: {0}" -f $app.id) -ForegroundColor Green
$cv  = G POST "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions" @{}
$fileBody = @{ '@odata.type'='#microsoft.graph.mobileAppContentFile'; name=$ai.FileName; size=$sizeUnenc; sizeEncrypted=$sizeEnc; isDependency=$false; manifest=$null }
$file = G POST "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($cv.id)/files" $fileBody
$fileUri = "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($cv.id)/files/$($file.id)"

# --- 5) Wait for the Azure Storage SAS URI ---
$file = Wait-State $fileUri 'azureStorageUriRequestSuccess'
$sas  = $file.azureStorageUri

# --- 6) Block-upload the encrypted content to Azure Blob Storage ---
$chunk = 6MB; $stream = [IO.File]::OpenRead($encPkg.FullName); $ids = @(); $idx = 0
try {
    $buf = New-Object byte[] $chunk
    while (($read = $stream.Read($buf,0,$chunk)) -gt 0) {
        $blockId = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(('{0:D6}' -f $idx)))
        $ids += $blockId
        $data = if ($read -eq $chunk) { $buf } else { $buf[0..($read-1)] }
        Invoke-WebRequest -Method PUT -Uri ("{0}&comp=block&blockid={1}" -f $sas, [Uri]::EscapeDataString($blockId)) `
            -Headers @{ 'x-ms-blob-type'='BlockBlob' } -Body $data -ContentType 'application/octet-stream' | Out-Null
        $idx++
    }
} finally { $stream.Dispose() }
$blockList = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
Invoke-WebRequest -Method PUT -Uri ("{0}&comp=blocklist" -f $sas) -Body $blockList -ContentType 'text/plain' | Out-Null
Write-Host ("  [+] uploaded {0} block(s)" -f $ids.Count) -ForegroundColor Green

# --- 7) Commit with the encryption info from Detection.xml, 8) wait, 9) set committed version ---
$commit = @{ fileEncryptionInfo = @{
    encryptionKey        = $enc.EncryptionKey
    macKey               = $enc.MacKey
    initializationVector = $enc.InitializationVector
    mac                  = $enc.Mac
    profileIdentifier    = $enc.ProfileIdentifier
    fileDigest           = $enc.FileDigest
    fileDigestAlgorithm  = $enc.FileDigestAlgorithm } }
G POST "$fileUri/commit" $commit | Out-Null
Wait-State $fileUri 'commitFileSuccess' | Out-Null
G PATCH "$B/deviceAppManagement/mobileApps/$($app.id)" @{ '@odata.type'='#microsoft.graph.win32LobApp'; committedContentVersion=$cv.id } | Out-Null

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("  [OK] '{0}' published (app {1})." -f $body['displayName'], $app.id) -ForegroundColor Green

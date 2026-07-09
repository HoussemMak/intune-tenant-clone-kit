#Requires -Version 7.0
<#
.SYNOPSIS
    EXPÉRIMENTAL : publie une application Win32 vers le tenant CIBLE à partir d'un fichier .intunewin local + métadonnées.

    ⚠️ EXPÉRIMENTAL — implémentation de référence du flux d'envoi de contenu Win32 documenté par Microsoft
    (création de l'app → version de contenu → fichier → SAS Azure Storage → envoi par blocs → validation avec les infos
    de chiffrement → définition de committedContentVersion). Il n'est PAS validé sur un tenant réel. APERÇU par défaut ;
    ajoutez -Execute uniquement sur un tenant BAC À SABLE et vérifiez le résultat.

.DESCRIPTION
    Les binaires d'application (.intunewin) ne sont jamais renvoyés par l'export — vous devez fournir le fichier. Ce script
    orchestre l'envoi pour que l'administrateur n'ait pas à cliquer dans le portail. Les métadonnées (le JSON win32LobApp :
    commandes d'installation/désinstallation, règles de détection, prérequis) peuvent être un profil 09_Apps exporté
    ou un profil rédigé par l'assistant IA.

.PARAMETER AppMetadataJson
    Chemin d'un fichier JSON décrivant le win32LobApp (doit inclure @odata.type = #microsoft.graph.win32LobApp,
    displayName, publisher, installCommandLine, uninstallCommandLine, detectionRules, etc.).

.PARAMETER IntuneWinFile
    Chemin du package .intunewin (produit par l'outil Microsoft Win32 Content Prep Tool).

.PARAMETER TargetTenantId
    GUID du tenant CIBLE. Garde-fou : refuse si le contexte Graph actuel correspond à un autre tenant.

.PARAMETER Execute
    Effectue l'envoi réel. Sans ce paramètre, APERÇU uniquement (aucune écriture).

.NOTES
    Nécessite une connexion Graph active au tenant CIBLE avec DeviceManagementApps.ReadWrite.All.
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

foreach ($p in $AppMetadataJson, $IntuneWinFile) { if (-not (Test-Path -LiteralPath $p)) { throw "Introuvable : $p" } }
$ctx = Get-MgContext
if (-not $ctx) { throw "Aucune connexion Graph. Connectez-vous d'abord au tenant CIBLE." }
if ($ctx.TenantId -ne $TargetTenantId) { throw "GARDE-FOU : contexte actuel $($ctx.TenantId) != cible $TargetTenantId." }

Write-Host ""
Write-Host "PUBLICATION APPLICATION WIN32 (EXPÉRIMENTAL)" -ForegroundColor Magenta
if (-not $Execute) { Write-Host "APERÇU : aucune écriture. Ajoutez -Execute sur un tenant BAC À SABLE pour envoyer." -ForegroundColor Yellow }

# --- 1) Lecture + analyse du .intunewin (un zip : Metadata\Detection.xml + Contents\IntunePackage.intunewin) ---
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("intunewin_" + [guid]::NewGuid().Guid)
Expand-Archive -LiteralPath $IntuneWinFile -DestinationPath $tmp -Force
$detXml = Get-ChildItem $tmp -Recurse -Filter 'Detection.xml' | Select-Object -First 1
$encPkg = Get-ChildItem $tmp -Recurse -Filter 'IntunePackage.intunewin' | Select-Object -First 1
if (-not $detXml -or -not $encPkg) { throw 'Fichier .intunewin non valide : Detection.xml / IntunePackage.intunewin introuvable.' }
[xml]$det = Get-Content $detXml.FullName -Raw
$ai = $det.ApplicationInfo
$enc = $ai.EncryptionInfo
$sizeUnenc = [int64]$ai.UnencryptedContentSize
$sizeEnc   = (Get-Item $encPkg.FullName).Length
Write-Host ("  Package : {0}  | non chiffré {1:N0} o | chiffré {2:N0} o" -f $ai.Name, $sizeUnenc, $sizeEnc) -ForegroundColor Cyan

$meta = Get-Content $AppMetadataJson -Raw | ConvertFrom-Json
$body = [ordered]@{}
foreach ($k in $meta.PSObject.Properties.Name) {
    if ($k -in 'id','createdDateTime','lastModifiedDateTime','uploadState','publishingState','isAssigned','committedContentVersion','size','dependentAppCount','supersedingAppCount','supersededAppCount','assignments') { continue }
    $body[$k] = $meta.$k
}
if (-not $body['@odata.type']) { $body['@odata.type'] = '#microsoft.graph.win32LobApp' }

if (-not $Execute) {
    Write-Host ("  Créerait l'app '{0}' et enverrait {1:N0} octets par blocs, puis validerait." -f $body['displayName'], $sizeEnc) -ForegroundColor Gray
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

function G { param($m,$u,$b) if ($b) { Invoke-MgGraphRequest -Method $m -Uri $u -Body ($b | ConvertTo-Json -Depth 40) -ContentType 'application/json' } else { Invoke-MgGraphRequest -Method $m -Uri $u } }
function Wait-State { param($u,$want) for ($i=0; $i -lt 60; $i++) { $r = G GET $u; if ($r.uploadState -eq $want) { return $r }; if ($r.uploadState -like '*Failed*') { throw "uploadState=$($r.uploadState)" }; Start-Sleep 5 }; throw "délai d'attente dépassé pour $want" }

# --- 2) Création de l'app, 3) version de contenu, 4) entrée de fichier ---
$app = G POST "$B/deviceAppManagement/mobileApps" $body
Write-Host ("  [+] app créée : {0}" -f $app.id) -ForegroundColor Green
$cv  = G POST "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions" @{}
$fileBody = @{ '@odata.type'='#microsoft.graph.mobileAppContentFile'; name=$ai.FileName; size=$sizeUnenc; sizeEncrypted=$sizeEnc; isDependency=$false; manifest=$null }
$file = G POST "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($cv.id)/files" $fileBody
$fileUri = "$B/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp/contentVersions/$($cv.id)/files/$($file.id)"

# --- 5) Attente de l'URI SAS Azure Storage ---
$file = Wait-State $fileUri 'azureStorageUriRequestSuccess'
$sas  = $file.azureStorageUri

# --- 6) Envoi par blocs du contenu chiffré vers Azure Blob Storage ---
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
Write-Host ("  [+] {0} bloc(s) envoyé(s)" -f $ids.Count) -ForegroundColor Green

# --- 7) Validation avec les infos de chiffrement de Detection.xml, 8) attente, 9) définition de la version validée ---
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
Write-Host ("  [OK] '{0}' publiée (app {1})." -f $body['displayName'], $app.id) -ForegroundColor Green

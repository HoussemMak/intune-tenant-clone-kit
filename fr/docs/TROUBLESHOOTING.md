> [🇬🇧 English version](../../en/docs/TROUBLESHOOTING.md)

# Dépannage — signature d'erreur → cause → correctif

Toutes les signatures ci-dessous sont des messages **Microsoft Graph** (non spécifiques à une
organisation). Détails des mécanismes : [`METHODOLOGY.md`](METHODOLOGY.md).

| Signature (Graph) | Cause | Correctif |
|---|---|---|
| `Property children in payload has a value that does not match schema` | Tableau vide `children:[]` transformé en `{}` par une reconstruction d'arbre en PowerShell | Ne pas reconstruire l'arbre ; PS 7 + `ConvertFrom-Json -AsHashtable` ; préserver `[]` |
| `Property settings ... does not match schema` | Tableau `settings` mono-élément aplati en objet | Idem ; garder `settings` comme tableau même à 1 élément |
| `Property groupSettingCollectionValue / simpleSettingCollectionValue ... does not match schema` | Collections mono-élément aplaties | Idem |
| `An unexpected 'StartObject' node was found for property named 'roleScopeTagIds'` | Tableau mono `["0"]` sérialisé `{"Length":1}` | Forcer `[string[]]@(...)` ou retirer `roleScopeTagIds` (défaut `["0"]`) |
| *(politique Settings Catalog créée mais vide)* | Import « en deux temps » (`POST .../{id}/settings`) — endpoint non fonctionnel | **UN SEUL POST** avec `settings` inline |
| `DetectionScriptContent must not be null or empty` | Contenu base64 absent de l'export (endpoint liste) | Réhydrater par `GET deviceHealthScripts/{id}` |
| *(script PowerShell créé mais vide, sans erreur)* | `deviceManagementScripts` accepte un contenu vide | Réhydrater `scriptContent` par item ; refuser le POST si contenu vide |
| `... scheduledActionsForRule ... is required` (conformité) | Action de blocage manquante (souvent strippée) | Ré-exporter avec `$expand`, ou synthétiser une action `block` |
| `Property validOperatingSystemBuildRanges ... does not match schema` | Tableau vide aplati | Retirer s'il est vide, ou préserver `[]` |
| `SecretReferenceValueId invalid for create` | Pointeur de secret propre au tenant source | Retirer le pointeur, ré-injecter la valeur en clair (`getOmaSettingPlainTextValue`) ou recréer |
| `400 BadRequest` sur `targetedMobileApps` (App Config) | GUID d'app propre à la source, absent de la cible | Remapper par nom (l'app doit exister/être approuvée côté cible) |
| `403` au précontrôle des scope tags | Scope `DeviceManagementRBAC.ReadWrite.All` non consenti | Consentir le scope, ou désactiver l'import des scope tags |

## Règles générales

- Toujours en **PowerShell 7** (jamais 5.1) pour tout le pipeline.
- Toujours **aperçu (PREVIEW)** avant `-Execute`.
- Le **garde-fou tenant** doit refuser d'écrire si le contexte courant n'est pas la cible attendue.
- Nettoyer un import raté **avant** de rejouer (sinon l'« objet de même nom existe déjà » masque les
  coquilles défectueuses).

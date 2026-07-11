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

## Signaux de réconciliation & du kit

Émis par le **kit lui-même** (le rapport `reconcile.json` / `.html` / `.csv` et la console), et non
par Graph. Ils font foi sur ce qu'un run a réellement fait — inspecter `reconcile.html` en premier.
Détails : [`METHODOLOGY.md`](METHODOLOGY.md).

| Signal (kit) | Cause | Correctif |
|---|---|---|
| `[BLOCKED] ... unresolved exclusion/filter — scope would broaden` | Un **groupe d'exclusion** ou un **filtre** d'affectation n'a pu être résolu sur la cible ; `/assign` remplace tout, donc appliquer l'objet sans lui *élargirait* le périmètre (fail-closed) | Créer le groupe d'exclusion / le filtre manquant sur la cible, puis rejouer. Une exclusion/un filtre non résolu est **toujours** bloqué — `-AllowPartialInclusionsOnly` ne l'autorise **pas** |
| `[BLOCKED] ... unresolved inclusion` | Un **groupe d'inclusion** n'a aucune correspondance sur la cible ; l'objet est refusé plutôt qu'appliqué à un autre périmètre | Créer/mapper le groupe sur la cible, ou passer `-AllowPartialInclusionsOnly` pour n'appliquer que le sous-ensemble résolu (identique ou plus restreint) |
| `SKIP_UNRESOLVED_CA_REF` | Une politique d'accès conditionnel référence un objet propre au tenant (groupe / emplacement nommé / rôle) sans remap sur la cible — l'AC est remap-ou-refus | Créer et mapper l'objet référencé sur la cible, puis rejouer. Les politiques AC sont **toujours créées DÉSACTIVÉES** par conception |
| `SKIP_DUP_KEY` | Deux objets source partagent le même identityKey (le nom source sans préfixe) — le run échoue volontairement pour éviter une correspondance ambiguë | Renommer/dédupliquer côté source (ou filtrer l'export) pour que chaque identityKey soit unique, puis rejouer |
| **Code de sortie 2** + bannière rouge `SECURITY-CRITICAL NOT APPLIED` | Un objet critique pour la sécurité (Conformité / Accès conditionnel / Endpoint Security / baseline) a fini Failed / Skipped / OutOfScope, ou une AC a été créée désactivée — levé uniquement sous `-Execute` | Ouvrir `reconcile.html`, corriger la cause racine (réf manquante, scope, consentement), puis rejouer. Le code non nul est volontaire pour arrêter la CI / l'automatisation |
| L'étape IA a écrit des fichiers mais **aucun appel réseau** | `Invoke-IntuneAIAssist` a tourné en dry-run local — `-SendToProvider` n'a pas été passé (ZÉRO sortie réseau par conception) | Comportement attendu : les brouillons sont dans `ai-output/` pour relecture humaine. Ajouter `-SendToProvider` seulement pour appeler un LLM externe (les secrets sont masqués + scannés avant tout envoi) |
| Rafales `429 Too Many Requests` / `503` / `504` en charge | Throttling Graph | Aucune action — export / import / affectations / orchestrateur ré-essaient désormais automatiquement avec `Retry-After` + backoff exponentiel |
| App registration sans la permission d'accès conditionnel (`Policy.ReadWrite.ConditionalAccess`) | `New-IntuneCloneKitAppRegistration.ps1` verrouille le scope AC derrière un switch (moindre privilège) | Recréer l'app registration avec `-EnableConditionalAccess` (rôle Target), puis accorder le consentement admin |

## Règles générales

- Toujours en **PowerShell 7** (jamais 5.1) pour tout le pipeline.
- Toujours **aperçu (PREVIEW)** avant `-Execute`.
- Le **garde-fou tenant** doit refuser d'écrire si le contexte courant n'est pas la cible attendue.
- Nettoyer un import raté **avant** de rejouer (sinon l'« objet de même nom existe déjà » masque les
  coquilles défectueuses).

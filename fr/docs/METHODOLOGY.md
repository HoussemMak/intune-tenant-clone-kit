> [🇬🇧 English version](../../en/docs/METHODOLOGY.md)

# Méthodologie — cloner Intune d'un tenant à un autre

Cloner une configuration Intune n'est **pas** une copie de fichiers : c'est une **reconstruction
sémantique**. Trois classes de problèmes font échouer les approches naïves. Ce document explique
chacune et le correctif appliqué par le kit.

## 1. Corruption de sérialisation des payloads polymorphes (Settings Catalog)

**Symptôme** : à la création d'une politique Settings Catalog, Graph renvoie
`Property children / settings / groupSettingCollectionValue in payload has a value that does not match schema`
ou `An unexpected 'StartObject' node was found for property named 'roleScopeTagIds'`.

**Cause** : de nombreux scripts relisent le JSON (`ConvertFrom-Json`) puis **reconstruisent** l'arbre
d'objets récursivement avant de re-sérialiser (`ConvertTo-Json`). Or, dès qu'une fonction **retourne**
un tableau, PowerShell **l'énumère** :
- un tableau **vide** `children:[]` devient `$null` → sérialisé `{}` ;
- un tableau **mono-élément** `roleScopeTagIds:["0"]` devient un scalaire/objet → sérialisé `{"Length":1}`.

Ce comportement existe en Windows PowerShell 5.1 **et** en PowerShell 7 si l'on reconstruit l'arbre.
Passer à PS 7 ne suffit donc pas à lui seul.

**Correctif** :
1. **Ne pas reconstruire l'arbre.** Lire en table de hachage (`ConvertFrom-Json -AsHashtable`), ne
   retoucher **que** la racine et le niveau `settings[i]`, puis sérialiser.
2. Préserver **strictement** les tableaux `[]` et mono-élément (ne jamais les supprimer via un
   « remove-nulls »).
3. Créer la politique en **UN SEUL POST** avec `settings` **inline** — l'endpoint
   `POST .../configurationPolicies/{id}/settings` par réglage **n'est pas** un mécanisme de création
   valide.
4. Sur chaque `settings[i]` : retirer l'`id` du wrapper et injecter
   `"@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting"` ; conserver
   `settingInstance` **verbatim** (y compris `children:[]` vides et `*TemplateReference` nuls).

## 2. Contenus que l'export « liste » ne renvoie pas

**Symptôme** : `DetectionScriptContent must not be null or empty` (remédiations), ou des scripts créés
**vides** sans erreur (faux succès), ou une conformité refusée sur `scheduledActionsForRule`.

**Cause** : les endpoints **de liste** ne renvoient pas certains contenus. Le contenu base64 des
scripts/remédiations, les `scheduledActionsForRule` des politiques de conformité et les messages
localisés des modèles de notification ne sont retournés **que par un GET par entité** (ou via `$expand`).

**Correctif** : lors de l'export, **réhydrater par item** :
- `GET deviceManagement/deviceManagementScripts/{id}` → `scriptContent`
- `GET deviceManagement/deviceHealthScripts/{id}` → `detectionScriptContent` + `remediationScriptContent`
- `GET deviceManagement/deviceCompliancePolicies/{id}?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)`
- `GET deviceManagement/notificationMessageTemplates/{id}?$expand=localizedNotificationMessages`

> À la création, une politique de conformité **exige** au moins une `scheduledActionsForRule` avec une
> action `block`. Si l'export ne l'a pas capturée, la synthétiser à l'import.

## 3. Identifiants non portables entre tenants

**Symptôme** : `SecretReferenceValueId invalid for create`, ou `400 BadRequest` sur
`targetedMobileApps`, ou des objets orphelins qui ne ciblent rien.

**Cause** : tout identifiant émis par un tenant est **local** à ce tenant : GUID d'applications, scope
tags, pointeurs de secrets (`secretReferenceValueId`), groupes Entra, filtres. Ils ne résolvent pas
dans un autre tenant.

**Correctif** :
- **Remapper par nom** (`displayName`) : applications, scope tags, groupes, filtres. Construire les
  dépendances **avant** les objets qui les référencent.
- **Secrets** : `Intune` ne laisse jamais exporter une valeur secrète en clair. La récupérer côté
  source (`POST .../deviceConfigurations/{id}/getOmaSettingPlainTextValue`) puis la ré-injecter, en
  retirant le `secretReferenceValueId` (Intune régénère un nouveau pointeur côté cible). Sinon,
  recréation manuelle.
- **Affectations** : les importer **en dernier**, après validation des objets et des mappings.

## Ordre d'exécution recommandé

```
0. Export frais (source, lecture seule) — déjà réhydraté (§2)
1. Sauvegarde de la cible
2. (optionnel) Nettoyage d'un import précédent raté
3. Foundation : filtres, scope tags
4. Apps (Store) + construction du mapping d'AppId
5. Politiques : profils, Settings Catalog (§1), conformité (§2)
6. Scripts / remédiations (contenu réhydraté)
7. Mobile : app config (remap), app protection, notifications, autopilot
8. Groupes + affectations : remap par nom (§3)
9. Manuel : secrets, apps binaires, admin templates, endpoint security, enrollment
```

Chaque écriture se fait d'abord en **aperçu (PREVIEW)**, puis en exécution après contrôle.

> [🇬🇧 English version](../../en/docs/METHODOLOGY.md)

# Méthodologie — cloner Intune d'un tenant à un autre

Cloner une configuration Intune n'est **pas** une copie de fichiers : c'est une **reconstruction
sémantique**. Les §1 à §3 couvrent les trois classes de problèmes qui font échouer les copies
naïves ; les §4 à §8 couvrent comment le kit **prouve** ce qu'il a appliqué, refuse d'**élargir la
portée** et survit au **throttling**. Chaque section garde la même forme **symptôme → cause →
correctif**.

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

## 4. Faux succès partiel — aucune preuve de ce qui a été appliqué

**Symptôme** : un import « se termine » en vert, mais personne ne peut dire si une politique de
conformité a réellement été **créée**, a **matché** une existante, ou a été silencieusement
**ignorée**. Un relecteur qui demande « l'Accès conditionnel est-il actif sur la cible ? » n'a aucun
artefact qui fasse foi.

**Cause** : un run qui n'affiche que des lignes `created` / `exists` ne laisse aucun registre par
objet, exploitable par machine. Objets homonymes, runs préfixés et items ignorés se confondent dans
le défilement — un objet critique non appliqué ressemble en tout point à un succès.

**Correctif** : chaque import émet **`reconcile.json` + `reconcile.html` + `reconcile.csv`** à côté
du log CSV — un enregistrement par objet : **outcome** (`Matched` / `Created` / `Failed` / `Skipped`
/ `Preview` / `OutOfScope`), **reason**, **targetId**, **identityKey** et le **remap** appliqué.
- L'**`identityKey`** est la clé logique sur le nom source **non préfixé** (indépendant du backend et
  du préfixe), donc un objet reste traçable même dans un run préfixé.
- **`Matched`** et **`Created`** portent l'**id cible** — la preuve que l'objet existe sur la cible.
- Deux fichiers source revendiquant le **même `identityKey`** dans un run **échouent durement en
  `SKIP_DUP_KEY`** (pas d'écrasement silencieux d'un objet logique par un autre).
- Une famille critique (**Conformité / Accès conditionnel / Endpoint Security / baseline**) restée
  **`Failed` / `Skipped` / `OutOfScope`** — ou une politique CA **créée DÉSACTIVÉE** — déclenche la
  bannière rouge **« SECURITY-CRITICAL NOT APPLIED »** et un **code de sortie non nul** sous
  `-Execute`, pour que l'automatisation s'arrête sur un faux vert au lieu d'annoncer un succès.

## 5. Affectations qui élargissent silencieusement la portée (fail-closed)

**Symptôme** : un objet est appliqué sur la cible, mais un **groupe d'exclusion** ou un **filtre
d'affectation** dont il dépendait n'a pas pu être résolu (il n'existe pas sur la cible). L'objet
finit par cibler **plus** d'appareils/utilisateurs que sur la source.

**Cause** : un `/assign` naïf retire la cible non résolue et POSTe le reste. Retirer une **inclusion**
ne fait que réduire la portée, mais retirer une **exclusion** ou un **filtre** l'**élargit** — une
régression de portée qui passe inaperçue.

**Correctif** : la phase d'affectation est **fail-closed** ; les cibles non résolues sont suivies
séparément (inclusion / exclusion / filtre) :
- Une **exclusion ou un filtre** non résolu **BLOQUE** l'objet entier sans condition — une cible
  n'est jamais appliquée sans son filtre/exclusion.
- Une **inclusion** non résolue bloque aussi par défaut ; seul `-AllowPartialInclusionsOnly` (renommé
  depuis `-AllowPartialAssignments`) laisse passer le sous-ensemble résolu, **égal ou plus étroit**.
- Les objets bloqués sont signalés, pour que vous créiez le filtre/groupe d'exclusion manquant sur la
  cible et rejouiez.

## 6. Références d'Accès conditionnel non résolues (remap-or-refuse)

**Symptôme** : une politique d'Accès conditionnel est clonée, mais ses utilisateurs / groupes / rôles
/ apps `include`/`exclude` pointent encore vers des **GUID du tenant source** qui ne veulent rien dire
sur la cible — voire résolvent vers le *mauvais* principal.

**Cause** : les politiques CA sont des réseaux denses de références locales au tenant. Émettre un seul
id source non mappé produit une politique silencieusement mal scopée, et une politique CA active mais
fausse est plus dangereuse que pas de politique du tout.

**Correctif** : **remap-or-refuse**. Chaque référence liée au tenant est soit remappée via les maps
cibles, soit toute la politique est **refusée** (`SKIP_UNRESOLVED_CA_REF`) — un id du tenant source
n'est **jamais** émis (sauf les app ids Microsoft bien connus). Toute politique CA effectivement créée
l'est **DÉSACTIVÉE**, pour qu'un humain la relise et l'active (le rapport la marque
security-critical-not-applied jusque-là).

## 7. Throttling et erreurs serveur transitoires (429 / 503 / 504)

**Symptôme** : un export ou un import volumineux échoue en cours de route sur `429 Too Many Requests`,
`503 Service Unavailable` ou `504 Gateway Timeout`, et un run naïf remonte cela comme un **Failed**
dur sur un objet qui n'était pas réellement cassé.

**Cause** : Graph throttle les tenants à fort volume. Un simple 429 transitoire ne doit pas se lire
comme un échec au niveau objet (ni comme un faux `Skipped`) dans le rapport de réconciliation.

**Correctif** : chaque appel passe par un wrapper de retry (export / import / affectations /
orchestrateur). Sur **429/503/504**, il honore l'en-tête **`Retry-After`** quand il est présent, sinon
un **backoff exponentiel plafonné (≤ 60 s) + jitter**, puis rejoue l'appel. Toute erreur non liée au
throttling est relancée telle quelle, donc la logique fail-closed (§5–§6) reste intacte.

## 8. Objets non clonables par API — recréation manuelle assistée

**Symptôme** : certains items ne peuvent jamais être POSTés avec le bon contenu — secrets
(Wi-Fi/VPN/PFX/OMA chiffré), admin templates, intents endpoint security, config d'inscription — et
atterrissent en `MANUAL` / `SKIP_*` / `OutOfScope` dans le rapport. Les recréer à la main est lent et
sujet aux erreurs.

**Cause** : ils portent des valeurs que l'API ne rend jamais en clair, ou n'ont pas d'endpoint de
ré-import (voir §3 et la table de couverture du README). Aucun outil ne franchit ce plafond
cryptographique/API.

**Correctif** : **assistance IA opt-in et durcie**. `Invoke-IntuneAIAssist` rédige — pour les items
`MANUAL` / `SKIP_*` / secret — un **runbook + des ébauches PowerShell/Graph** (`-WhatIf`, secrets
`<PLACEHOLDER>`) dans `ai-output/` **pour relecture humaine**. Il **n'écrit jamais dans un tenant et
n'exécute jamais automatiquement**. L'envoi externe est **opt-in** via `-SendToProvider` (sans lui :
dry-run local, **zéro appel réseau**) ; les secrets sont caviardés et un **scan de secrets avant
envoi échoue durement** ; la clé d'API n'est jamais embarquée. L'humain reste dans la boucle —
l'assistant ne fait qu'ôter le coût de la page blanche.

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

Chaque écriture se fait d'abord en **aperçu (PREVIEW)**, puis en exécution après contrôle — et chaque
run émet le rapport de réconciliation (§4) comme artefact qui fait foi, la phase d'affectation étant
fail-closed (§5).

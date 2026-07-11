> [🇬🇧 English version](../en/README.md)

# intune-tenant-clone-kit

![Licence : MIT](https://img.shields.io/badge/License-MIT-green.svg) ![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white) ![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-beta-0078D4.svg) ![PRs bienvenues](https://img.shields.io/badge/PRs-welcome-brightgreen.svg) ![PSGallery](https://img.shields.io/powershellgallery/v/IntuneTenantCloneKit?logo=powershell&label=PSGallery&color=5391FE)

**Cloner la configuration Microsoft Intune d'un tenant vers un autre (SOURCE → CIBLE), de façon fiable.**

> **On clone la configuration, on guide le reste.** Ce kit duplique la
> **configuration** Intune *clonable* d'un tenant à l'autre — ce n'est **pas** une
> migration d'appareils ni d'identités : les appareils se ré-enrôlent, les secrets
> et jetons se re-jumellent (un plafond cryptographique qu'aucun outil ne franchit).

![Architecture du intune-tenant-clone-kit](../assets/architecture.png)

Ce kit corrige les pièges classiques de la duplication d'Intune entre tenants : corruption de la
sérialisation des payloads polymorphes (Settings Catalog), création atomique des politiques, actions
de conformité manquantes, contenu des scripts non exporté, et identifiants non portables entre tenants.
Surtout, **chaque import émet un rapport de réconciliation** qui dit, objet par objet, ce qui a été
appliqué — et vous alerte si un objet **sécurité-critique** ne l'a pas été.

> ⚠️ **Lire [`DISCLAIMER.md`](DISCLAIMER.md) avant toute utilisation.** Fourni « en l'état », sans garantie.
> Toujours tester sur un tenant de bac à sable. Vous êtes responsable de l'usage sur vos tenants.

---

## Ce que fait le kit

Cycle complet **export → correction → import → réconciliation**.

**Deux modes d'exécution :**
- **Manuel, pas-à-pas** — [`EXECUTER.md`](EXECUTER.md) : connexion interactive, chaque écriture en aperçu (PREVIEW) d'abord.
- **Automatisé, non-surveillé** — [`EXECUTER_AUTO.md`](EXECUTER_AUTO.md) : une seule commande
  (`Invoke-IntuneCloneKit-Unattended.ps1`), authentification **app-only par certificat**, aucun prompt,
  export → nettoyage → import → affectations → vérification → rapport HTML. Idéal en tâche planifiée.
  Le mode automatisé enchaîne l'**import** sans intervention ; il ne prétend pas gérer sans les mains
  les appareils ou les secrets (voir [`LIMITATIONS.md`](LIMITATIONS.md)).

- **Export frais** du tenant source (PowerShell 7 + Microsoft Graph SDK, endpoint `beta`), **déjà
  réhydraté** : settings du Settings Catalog, contenu base64 des scripts/remédiations, actions de
  conformité (`scheduledActionsForRule`), messages de notification.
- **Import corrigé** : POST unique avec `settings` **inline** (Settings Catalog), préservation stricte
  des tableaux `[]` / mono-élément, injection de `scheduledActionsForRule`, idempotence par nom,
  journal CSV, **aperçu (PREVIEW) par défaut**.
- **Rapport de réconciliation** à chaque exécution (voir ci-dessous) : le compte-rendu objet par objet
  de ce qui a été apparié / créé / échoué / ignoré, avec bannière **sécurité-critique**.
- **Nettoyage** optionnel d'un import précédent raté, **remap des groupes/affectations par nom**,
  garde-fou anti-écriture source (refuse d'écrire si le contexte n'est pas le tenant cible).
- **Résilience réseau** : les réponses HTTP **429 / 503 / 504** sont réessayées (respect de `Retry-After`
  + backoff exponentiel) à l'export, à l'import, aux affectations et dans l'orchestrateur.

![Comment ça marche — deux voies (export → correction → import) + piste IA](../assets/architecture-detailed.png)

## Rapport de réconciliation (le différenciateur)

Chaque import écrit, à côté du journal CSV, un triptyque **`reconcile.json` + `reconcile.html` +
`reconcile.csv`**. Objet par objet, il expose : le **résultat** (`Matched` / `Created` / `Failed` /
`Skipped` / `Preview` / `OutOfScope`), la **raison**, le `targetId`, la clé d'identité (`identityKey`,
calculée sur le nom **source non préfixé**) et le remap éventuel.

- Une famille **sécurité-critique** (Conformité / Conditional Access / Endpoint Security / *baseline*)
  laissée en `Failed` / `Skipped` / `OutOfScope` — ou une CA créée **désactivée** — déclenche une
  bannière rouge **« SECURITY-CRITICAL NOT APPLIED »** et un **code de sortie non nul** en mode `-Execute`.
- Une **clé source dupliquée** provoque un échec dur `SKIP_DUP_KEY` (jamais deux objets écrasés en silence).

**Sécurité fail-closed.** Une exclusion d'affectation ou un filtre **non résolu bloque l'objet** — jamais
d'élargissement silencieux de la portée (interrupteur `-AllowPartialInclusionsOnly`). Le garde
anti-écriture source est **paramétrique** (`-SourceTenantId` vs `-TargetTenantId`, indépendant du
manifeste, échec dur si le manifeste est manquant ou corrompu). Les **Conditional Access** suivent la règle
**remap-ou-refus** : chaque référence propre au tenant est remappée, sinon la policy est refusée
(`SKIP_UNRESOLVED_CA_REF`) — et une CA importée est **toujours créée DÉSACTIVÉE**.

**Vérification honnête.** L'orchestrateur non-surveillé **ne compare plus les compteurs** (`cible ≥ source`) :
il s'appuie sur le `reconcile.json` de chaque vague comme source de vérité, et **pagine** la sauvegarde /
vérification (plus de troncature `?$top=999`).

## Couverture

| ✅ Automatisé (réimporté) | ⏸️ Manuel |
|---|---|
| Settings Catalog, Profils de configuration, Conformité, Scripts, Remédiations, Filtres, Scope tags, Apps Store, App Config, App Protection, Autopilot, Notifications, Groupes + affectations, Windows Update (anneaux + profils Feature/Quality/Driver), Termes & conditions, Catégories d'appareils, rôles RBAC personnalisés, Conditional Access (créée désactivée) | **Exportés mais NON réimportés** (à recréer à la main, remontés `OutOfScope`) : Admin Templates (`14_`), Endpoint Security intents (`15_`), Enrollment (`16_`). |

**Non clonés (plafond cryptographique)** — aucun outil ne les fait traverser : secrets (Wi-Fi/VPN/PFX,
OMA chiffré), jetons & connecteurs Apple/Google (APNs/ADE/VPP/Managed Google Play/NDES), identités
d'appareils & empreintes matérielles Autopilot, binaires d'apps (`.intunewin`) & licences VPP/Store.

> 📌 Liste complète de ce qui n'est **pas** cloné (et comment gérer chaque élément) : [`LIMITATIONS.md`](LIMITATIONS.md).
>
> ℹ️ **Admin Templates (`14_`), Endpoint Security intents (`15_`) et Enrollment (`16_`) sont _exportés_ mais
> **ne figurent pas** dans le catalogue d'import** — le moteur d'import ne les recrée jamais ; à recréer
> manuellement dans la cible. Le **rapport de réconciliation** liste chacun de ces objets en **`OutOfScope`**
> (comptabilisés, jamais abandonnés en silence) ; un objet Endpoint Security OutOfScope — ou tout objet dont
> le nom contient *baseline* — lève en plus la bannière **sécurité-critique** (code de sortie de
> réconciliation non nul en mode `-Execute`).

![Ce qui se clone vs. ce qui se re-jumelle — en un coup d'œil](../assets/overview.png)

## Prérequis

- **PowerShell 7.4+** (obligatoire — pas Windows PowerShell 5.1).
- Module `Microsoft.Graph.Authentication`.
- Un compte administrateur sur **chaque** tenant (lecture sur la source, écriture sur la cible),
  avec consentement admin des scopes `DeviceManagement*.ReadWrite.All`.
- Pour un enregistrement d'application **au moindre privilège**, voir
  [`tools/New-IntuneCloneKitAppRegistration.ps1`](tools/New-IntuneCloneKitAppRegistration.ps1) : il
  abandonne les scopes `DeviceManagementManagedDevices.*`, crée un **certificat NON-EXPORTABLE**, et
  ne demande la portée Conditional Access que derrière `-EnableConditionalAccess`. `Group.ReadWrite.All`
  reste sur la **cible** (provisionnement d'un tenant neuf).

## Démarrage rapide

```powershell
# 1) Configurer
Copy-Item config.example.ps1 config.ps1
#    -> éditer config.ps1 : renseigner SourceTenantId / TargetTenantId / domaines

# 2) Suivre EXECUTER.md (manuel) ou EXECUTER_AUTO.md (automatisé)
```

Détails, causes racines et dépannage : [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md) · [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) · [`docs/SEQUENCE.md`](docs/SEQUENCE.md) (séquence d'exécution).

## Installer en module (PowerShell Gallery)

```powershell
Install-Module IntuneTenantCloneKit -Scope CurrentUser
Import-Module IntuneTenantCloneKit
Get-Command -Module IntuneTenantCloneKit
```

Le module embarque la **même logique** que les fichiers `scripts/`, exposée en cmdlets à verbes approuvés
(`Export-IntuneConfiguration`, `Import-IntuneConfiguration`, `Compare-IntuneExport`, `Test-IntuneExport`,
`New-IntuneAppIdMap`, `New-IntuneCloneAppRegistration`, …). Les **codes de sortie sont préservés** (un
`exit N` interne devient un `return N`) : `Test-IntuneExport` / `Compare-IntuneExport` renvoient un code
exploitable, et une cmdlet ne fait jamais sortir l'hôte PowerShell. Préférez les scripts pas-à-pas si
vous voulez lire et tracer chaque action. Voir [`../module/README.md`](../module/README.md).

## Import en une passe (`-Phase All`)

Un import `-Phase All` unique **construit automatiquement** la carte d'ids d'apps *source → cible* après
la vague *Apps*, puis remappe les références (`targetedMobileApps`, …). Une app **non mappée** devient
`SKIP_UNMAPPED` — jamais un GUID source n'est POSTé sur la cible.

## Assistant IA (optionnel, expérimental, renforcé)

Pour les éléments non importables automatiquement — items **MANUAL / SKIP_\* / à secret** (voir
[`LIMITATIONS.md`](LIMITATIONS.md)) — [`scripts/Invoke-IntuneAIAssist.ps1`](scripts/Invoke-IntuneAIAssist.ps1)
rédige un **runbook de recréation + des scaffolds PowerShell/Graph** (avec `-WhatIf` et secrets en
`<PLACEHOLDER>`) dans `ai-output/`, pour **revue humaine**. Il **n'écrit jamais dans un tenant** et
**n'exécute jamais** rien tout seul.

- **Par défaut : dry-run local, ZÉRO appel réseau.** L'envoi externe est **opt-in** via `-SendToProvider`.
- Les valeurs secrètes sont **expurgées**, et un **scan de secrets pré-envoi** échoue en dur s'il en trouve.
- Préférez **Azure OpenAI** (données dans votre périmètre). La clé API est **la vôtre** (dans `config.ps1`,
  gitignoré, ou variables d'environnement `INTUNE_AI_*`) et n'est **jamais** livrée avec le kit.

## Helpers avancés (optionnels)

- **`scripts/Recover-IntuneOmaSecrets.ps1`** — récupère la valeur en clair des secrets OMA-URI chiffrés
  depuis la source et la ré-injecte dans l'export (aussi `-RecoverSecrets` de l'orchestrateur), pour que
  ces profils s'importent automatiquement. Nécessite les droits de lecture source ; écrit du clair sur
  le disque — à protéger.
- **`scripts/Publish-IntuneApp.ps1`** *(expérimental)* — orchestre l'upload d'une app Win32 `.intunewin`
  depuis un binaire local + métadonnées (création app → content version → SAS → upload par blocs → commit).
- **`scripts/Invoke-IntunePortalCaptureToScript.ps1`** — transforme une capture portail (Device Inventory,
  endpoints gatés) en script de recréation rédigé par l'IA (revue d'abord).

- **`scripts/Verify-IntuneExport.ps1`** — contrôle d'intégrité hors-ligne d'un export (`checksums.json` SHA-256) : signale les fichiers modifiés / manquants / non suivis.
- **`scripts/Compare-IntuneExport.ps1`** — comparaison de dérive entre deux exports (ajouté / retiré / modifié par objet, classé par sévérité).

## Structure

```
fr/
├── README.md
├── EXECUTER.md                         # mode manuel : étape → commande
├── EXECUTER_AUTO.md                    # mode automatisé : une seule commande
├── DISCLAIMER.md
├── Invoke-IntuneCloneKit-Unattended.ps1 # orchestrateur non-surveillé (app-only certificat)
├── config.example.ps1                  # à copier en config.ps1 (gitignoré)
├── FR.png                              # ancien schéma (l'en-tête utilise ../assets/architecture.png)
├── scripts/                            # moteur d'import corrigé, exporteur, cleanup, remap, affectations
├── docs/                               # méthodologie + dépannage
├── sample/                             # mini-export SYNTHÉTIQUE (structure attendue)
└── tools/                              # New-IntuneCloneKitAppRegistration.ps1, check-no-secrets.ps1
```

## Sécurité & données

Ce bundle **ne contient aucune donnée réelle de tenant**. Les vraies données générées à l'exécution
(`input/`, `output/`, `logs/`, `backup_*`, `config.ps1`) sont **ignorées par git**. Le script
[`tools/check-no-secrets.ps1`](tools/check-no-secrets.ps1) vérifie l'absence d'identifiants sensibles.

## Licence

[MIT](../LICENSE).
</content>
</invoke>

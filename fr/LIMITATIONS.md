> [🇬🇧 English version](../en/LIMITATIONS.md)

# Limitations

Ce kit clone **la majorité** d'une configuration Intune, mais certains types d'objets ne peuvent pas
être exportés ou recréés automatiquement — soit à cause de contraintes de la plateforme Microsoft
Graph / Intune, soit parce qu'ils portent des données non transférables entre tenants. Traitez les
éléments ci-dessous **manuellement** dans le tenant cible.

> ### Clone, pas migration
>
> Ce kit **duplique la configuration Intune _clonable_** d'un tenant vers un autre. Ce n'est **pas** une
> *migration* d'appareils, d'identités ni de tenant complet : sur la cible, les appareils **se ré-inscrivent**
> et les secrets & tokens **se ré-appairent**. Cette frontière est un **plafond cryptographique qu'aucun outil
> ne franchit** — ce n'est pas une lacune de celui-ci. Trois catégories honnêtes :
>
> 1. **Cloné automatiquement** — ~20 familles de configuration sont exportées *et* réimportées (tableau de
>    couverture dans [`README.md`](README.md)).
> 2. **Importé (expérimental), ou recréé à la main** — Modèles d'administration (ADMX) et configurations
>    d'inscription (Enrollment) sont désormais réimportés par un moteur **expérimental, fail-closed et en
>    PREVIEW par défaut** (nouveau en v2.3.0 — voir le caveat plus bas) ; les **intents Endpoint Security
>    legacy** restent manuels (l'API `intents` est gelée — l'Endpoint Security moderne se clone déjà via la
>    famille Settings Catalog). Tout ce qui n'est pas recréé est remonté par le rapport de réconciliation en
>    **`OutOfScope`**, donc rien n'est abandonné en silence.
> 3. **Jamais franchi — le plafond cryptographique** — secrets chiffrés (l'export ne porte jamais la valeur en
>    clair), tokens & connecteurs tiers (APNs / Apple ADE·VPP / Managed Google Play / NDES), identités
>    d'appareils & hashes matériels Autopilot, et binaires d'apps & licences store/VPP.
>
> **On clone la configuration, on guide le reste.** Pour les catégories 2 et 3, l'assistant IA opt-in
> ([`Invoke-IntuneAIAssist.ps1`](scripts/Invoke-IntuneAIAssist.ps1)) rédige un **runbook de recréation +
> des squelettes PowerShell/Graph** dans `ai-output/` pour relecture humaine — il **absorbe la corvée
> manuelle, pas le plafond cryptographique** : il n'écrit jamais dans un tenant, n'exécute jamais rien
> automatiquement, et caviarde les secrets avant tout appel réseau (opt-in).

![Ce qui se clone vs. ce qui se ré-appaire](../assets/overview.png)

## Non exportés / non clonés par le kit

| Type d'objet | Pourquoi | Que faire |
|---|---|---|
| **Device Inventory policies** (la nouvelle configuration *« collecte d'inventaire »* / properties catalog) | Ces politiques **ne sont pas renvoyées par les endpoints de configuration `deviceManagement` standards** énumérés par le kit, et **ne sont pas exportables avec un token Microsoft Graph classique** — le portail Intune utilise un token séparé/interne pour elles. | Recréer manuellement — ou `Invoke-IntunePortalCaptureToScript.ps1` transforme une capture portail en script de recréation rédigé par l'IA. |
| **Secrets chiffrés** (Wi-Fi/PSK, VPN, OMA-URI personnalisé avec `secretReferenceValueId`, blobs AppLocker/WDAC) | Intune n'exporte jamais une valeur secrète en clair ; le pointeur de référence est propre au tenant. | `Recover-IntuneOmaSecrets.ps1` (ou `-RecoverSecrets` de l'orchestrateur) récupère le clair depuis la source et le ré-injecte — sans re-saisie (droits de lecture source requis) ; sinon recréer et re-saisir le secret. |
| **Apps LOB / Win32 / VPP** | Le binaire d'installation (`.intunewin`, package, token VPP) ne fait pas partie des métadonnées JSON exportées. | Fournir le binaire ; `Publish-IntuneApp.ps1` (expérimental) orchestre l'upload Win32 `.intunewin`, puis remapper les affectations. |

## Importé — EXPÉRIMENTAL (Modèles d'administration & Enrollment)

> 🧪 **EXPÉRIMENTAL — lancer d'abord en PREVIEW.** Nouveaux en **v2.3.0**, les imports des Modèles
> d'administration (ADMX) et des configurations d'inscription (Enrollment) **n'ont pas été validés par les
> mainteneurs sur un vrai tenant.** **Lancez-les d'abord en mode PREVIEW, testez sur un tenant sandbox, puis
> [ouvrez une issue de retour](https://github.com/HoussemMak/intune-tenant-clone-kit/issues).** Les deux
> chemins sont **fail-closed** et en **PREVIEW par défaut** : tout cas non résolu ou ambigu est **ignoré,
> jamais deviné**. Ce n'est toujours **pas** une « migration complète » — le positionnement honnête est
> inchangé.

Depuis la **v2.3.0**, deux familles jusqu'ici export-only sont désormais recréées par le moteur d'import —
mais de façon **expérimentale** (voir le caveat ci-dessus). C'est une recréation best-effort,
**skip-and-flag**, et chaque objet ignoré reste remonté par le rapport de réconciliation en **`OutOfScope`**.

| Type d'objet | Dossier d'export | Ce qui est importé | Ce qui est ignoré (fail-closed) |
|---|---|---|---|
| **Modèles d'administration (ADMX)** (`groupPolicyConfigurations`) | `14_AdminTemplates` | Chaque politique est recréée en remappant ses **références de définition / présentation par attributs** (nom, classe, chemin de catégorie) d'un tenant à l'autre plutôt que par ID propre au tenant. | Toute valeur dont la définition ou la présentation ne peut être résolue **sans ambiguïté** sur la cible est refusée en **`SKIP_UNRESOLVED_DEF`** — jamais écrite à l'aveugle avec un ID deviné. |
| **Configurations d'inscription (Enrollment)** (`deviceEnrollmentConfigurations`) | `16_Enrollment` | Seuls les profils **créables et ciblés** : page de statut d'inscription (ESP), limite d'appareils, restriction d'inscription mono-plateforme, et notifications. Les **priorités cibles existantes ne sont jamais réordonnées**. | Les **défauts** du tenant, les objets **priority-0** et **singletons** (Windows Hello, co-management, windows-restore) sont **ignorés** ; une **restriction de plateforme legacy combinée** est ignorée en **`SKIP_FLAG_REVIEW`** (remontée sécurité-critique pour relecture humaine). |

## Exportés, mais NON réimportés automatiquement (réimport manuel)

La famille ci-dessous **est bien capturée par l'export**, mais **ne figure pas dans le catalogue
d'import** (`$Catalog`) : le moteur d'import ne la recrée donc jamais — à recréer à la main dans le tenant
cible. Elle n'est **pas** « absente » de votre export : le **rapport de réconciliation**
(`reconcile.json` / `.html` / `.csv`) liste chacun de ces objets avec l'issue **`OutOfScope`** (comptabilisés,
jamais abandonnés en silence). Un objet **Endpoint Security** OutOfScope — ou tout objet dont le nom contient
*baseline* — lève en plus la bannière **SÉCURITÉ-CRITIQUE** et, en mode `-Execute`, force un code de sortie de
réconciliation non nul : une politique critique n'est jamais confondue avec un « tout va bien ».

| Type d'objet | Dossier d'export | Pourquoi non réimporté | Que faire |
|---|---|---|---|
| **Endpoint Security (intents / baselines)** (legacy) | `15_EndpointSecurity` | L'API legacy `intents` est **gelée par Microsoft (~2025-03)** et absente du catalogue d'import. L'Endpoint Security **moderne** se clone déjà via la famille **Settings Catalog** (`02_`) ; seuls les intents legacy restent manuels. | Recréer les intents legacy au portail (ou les migrer vers le Settings Catalog). Listé `OutOfScope` ; les baselines sont en plus signalées sécurité-critique. |

> 🤖 Cette famille encore manuelle — plus les éléments de la catégorie 3 ci-dessus — est précisément le **gap
> manuel** que vise l'assistant IA opt-in : pointez `Invoke-IntuneAIAssist.ps1` sur l'export pour obtenir un
> runbook de recréation relu-avant-usage + des squelettes Graph dans `ai-output/`. Il absorbe la corvée
> (rédige les étapes et les scripts) — il n'écrit jamais dans votre tenant.

## Autres types de configuration non clonés

Le kit énumère un ensemble fixe d'endpoints Intune ; tout ce qui est en dehors n'est pas exporté :

- **Règles de nettoyage d'appareils**.
- **Attributions de rôles RBAC** et **définitions de rôles intégrées** (les *définitions* de rôles
  personnalisés sont clonées ; les rôles intégrés et les *attributions* — qui détient un rôle — non).
- **Personnalisation / Company branding / Organizational messages**.
- **Tokens d'inscription & connecteurs tiers** — Apple **ADE/VPP** & le certificat push **APNs**,
  **Managed Google Play** / Android Enterprise, et **connecteurs PKI / NDES / certificat** : secrets ou
  infrastructure qui **se ré-appairent** sur le tenant cible (le plafond cryptographique), non transférables.

À recréer au portail, ou à traiter avec un outil dédié.

## Hors périmètre par nature

- **Conditional Access** — exporté/importé **best-effort** : chaque politique est **créée DÉSACTIVÉE**. Ses références (utilisateurs, groupes, rôles, apps, emplacements nommés, service principals, conditions d'utilisation, authentication strength) sont **remappées vers le tenant cible** ; toute référence non résolvable fait **refuser la politique entière (fail-closed)** au lieu d'émettre un ID du tenant source. **À relire et activer manuellement.** Le scope CA est **opt-in** : l'outil d'app-registration accorde `Policy.ReadWrite.ConditionalAccess` uniquement avec **`-EnableConditionalAccess`**.
- **Appareils, utilisateurs, hashes matériels Autopilot, rapports / données d'inventaire** — données
  d'exécution, pas de la configuration (les appareils **se ré-inscrivent** sur la cible ; les hashes
  Autopilot sont re-collectés depuis le matériel lui-même).

## Gérés, mais dépendants du tenant

- **Groupes, filtres, scope tags, ID d'apps** sont **remappés par nom** — les objets cibles doivent
  déjà exister (ou être créés) au préalable ; les références non résolues sont journalisées et ignorées.
  **Les filtres d'affectation ne sont pas recréés** : une affectation filtrée dont le filtre est absent
  de la cible est **bloquée** (jamais appliquée sans son filtre), pas élargie en silence.
- **Apps Managed Google Play / VPP** doivent être approuvées et synchronisées dans le tenant cible
  avant que leurs app configurations ne s'appliquent.
- **Données d'inventaire / rapports** = télémétrie d'exécution, pas de la configuration — hors périmètre.
  Ce kit clone la **configuration**, pas les données des appareils.

## Remerciements

Merci à **Rudy Ooms** — Microsoft MVP, [call4cloud.nl](https://call4cloud.nl) — d'avoir signalé la
limitation des Device Inventory policies.

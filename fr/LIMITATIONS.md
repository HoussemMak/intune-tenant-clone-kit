> [🇬🇧 English version](../en/LIMITATIONS.md)

# Limitations

Ce kit clone **la majorité** d'une configuration Intune, mais certains types d'objets ne peuvent pas
être exportés ou recréés automatiquement — soit à cause de contraintes de la plateforme Microsoft
Graph / Intune, soit parce qu'ils portent des données non transférables entre tenants. Traitez les
éléments ci-dessous **manuellement** dans le tenant cible.

## Non exportés / non clonés par le kit

| Type d'objet | Pourquoi | Que faire |
|---|---|---|
| **Device Inventory policies** (la nouvelle configuration *« collecte d'inventaire »* / properties catalog) | Ces politiques **ne sont pas renvoyées par les endpoints de configuration `deviceManagement` standards** énumérés par le kit, et **ne sont pas exportables avec un token Microsoft Graph classique** — le portail Intune utilise un token séparé/interne pour elles. | Recréer manuellement — ou `Invoke-IntunePortalCaptureToScript.ps1` transforme une capture portail en script de recréation rédigé par l'IA. |
| **Secrets chiffrés** (Wi-Fi/PSK, VPN, OMA-URI personnalisé avec `secretReferenceValueId`, blobs AppLocker/WDAC) | Intune n'exporte jamais une valeur secrète en clair ; le pointeur de référence est propre au tenant. | `Recover-IntuneOmaSecrets.ps1` (ou `-RecoverSecrets` de l'orchestrateur) récupère le clair depuis la source et le ré-injecte — sans re-saisie (droits de lecture source requis) ; sinon recréer et re-saisir le secret. |
| **Apps LOB / Win32 / VPP** | Le binaire d'installation (`.intunewin`, package, token VPP) ne fait pas partie des métadonnées JSON exportées. | Fournir le binaire ; `Publish-IntuneApp.ps1` (expérimental) orchestre l'upload Win32 `.intunewin`, puis remapper les affectations. |
| **Modèles d'administration (ADMX)** | Non gérés par le moteur Settings Catalog. | Recréer au portail (ou migrer vers le Settings Catalog). |
| **Endpoint Security (intents)** | Le modèle de templates `intents` n'est pas couvert. | Recréer au portail. |
| **Configurations d'inscription (Enrollment)** | Restrictions / pages de statut d'inscription propres au tenant. | Recréer au portail. |

## Autres types de configuration non clonés

Le kit énumère un ensemble fixe d'endpoints Intune ; tout ce qui est en dehors n'est pas exporté :

- **Règles de nettoyage d'appareils**.
- **Attributions de rôles RBAC** et **définitions de rôles intégrées** (les *définitions* de rôles
  personnalisés sont clonées ; les rôles intégrés et les *attributions* — qui détient un rôle — non).
- **Personnalisation / Company branding / Organizational messages**.
- **Tokens d'inscription** (Apple ADE/VPP, Android Enterprise) et **connecteurs PKI / certificat** —
  secrets ou infrastructure, non transférables entre tenants.

À recréer au portail, ou à traiter avec un outil dédié.

## Hors périmètre par nature

- **Conditional Access** — désormais exporté/importé **best-effort** : chaque politique est **créée DÉSACTIVÉE**, et ses références (utilisateurs, groupes, apps, emplacements nommés) sont des **IDs du tenant source à remapper** avant activation. Nécessite `Policy.Read.All` / `Policy.ReadWrite.ConditionalAccess`.
- **Appareils, utilisateurs, hashes matériels Autopilot, rapports / données d'inventaire** — données
  d'exécution, pas de la configuration.

## Gérés, mais dépendants du tenant

- **Groupes, filtres, scope tags, ID d'apps** sont **remappés par nom** — les objets cibles doivent
  déjà exister (ou être créés) au préalable ; les références non résolues sont journalisées et ignorées.
- **Apps Managed Google Play / VPP** doivent être approuvées et synchronisées dans le tenant cible
  avant que leurs app configurations ne s'appliquent.
- **Données d'inventaire / rapports** = télémétrie d'exécution, pas de la configuration — hors périmètre.
  Ce kit clone la **configuration**, pas les données des appareils.

## Remerciements

Merci à **Rudy Ooms** — Microsoft MVP, [call4cloud.nl](https://call4cloud.nl) — d'avoir signalé la
limitation des Device Inventory policies.

> [🇬🇧 English version](../en/LIMITATIONS.md)

# Limitations

Ce kit clone **la majorité** d'une configuration Intune, mais certains types d'objets ne peuvent pas
être exportés ou recréés automatiquement — soit à cause de contraintes de la plateforme Microsoft
Graph / Intune, soit parce qu'ils portent des données non transférables entre tenants. Traitez les
éléments ci-dessous **manuellement** dans le tenant cible.

## Non exportés / non clonés par le kit

| Type d'objet | Pourquoi | Que faire |
|---|---|---|
| **Device Inventory policies** (la nouvelle configuration *« collecte d'inventaire »* / properties catalog) | Ces politiques **ne sont pas renvoyées par les endpoints de configuration `deviceManagement` standards** énumérés par le kit, et **ne sont pas exportables avec un token Microsoft Graph classique** — le portail Intune utilise un token séparé/interne pour elles. | Les recréer manuellement dans le tenant cible. |
| **Secrets chiffrés** (Wi-Fi/PSK, VPN, OMA-URI personnalisé avec `secretReferenceValueId`, blobs AppLocker/WDAC) | Intune n'exporte jamais une valeur secrète en clair ; le pointeur de référence est propre au tenant. | Recréer le profil et re-saisir la valeur secrète. |
| **Apps LOB / Win32 / VPP** | Le binaire d'installation (`.intunewin`, package, token VPP) ne fait pas partie des métadonnées JSON exportées. | Re-téléverser le binaire, puis remapper les affectations. |
| **Modèles d'administration (ADMX)** | Non gérés par le moteur Settings Catalog. | Recréer au portail (ou migrer vers le Settings Catalog). |
| **Endpoint Security (intents)** | Le modèle de templates `intents` n'est pas couvert. | Recréer au portail. |
| **Configurations d'inscription (Enrollment)** | Restrictions / pages de statut d'inscription propres au tenant. | Recréer au portail. |

## Autres types de configuration non clonés

Le kit énumère un ensemble fixe d'endpoints Intune ; tout ce qui est en dehors n'est pas exporté :

- **Windows Update** — les anneaux de mise à jour sont clonés, mais **pas les profils Feature / Quality /
  Driver update** (`windowsFeatureUpdateProfiles`, `windowsQualityUpdateProfiles`, `windowsDriverUpdateProfiles`).
- **Termes et conditions**, **Catégories d'appareils**, **Règles de nettoyage d'appareils**.
- **Définitions de rôles RBAC** (seuls les *scope tags* sont gérés).
- **Personnalisation / Company branding / Organizational messages**.
- **Tokens d'inscription** (Apple ADE/VPP, Android Enterprise) et **connecteurs PKI / certificat** —
  secrets ou infrastructure, non transférables entre tenants.

À recréer au portail, ou à traiter avec un outil dédié.

## Hors périmètre par nature

- Politiques **Conditional Access** — elles relèvent de **Microsoft Entra ID**, pas d'Intune.
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

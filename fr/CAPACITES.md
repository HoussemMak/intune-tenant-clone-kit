> [🇬🇧 English version](../en/CAPABILITIES.md)

# IntuneTenantCloneKit — Ce que l'outil fait (et ne fait pas)

> Positionnement honnête : l'outil **duplique la configuration clonable** ; ce **n'est pas** une migration
> d'appareils ni d'identités. Reflète l'état **v2.3.0**.

## En bref

**IntuneTenantCloneKit** reconstruit la **configuration** Intune d'un tenant dans un autre (SOURCE → CIBLE)
en quelques minutes au lieu de semaines — avec **remap automatique des groupes et filtres**, une **preuve
objet-par-objet** de ce qui a atterri, et un **assistant IA** qui génère les runbooks/scripts pour le reste
manuel. **Ce n'est pas une migration d'appareils ni d'identités** : ceux-ci se re-fabriquent côté cible.

> 💡 **Distinction clé.** Une *migration* déplace l'**état** (appareils, identités, jetons, licences). Le kit
> duplique la **configuration** (la forme des politiques). L'état, les secrets et les liens de confiance se
> **re-créent** — c'est un plafond **cryptographique**, qu'**aucun outil** (nous, la concurrence, ni le natif
> Microsoft) ne franchit.

## Légende des statuts

| Icône | Statut | Signification |
|:---:|---|---|
| ✅ | **Automatisé** | Cloné fidèlement par l'outil (après remap groupes/filtres). |
| 🟡 | **Partiel** | Structure clonée mais amputée (secret/binaire absent, créé désactivé, à compléter). |
| 🟠 | **Manuel — assisté IA** | Pas cloné automatiquement ; l'**assistant IA** génère le runbook + les scripts (revue humaine) pour le refaire. |
| ❌ | **Hors de portée** | Plafond cryptographique/physique ; se **re-fabrique** côté admin. Aucun outil ne le franchit. |

## Tableau de couverture — tous les éléments de la « migration »

### 🧩 Profils de configuration
| Élément | Statut | Détail |
|---|:---:|---|
| Settings Catalog (`configurationPolicies`) | ✅ | Réglages postés *inline*, arbre préservé verbatim. |
| Profils classiques (`deviceConfigurations`, OMA-URI) | 🟡 | Clonés ; un OMA-URI à **secret chiffré** est ignoré (secret à ressaisir). |
| Administrative Templates / ADMX | ✅ *(v2.3.0, expérimental)* | Définitions/présentations remappées **par attributs** ; valeur non résolue = ignorée (fail-closed). |
| App Configuration (ACP) | 🟡 | Remap de l'app cible requis, sinon ignoré. |

### 🛡️ Conformité
| Élément | Statut | Détail |
|---|:---:|---|
| Compliance policies | 🟡 | Clonées ; une action de blocage par défaut peut être **injectée** si absente (à vérifier avant activation). |
| Notification templates | ✅ | Messages localisés inclus. |
| Compliance scripts (custom) | 🟠 | Pas encore automatisé (roadmap) — recréation assistée IA. |

### 🔒 Endpoint Security
| Élément | Statut | Détail |
|---|:---:|---|
| Endpoint Security **moderne** (`configurationPolicies`) | ✅ | Passe par le Settings Catalog. |
| Endpoint Security **legacy** (`intents`) | 🟠 | API **gelée** par Microsoft (~2025) ; recréation manuelle/IA en Settings Catalog. |
| Security baselines | 🟠 | Versionnées / gelées ; semi-manuel. |

### 📱 Applications
| Élément | Statut | Détail |
|---|:---:|---|
| Apps du Store / winGet (métadonnées) | ✅ | Clonées. |
| Win32 / LOB / VPP / Managed Google Play | 🟡 → ❌ | Métadonnées clonables ; **binaire `.intunewin` et licences = hors de portée** (re-upload + rachat). |
| App Protection / MAM | ✅ | Cloné. |

### 📜 Scripts & remédiations
| Élément | Statut | Détail |
|---|:---:|---|
| Scripts PowerShell / Shell (macOS) | ✅ | Contenu réhydraté. |
| Remediations (proactives) | ✅ | Cloné. |
| Custom attributes (macOS) | 🟠 | Pas encore automatisé (roadmap). |

### 🔄 Mises à jour Windows
| Élément | Statut | Détail |
|---|:---:|---|
| Update rings | ✅ | Cloné. |
| Feature / Quality / Driver update profiles | ✅ | Cloné. |
| Quality update policies (expedite / hotpatch) | 🟠 | Pas encore automatisé (roadmap). |

### 🖥️ Inscription (Enrollment)
| Élément | Statut | Détail |
|---|:---:|---|
| ESP, limite d'appareils, restriction mono-plateforme, notifications | 🟡 *(v2.3.0, expérimental)* | Créés ; **fail-closed**. |
| Défauts tenant / Windows Hello / co-management (singletons) | 🟠 | Non dupliqués (priorités/singletons) ; à configurer côté cible. |
| Apple ADE/DEP, Android COBO | ❌ | Jetons d'appairage. |

### 🔐 Certificats & réseau
| Élément | Statut | Détail |
|---|:---:|---|
| Trusted Root (certificat public) | 🟡 | Cloné (partie publique). |
| SCEP / PKCS / VPN / Wi-Fi (PSK) | 🟡 → ❌ | Coquille clonée ; **secret + connecteur = hors de portée** (ressaisie + ré-appairage NDES). |

### 🚪 Accès conditionnel (Entra, lié)
| Élément | Statut | Détail |
|---|:---:|---|
| Conditional Access policies | 🟡 | Créées **désactivées**, références remappées-ou-refusées, **activation manuelle**. |
| Named locations / Authentication strength / Terms of Use | 🟠 | Pas encore exportés/importés (roadmap) ; bloquent certaines CA. |

### 👤 RBAC
| Élément | Statut | Détail |
|---|:---:|---|
| Rôles custom + scope tags | ✅ | Clonés (rôles intégrés ignorés). |
| Role assignments | 🟠 | Membres/SP = références d'identité (semi-manuel). |

### ⚙️ Administration du tenant
| Élément | Statut | Détail |
|---|:---:|---|
| Terms & Conditions (inscription) | ✅ | Cloné. |
| Device categories | ✅ | Cloné. |
| Branding / Company Portal | 🟠 | Pas encore automatisé (roadmap). |
| Connecteurs / partenaires (MTD…) | ❌ | Appairage. |

### 🎯 Affectations
| Élément | Statut | Détail |
|---|:---:|---|
| Groupes (recréés par nom) + affectations | ✅ | Remap par nom ; groupes manquants recréés ; **fail-closed** (exclusion/filtre non résolu = bloqué, jamais élargi). |
| Filtres d'affectation | 🟡 | Remappés par nom ; non auto-recréés dans certains flux. |

### 🚫 État & identité — le plafond (se re-fabrique, aucun outil ne clone)
| Élément | Statut | Détail |
|---|:---:|---|
| Appareils enrôlés / hash Autopilot | ❌ | Identité **scellée au tenant** → ré-enrôlement physique. |
| Utilisateurs / groupes (identités Entra) | ❌ | À re-provisionner / re-synchroniser. |
| Secrets (Wi-Fi/VPN/PFX/OMA) | ❌ | Chiffrés par design → ressaisie manuelle. |
| Jetons & connecteurs (APNs/ADE/VPP/MGP/NDES) | ❌ | Ré-appairage. |
| Binaires d'apps & licences | ❌ | Re-package (Content Prep Tool) + rachat. |

## Ce qui rend l'outil unique

- 🧾 **La preuve.** Chaque exécution produit un **rapport de réconciliation objet-par-objet** (JSON + HTML) :
  ce qui a atterri, ce qui a échoué, pourquoi. Une politique de sécurité non appliquée → alerte rouge + code
  de sortie non nul.
- 🔒 **Sécurité fail-closed.** Une exclusion non résolue **bloque** l'objet (jamais d'élargissement silencieux) ;
  jamais d'écriture dans le tenant source ; secrets jamais exfiltrés ; app-only, moindre privilège.
- 🤖 **Assistant IA pour le reste (opt-in).** Pour tout ce qui est 🟠, l'IA génère les **runbooks + scripts**
  PowerShell/Graph (revue humaine) — elle **guide**, elle ne migre rien à ta place.

## Ce qui reste toujours manuel (le plafond, résumé)
Ré-saisie des **secrets** · ré-appairage des **jetons/connecteurs** (Apple/Google/PKI) · ré-enrôlement des
**appareils** · re-upload des **binaires** + rachat des **licences** · recâblage des **références Entra**.

## Disclaimers
- **Aucun appareil migré** ; ré-enrôlement requis. · **Secrets non transférés** (ressaisie). · **Conditional
  Access créé désactivé** (activation manuelle). · **Import ADMX/Enrollment expérimental** (v2.3.0) — lancer
  en **PREVIEW** d'abord. · **GUID non préservés** (nouveaux IDs dans la cible).

---
Voir aussi : [`LIMITATIONS.md`](LIMITATIONS.md) · [`../CHANGELOG.md`](../CHANGELOG.md) · reflète la **v2.3.0**.

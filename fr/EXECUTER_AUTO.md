> [🇬🇧 English version](../en/EXECUTER_AUTO.md)

# EXECUTER_AUTO — Exécution ZÉRO-TOUCH (aucune intervention humaine)

Cycle complet **Export → Nettoyage → Import (vagues) → Affectations → Vérification → Rapport**,
piloté par **une seule commande**, sans copier-coller, sans popup de connexion, sans confirmation.

> Différence avec [`EXECUTER.md`](EXECUTER.md) (mode manuel pas-à-pas, connexion interactive) :
> ici l'authentification est **app-only par certificat** et l'enchaînement est intégral et non-surveillé.

---

## Ce qui reste (une seule fois) vs ce qui est automatique

| Une seule fois (setup, admin) | À chaque exécution (100 % automatique) |
|---|---|
| Créer l'app registration + certificat + consentement admin dans **chaque** tenant | Export, sauvegarde, nettoyage, préflight, import par vagues, affectations, vérification, rapport |

L'app-only est **la seule façon** d'être réellement non-surveillé : Microsoft impose une identité
applicative (app registration + permissions applicatives + consentement admin) pour toute connexion
sans humain. Une fois posée, plus aucune intervention n'est requise — y compris en tâche planifiée.

---

## Étape A — Préparer les identités app-only (une fois par tenant)

Connecté en **administrateur** (Global Admin, ou Privileged Role Admin + Application Admin) :

```powershell
$Kit = 'C:\chemin\vers\intune-tenant-clone-kit'   # <-- éditer

# Tenant SOURCE (permissions LECTURE)
& "$Kit\tools\New-IntuneCloneKitAppRegistration.ps1" -TenantId <SOURCE_TENANT_ID> -Role Source

# Tenant CIBLE (permissions ÉCRITURE)
& "$Kit\tools\New-IntuneCloneKitAppRegistration.ps1" -TenantId <TARGET_TENANT_ID> -Role Target
```

Chaque appel affiche à la fin les lignes `…ClientId` / `…CertThumbprint` à coller dans `config.ps1`.

> Le certificat est créé dans `Cert:\CurrentUser\My` du compte qui exécute le helper. L'orchestrateur
> devra tourner sous **le même compte / la même machine** (ou importez le certificat là où il tournera).
> Permissions applicatives posées : `DeviceManagement*.{Read|ReadWrite}.All`, `Group.{Read|ReadWrite}.All`,
> `Organization.Read.All` (RBAC inclus pour les Scope Tags).

## Étape B — Renseigner `config.ps1`

```powershell
Copy-Item "$Kit\config.example.ps1" "$Kit\config.ps1"
# éditer config.ps1 : SourceTenantId, TargetTenantId, puis
#   SourceClientId / SourceCertThumbprint / TargetClientId / TargetCertThumbprint
```

## Étape C — Lancer l'exécution zéro-touch (PowerShell 7)

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1"
```

C'est tout. Tout est lu depuis `config.ps1`. À la fin : rapport HTML dans `output\`, journaux dans `logs\`.

### Bonne pratique : un essai à blanc d'abord

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1" -Preview
```

`-Preview` fait l'export + toutes les prévisualisations **sans aucune écriture** (aucun objet créé,
aucun groupe, aucune affectation). À vérifier dans le rapport, puis relancer sans `-Preview`.

---

## Paramètres utiles

| Paramètre | Effet |
|---|---|
| `-Preview` | Simulation intégrale, aucune écriture. |
| `-SourcePath <dossier>` | Réimporter un export déjà produit au lieu d'exporter à neuf. |
| `-ImportReport <fichier>` | Nettoyer un import précédent raté avant de réimporter (sinon auto-détecté dans `input\`). |
| `-SkipAssignments` | Ne pas migrer groupes + affectations. |
| `-SkipVerification` | Ne pas faire le comptage final SOURCE vs CIBLE. |
| `-SkipApps` / `-SkipScripts` / `-SkipMobile` | Sauter une vague d'import. |
| `-IncludeScopeTags` | Conserver les `roleScopeTagIds` (nécessite RBAC.ReadWrite sur la cible). |
| `-StaticOnlyGroups` | Recréer les groupes dynamiques en statiques vides (plus sûr en bac à sable). |
| `-StopOnImportErrors` | Interrompre si une vague comporte des erreurs. |
| `-AllowInteractive` | Repli sur connexion interactive si pas d'app-only (rompt le zéro-touch). |

Sans `config.ps1`, tout est passable en paramètres :

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1" `
  -SourceTenantId <SRC> -TargetTenantId <TGT> `
  -SourceClientId <APPSRC> -SourceCertThumbprint <THUMBSRC> `
  -TargetClientId <APPTGT> -TargetCertThumbprint <THUMBTGT>
```

---

## Exécution planifiée (vraiment non-surveillée)

Le certificat étant dans le magasin, l'orchestrateur peut tourner en tâche planifiée :

```powershell
$act = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument '-NoProfile -File "C:\chemin\vers\intune-tenant-clone-kit\Invoke-IntuneCloneKit-Unattended.ps1"'
$trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 3am
Register-ScheduledTask -TaskName 'IntuneCloneKit-ZeroTouch' -Action $act -Trigger $trg -RunLevel Highest
```

---

## Ce qui reste manuel (limites Intune, non contournables)

Profils à secret (Wi-Fi/PSK, AppLocker/WDAC, OMA chiffré), apps LOB/Win32/VPP (binaires),
Admin Templates, Endpoint Security (intents), Enrollment : non clonables par métadonnée seule.
Ils sont **ignorés proprement** (statut `SKIP_*`) et listés dans le rapport pour reprise manuelle.

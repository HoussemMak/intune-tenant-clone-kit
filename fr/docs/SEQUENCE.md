> [🇬🇧 English version](../../en/docs/SEQUENCE.md)

# Séquence d'exécution

Flux de bout en bout du kit : export frais, import par vagues avec rapport de réconciliation, vérification par outcome, et l'assistant IA de recréation optionnel. S'affiche nativement sur GitHub.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Kit as Kit (orchestrateur)
    participant Src as Tenant source (Graph · lecture)
    participant Tgt as Tenant cible (Graph · écriture)
    participant AI as Endpoint IA (optionnel)

    Admin->>Kit: lancer (config.ps1)
    Kit->>Src: connexion (lecture seule) + export frais (réhydraté, paginé)
    Src-->>Kit: JSON de configuration
    Kit->>Tgt: connexion (écriture) + sauvegarde (paginée)
    Kit->>Tgt: import par vagues (payloads corrigés, fail-closed)
    Kit->>Tgt: affectations — remap par nom
    Note over Src,Tgt: HTTP 429/503/504 rejoués (Retry-After + backoff exponentiel)
    Kit->>Kit: réconciliation — émet reconcile.json / .html / .csv (par run)
    Kit->>Kit: vérification par outcome & identityKey (pas les comptes)
    alt famille critique sécurité Failed / Skipped / OutOfScope (ou CA créée désactivée)
        Kit-->>Admin: bannière rouge 'SECURITY-CRITICAL NOT APPLIED' + code de sortie non nul (-Execute)
    end
    opt -UseAIAssist (éléments manuels / SKIP_* / secrets)
        Kit->>Kit: rédige runbook + scaffolds PowerShell/Graph (-WhatIf, <PLACEHOLDER>) dans ai-output/
        opt -SendToProvider (opt-in ; sinon dry-run local, zéro appel réseau)
            Kit->>AI: métadonnées expurgées (scan de secrets avant envoi)
            AI-->>Kit: runbook de recréation + scaffolds
        end
    end
    Kit-->>Admin: rapport de réconciliation (json/html/csv) + ai-output (à relire)
    Note over Admin,AI: L'étape IA n'écrit jamais dans un tenant · secrets expurgés · revue humaine
```

> [🇫🇷 Version française](../../fr/docs/SEQUENCE.md)

# Execution sequence

End-to-end flow of the kit: fresh export, wave import with a reconciliation report, outcome-based verification, and the optional AI recreation assistant. Renders natively on GitHub.

```mermaid
sequenceDiagram
    autonumber
    actor Admin
    participant Kit as Kit (orchestrator)
    participant Src as Source tenant (Graph · read)
    participant Tgt as Target tenant (Graph · write)
    participant AI as AI endpoint (optional)

    Admin->>Kit: run (config.ps1)
    Kit->>Src: connect (read-only) + fresh export (rehydrated, paginated)
    Src-->>Kit: configuration JSON
    Kit->>Tgt: connect (write) + backup (paginated)
    Kit->>Tgt: import in waves (corrected payloads, fail-closed)
    Kit->>Tgt: assignments — remap by name
    Note over Src,Tgt: HTTP 429/503/504 retried (Retry-After + exponential backoff)
    Kit->>Kit: reconcile — emit reconcile.json / .html / .csv (per run)
    Kit->>Kit: verify by outcome & identityKey (not counts)
    alt security-critical family Failed / Skipped / OutOfScope (or CA created disabled)
        Kit-->>Admin: red 'SECURITY-CRITICAL NOT APPLIED' banner + non-zero exit (-Execute)
    end
    opt -UseAIAssist (manual / SKIP_* / secret items)
        Kit->>Kit: draft runbook + PowerShell/Graph scaffolds (-WhatIf, <PLACEHOLDER>) into ai-output/
        opt -SendToProvider (opt-in; else local dry-run, zero network call)
            Kit->>AI: redacted metadata (pre-send secret scan)
            AI-->>Kit: recreation runbook + scaffolds
        end
    end
    Kit-->>Admin: reconcile report (json/html/csv) + ai-output (review-first)
    Note over Admin,AI: The AI step never writes to a tenant · secrets redacted · human review
```

> [🇫🇷 Version française](../../fr/docs/TROUBLESHOOTING.md)

# Troubleshooting — error signature → cause → fix

All the signatures below are **Microsoft Graph** messages (not specific to any
organization). Details of the mechanisms: [`METHODOLOGY.md`](METHODOLOGY.md).

| Signature (Graph) | Cause | Fix |
|---|---|---|
| `Property children in payload has a value that does not match schema` | Empty array `children:[]` turned into `{}` by a tree reconstruction in PowerShell | Do not reconstruct the tree; PS 7 + `ConvertFrom-Json -AsHashtable`; preserve `[]` |
| `Property settings ... does not match schema` | Single-element `settings` array flattened into an object | Same; keep `settings` as an array even with 1 element |
| `Property groupSettingCollectionValue / simpleSettingCollectionValue ... does not match schema` | Single-element collections flattened | Same |
| `An unexpected 'StartObject' node was found for property named 'roleScopeTagIds'` | Single-element array `["0"]` serialized as `{"Length":1}` | Force `[string[]]@(...)` or drop `roleScopeTagIds` (default `["0"]`) |
| *(Settings Catalog policy created but empty)* | "Two-step" import (`POST .../{id}/settings`) — non-functional endpoint | **A SINGLE POST** with `settings` inline |
| `DetectionScriptContent must not be null or empty` | Base64 content absent from the export (list endpoint) | Rehydrate via `GET deviceHealthScripts/{id}` |
| *(PowerShell script created but empty, no error)* | `deviceManagementScripts` accepts empty content | Rehydrate `scriptContent` per item; reject the POST if content is empty |
| `... scheduledActionsForRule ... is required` (compliance) | Missing block action (often stripped) | Re-export with `$expand`, or synthesize a `block` action |
| `Property validOperatingSystemBuildRanges ... does not match schema` | Empty array flattened | Drop it if empty, or preserve `[]` |
| `SecretReferenceValueId invalid for create` | Secret pointer specific to the source tenant | Drop the pointer, re-inject the value in cleartext (`getOmaSettingPlainTextValue`) or recreate |
| `400 BadRequest` on `targetedMobileApps` (App Config) | App GUID specific to the source, absent from the target | Remap by name (the app must exist/be approved on the target side) |
| `403` at scope-tags precheck | Scope `DeviceManagementRBAC.ReadWrite.All` not consented | Consent the scope, or disable scope-tags import |

## Reconciliation & kit signals

These are emitted by the **kit itself** (the `reconcile.json` / `.html` / `.csv` report and the
console), not by Graph. They are the source of truth for what a run did — inspect `reconcile.html`
first. Details: [`METHODOLOGY.md`](METHODOLOGY.md).

| Signal (kit) | Cause | Fix |
|---|---|---|
| `[BLOCKED] ... unresolved exclusion/filter — scope would broaden` | An assignment **exclusion group** or a **filter** could not be resolved on the target; `/assign` is a full replace, so applying the object without it would *broaden* scope (fail-closed) | Create the missing exclusion group / filter on the target, then replay. An unresolved exclusion/filter is **always** blocked — `-AllowPartialInclusionsOnly` does **not** override it |
| `[BLOCKED] ... unresolved inclusion` | An **inclusion group** has no target match; the object is refused rather than applied to a different scope | Create/map the group on the target, or pass `-AllowPartialInclusionsOnly` to apply the resolved same-or-narrower subset only |
| `SKIP_UNRESOLVED_CA_REF` | A Conditional Access policy references a tenant-scoped object (group / named location / role) with no target remap — CA is remap-or-refuse | Create and map the referenced object on the target, then replay. CA policies are always created **DISABLED** by design |
| `SKIP_DUP_KEY` | Two source objects share the same identityKey (the non-prefixed source name) — the run hard-fails to avoid an ambiguous match | Rename/de-duplicate on the source (or filter the export) so each identityKey is unique, then replay |
| **Exit code 2** + red `SECURITY-CRITICAL NOT APPLIED` banner | A security-critical object (Compliance / Conditional Access / Endpoint Security / baseline) ended Failed / Skipped / OutOfScope, or a CA was created disabled — raised only under `-Execute` | Open `reconcile.html`, fix the root cause (missing ref, scope, consent), then replay. The non-zero exit is intentional so CI / automation stops on it |
| AI step wrote files but made **no network call** | `Invoke-IntuneAIAssist` ran in local dry-run — `-SendToProvider` was not passed (ZERO network egress by design) | Expected behaviour: drafts are in `ai-output/` for human review. Add `-SendToProvider` only to call an external LLM (secrets are redacted + scanned before any send) |
| `429 Too Many Requests` / `503` / `504` bursts under load | Graph throttling | No action — export / import / assignments / orchestrator now auto-retry with `Retry-After` + exponential backoff |
| App registration lacks the Conditional Access permission (`Policy.ReadWrite.ConditionalAccess`) | `New-IntuneCloneKitAppRegistration.ps1` gates the CA scope behind a switch (least-privilege) | Re-create the app registration with `-EnableConditionalAccess` (Target role), then grant admin consent |

## General rules

- Always use **PowerShell 7** (never 5.1) for the whole pipeline.
- Always **preview (PREVIEW)** before `-Execute`.
- The **tenant guard** must refuse to write if the current context is not the expected target.
- Clean up a failed import **before** replaying (otherwise the "object with the same name already
  exists" masks the faulty typos).

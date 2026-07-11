> [🇫🇷 Version française](../../fr/docs/METHODOLOGY.md)

# Methodology — cloning Intune from one tenant to another

Cloning an Intune configuration is **not** a file copy: it is a **semantic
reconstruction**. §1–§3 cover the three classes of problems that make naive copies fail; §4–§8
cover how the kit **proves** what it applied, refuses to **widen scope**, and survives **throttling**.
Every section keeps the same **symptom → cause → fix** shape.

## 1. Serialization corruption of polymorphic payloads (Settings Catalog)

**Symptom**: when creating a Settings Catalog policy, Graph returns
`Property children / settings / groupSettingCollectionValue in payload has a value that does not match schema`
or `An unexpected 'StartObject' node was found for property named 'roleScopeTagIds'`.

**Cause**: many scripts re-read the JSON (`ConvertFrom-Json`) then **rebuild** the object
tree recursively before re-serializing (`ConvertTo-Json`). But as soon as a function **returns**
an array, PowerShell **enumerates** it:
- an **empty** array `children:[]` becomes `$null` → serialized as `{}`;
- a **single-element** array `roleScopeTagIds:["0"]` becomes a scalar/object → serialized as `{"Length":1}`.

This behavior exists in Windows PowerShell 5.1 **and** in PowerShell 7 if the tree is rebuilt.
Switching to PS 7 is therefore not enough on its own.

**Fix**:
1. **Do not rebuild the tree.** Read into a hash table (`ConvertFrom-Json -AsHashtable`), touch
   **only** the root and the `settings[i]` level, then serialize.
2. **Strictly** preserve `[]` and single-element arrays (never remove them via a
   "remove-nulls").
3. Create the policy in **A SINGLE POST** with `settings` **inline** — the endpoint
   `POST .../configurationPolicies/{id}/settings` per setting is **not** a valid creation
   mechanism.
4. On each `settings[i]`: remove the wrapper's `id` and inject
   `"@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting"`; keep
   `settingInstance` **verbatim** (including empty `children:[]` and null `*TemplateReference`).

## 2. Content that the "list" export does not return

**Symptom**: `DetectionScriptContent must not be null or empty` (remediations), or scripts created
**empty** with no error (false success), or a compliance policy rejected on `scheduledActionsForRule`.

**Cause**: the **list** endpoints do not return certain content. The base64 content of
scripts/remediations, the `scheduledActionsForRule` of compliance policies and the localized messages
of notification templates are returned **only by a per-entity GET** (or via `$expand`).

**Fix**: during export, **rehydrate per item**:
- `GET deviceManagement/deviceManagementScripts/{id}` → `scriptContent`
- `GET deviceManagement/deviceHealthScripts/{id}` → `detectionScriptContent` + `remediationScriptContent`
- `GET deviceManagement/deviceCompliancePolicies/{id}?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)`
- `GET deviceManagement/notificationMessageTemplates/{id}?$expand=localizedNotificationMessages`

> At creation, a compliance policy **requires** at least one `scheduledActionsForRule` with a
> `block` action. If the export did not capture it, synthesize it at import.

## 3. Identifiers that are not portable between tenants

**Symptom**: `SecretReferenceValueId invalid for create`, or `400 BadRequest` on
`targetedMobileApps`, or orphaned objects that target nothing.

**Cause**: any identifier issued by a tenant is **local** to that tenant: application GUIDs, scope
tags, secret pointers (`secretReferenceValueId`), Entra groups, filters. They do not resolve
in another tenant.

**Fix**:
- **Remap by name** (`displayName`): applications, scope tags, groups, filters. Build the
  dependencies **before** the objects that reference them.
- **Secrets**: `Intune` never lets you export a secret value in clear text. Retrieve it on the
  source side (`POST .../deviceConfigurations/{id}/getOmaSettingPlainTextValue`) then re-inject it,
  removing the `secretReferenceValueId` (Intune regenerates a new pointer on the target side). Otherwise,
  manual recreation.
- **Assignments**: import them **last**, after validating the objects and the mappings.

## 4. Silent partial success — no proof of what was applied

**Symptom**: an import "finishes" with green output, but nobody can say whether a compliance policy
was actually **created**, **matched** an existing one, or was silently **skipped**. A reviewer asking
"is Conditional Access live on the target?" has no authoritative artifact to point at.

**Cause**: a run that only prints `created` / `exists` lines leaves no per-object, machine-readable
ledger. Same-name objects, prefixed runs and skipped items blur together in the scrollback — a
security-critical object left unapplied looks identical to a success.

**Fix**: every import run emits **`reconcile.json` + `reconcile.html` + `reconcile.csv`** next to the
CSV log — one record per object: **outcome** (`Matched` / `Created` / `Failed` / `Skipped` /
`Preview` / `OutOfScope`), **reason**, **targetId**, **identityKey** and the **remap** applied.
- The **`identityKey`** is the logical key on the **non-prefixed** source name (backend- and
  prefix-independent), so an object stays traceable across a prefixed run.
- **`Matched`** and **`Created`** carry the **target id** — proof the object exists on the target.
- Two source files claiming the **same `identityKey`** in one run **hard-fail as `SKIP_DUP_KEY`**
  (no silent overwrite of one logical object by another).
- A security-critical family (**Compliance / Conditional Access / Endpoint Security / baseline**)
  left **`Failed` / `Skipped` / `OutOfScope`** — or a CA policy **created DISABLED** — raises the red
  **"SECURITY-CRITICAL NOT APPLIED"** banner and a **non-zero exit code** under `-Execute`, so
  automation stops on a false green instead of reporting success.

## 5. Assignments that silently widen scope (fail-closed)

**Symptom**: an object is applied on the target, but an **exclusion group** or an **assignment
filter** it depended on could not be resolved (it does not exist on the target). The object ends up
targeting **more** devices/users than on the source.

**Cause**: a naive `/assign` drops the unresolved target and POSTs the rest. Dropping an **inclusion**
only narrows scope, but dropping an **exclusion** or a **filter** **broadens** it — a scope regression
that passes unnoticed.

**Fix**: the assign phase is **fail-closed**; unresolved targets are tracked as inclusion vs
exclusion vs filter:
- An unresolved **exclusion or filter** **BLOCKS** the whole object unconditionally — a target is
  never applied without its filter/exclusion.
- An unresolved **inclusion** also blocks by default; only `-AllowPartialInclusionsOnly` (renamed
  from `-AllowPartialAssignments`) lets the resolved, **same-or-narrower** subset through.
- Blocked objects are reported so you can create the missing filter/exclusion group on the target
  and re-run.

## 6. Conditional Access references that don't resolve (remap-or-refuse)

**Symptom**: a Conditional Access policy is cloned, but its `include`/`exclude` users, groups, roles
or apps still point at **source-tenant GUIDs** that mean nothing on the target — or resolve to the
*wrong* principal.

**Cause**: CA policies are dense webs of tenant-local references. Emitting any unmapped source id
produces a silently mis-scoped policy, and a live CA policy that is wrong is more dangerous than none.

**Fix**: **remap-or-refuse**. Every tenant-scoped reference is either remapped via the target maps,
or the whole policy is **refused** (`SKIP_UNRESOLVED_CA_REF`) — a source-tenant id is **never** emitted
(well-known Microsoft app ids excepted). Every CA policy that *is* created is created **DISABLED**, so
a human reviews and enables it (the report flags it security-critical-not-applied until then).

## 7. Throttling and transient server errors (429 / 503 / 504)

**Symptom**: a large export or import fails part-way with `429 Too Many Requests`, `503 Service
Unavailable` or `504 Gateway Timeout`, and a naive run surfaces this as a hard **Failed** on an object
that was never really broken.

**Cause**: Graph throttles high-volume tenants. A single transient 429 must not read as an
object-level failure (or a false `Skipped`) in the reconciliation report.

**Fix**: every call goes through a retry wrapper (export / import / assignments / orchestrator). On
**429/503/504** it honors the **`Retry-After`** header when present, else a **capped exponential
backoff (≤ 60 s) + jitter**, then replays the call. Any non-throttling error is re-thrown unchanged,
so the fail-closed logic (§5–§6) is untouched.

## 8. Objects that cannot be cloned by API — assisted manual recreation

**Symptom**: some items can never be POSTed with correct content — secrets (Wi-Fi/VPN/PFX/encrypted
OMA), admin templates, endpoint security intents, enrollment config — and they land as `MANUAL` /
`SKIP_*` / `OutOfScope` in the report. Recreating them by hand is slow and error-prone.

**Cause**: they carry values the API won't return in clear, or have no re-import endpoint (see §3 and
the coverage table in the README). No tool crosses that cryptographic/API ceiling.

**Fix**: **opt-in, hardened AI assist**. `Invoke-IntuneAIAssist` drafts — for `MANUAL` / `SKIP_*` /
secret items — a **runbook + PowerShell/Graph scaffolds** (`-WhatIf`, `<PLACEHOLDER>` secrets) into
`ai-output/` **for human review**. It **never writes to a tenant and never auto-executes**. External
send is **opt-in** via `-SendToProvider` (without it: local dry-run, **zero network call**); secrets
are redacted and a **pre-send secret scan hard-fails**; the API key is never bundled. The human stays
in the loop — the assistant only removes the blank-page cost.

## Recommended execution order

```
0. Fresh export (source, read-only) — already rehydrated (§2)
1. Backup of the target
2. (optional) Cleanup of a previous failed import
3. Foundation: filters, scope tags
4. Apps (Store) + building the AppId mapping
5. Policies: profiles, Settings Catalog (§1), compliance (§2)
6. Scripts / remediations (rehydrated content)
7. Mobile: app config (remap), app protection, notifications, autopilot
8. Groups + assignments: remap by name (§3)
9. Manual: secrets, binary apps, admin templates, endpoint security, enrollment
```

Each write is done first in **PREVIEW**, then in execution after checking — and each run emits the
reconciliation report (§4) as the artifact of record, with the assign phase fail-closed (§5).

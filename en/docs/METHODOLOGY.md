> [🇫🇷 Version française](../../fr/docs/METHODOLOGY.md)

# Methodology — cloning Intune from one tenant to another

Cloning an Intune configuration is **not** a file copy: it is a **semantic
reconstruction**. Three classes of problems cause naive approaches to fail. This document explains
each one and the fix the kit applies.

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

Each write is done first in **PREVIEW**, then in execution after checking.

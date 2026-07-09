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

## General rules

- Always use **PowerShell 7** (never 5.1) for the whole pipeline.
- Always **preview (PREVIEW)** before `-Execute`.
- The **tenant guard** must refuse to write if the current context is not the expected target.
- Clean up a failed import **before** replaying (otherwise the "object with the same name already
  exists" masks the faulty typos).

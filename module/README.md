# IntuneTenantCloneKit (PowerShell module)

The `en/` and `fr/` bundles ship the kit as **standalone scripts** (best for reading the code and
running step by step). This folder packages the **same logic** as an installable PowerShell module
so you can `Install-Module` and call clean, approved-verb cmdlets.

```powershell
Install-Module IntuneTenantCloneKit -Scope CurrentUser
Import-Module IntuneTenantCloneKit
Get-Command -Module IntuneTenantCloneKit
```

> The module is published on the PowerShell Gallery (see the page for the current version). It clones the **clonable Intune configuration** tenant-to-tenant — devices re-enroll and
> secrets/tokens re-pair (a cryptographic ceiling no tool crosses). We clone the configuration; we
> guide the rest — see [`en/LIMITATIONS.md`](../en/LIMITATIONS.md).

## Cmdlets

| Cmdlet | From script (`en/`) |
|---|---|
| `Export-IntuneConfiguration`      | `scripts/Export-IntuneConfig_FraisComplet_v1.ps1` |
| `Import-IntuneConfiguration`      | `scripts/Import-IntuneConfig_Corrige_v3.ps1` |
| `Compare-IntuneExport`            | `scripts/Compare-IntuneExport.ps1` |
| `Test-IntuneExport`               | `scripts/Verify-IntuneExport.ps1` |
| `Copy-IntuneAssignment`           | `scripts/Invoke-IntuneAssignments_Graph.ps1` |
| `New-IntuneAppIdMap`              | `scripts/Build-IntuneAppIdMap.ps1` |
| `Remove-IntuneImportedObject`     | `scripts/Invoke-IntuneImportCleanupFromReport.ps1` |
| `Restore-IntuneScriptContent`     | `scripts/Recover-IntuneScriptContentsFromProd.ps1` |
| `Restore-IntuneOmaSecret`         | `scripts/Recover-IntuneOmaSecrets.ps1` |
| `Invoke-IntuneAIAssist`           | `scripts/Invoke-IntuneAIAssist.ps1` |
| `Convert-IntunePortalCapture`     | `scripts/Invoke-IntunePortalCaptureToScript.ps1` |
| `Publish-IntuneApp`               | `scripts/Publish-IntuneApp.ps1` |
| `New-IntuneCloneAppRegistration`  | `tools/New-IntuneCloneKitAppRegistration.ps1` |

> The unattended orchestrator (`Invoke-IntuneCloneKit-Unattended.ps1`) stays a bundle script for now;
> the composable cmdlets above cover the same flow: `Export-IntuneConfiguration` -> (`Restore-*`) ->
> `Import-IntuneConfiguration` -> `Copy-IntuneAssignment` -> `Test-IntuneExport`.

## Key behaviors

- **`Import-IntuneConfiguration` — reconciliation report + fail-loud exit code.** Every run emits
  `reconcile.json` / `reconcile.html` / `reconcile.csv` next to the CSV log: object-by-object
  outcome (Matched / Created / Failed / Skipped / Preview / OutOfScope), reason, `targetId` and
  `identityKey`. If a security-critical family (Compliance / Conditional Access / Endpoint Security /
  baseline) is left Failed/Skipped/OutOfScope — or a Conditional Access policy was created disabled —
  the report raises a red **"SECURITY-CRITICAL NOT APPLIED"** banner and the cmdlet returns a
  **non-zero code** under `-Execute`. Because this is a module, it **returns** the code and never
  kills the host (Conditional Access is always created **disabled**; unresolved tenant-scoped refs
  are refused rather than pointed at the source tenant).
- **`Copy-IntuneAssignment` — fail-closed scoping.** An assignment exclusion or filter that cannot
  be resolved on the target **blocks the object** rather than silently widening scope. Use
  `-AllowPartialInclusionsOnly` to permit partial *inclusions* only (exclusions/filters still block).
- **`New-IntuneCloneAppRegistration` — least privilege.** Provisions the app registration without
  the broad `DeviceManagementManagedDevices.*` scopes and with a **non-exportable** certificate;
  Conditional Access permissions are added only when you pass `-EnableConditionalAccess`.
- **`Invoke-IntuneAIAssist` — opt-in, local by default.** Drafts runbooks and `-WhatIf` PowerShell/
  Graph scaffolds (with `<PLACEHOLDER>` secrets) into `ai-output/` for **human review**; it never
  writes to a tenant and never auto-executes. External send is opt-in via `-SendToProvider` — without
  it the run is a local dry-run with **zero network calls**, and secrets are redacted with a
  pre-send scan that hard-fails.
- **`Test-IntuneExport` / `Compare-IntuneExport` — usable exit codes.** These return `0`/non-zero so
  CI can gate on them. `Build-Module.ps1` rewrites every top-level `exit N` to `return N` so a
  cmdlet keeps its code without terminating the host session.

## Build (maintainers)

The `Public/*.ps1` function files are **generated** from the `en/` scripts — the scripts remain the
single source of truth. After editing an `en/` script, regenerate:

```powershell
pwsh ./module/Build-Module.ps1
Test-ModuleManifest ./module/IntuneTenantCloneKit/IntuneTenantCloneKit.psd1
```

Then bump `ModuleVersion` in `IntuneTenantCloneKit.psd1`, commit, and push a matching `vX.Y.Z` tag —
the `publish-psgallery.yml` workflow validates and publishes automatically.

See the project [`en/LIMITATIONS.md`](../en/LIMITATIONS.md) for what is **not** cloned and the caveats
(e.g. Conditional Access is imported best-effort, created disabled).

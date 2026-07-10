# IntuneTenantCloneKit (PowerShell module)

The `en/` and `fr/` bundles ship the kit as **standalone scripts** (best for reading the code and
running step by step). This folder packages the **same logic** as an installable PowerShell module
so you can `Install-Module` and call clean, approved-verb cmdlets.

```powershell
Install-Module IntuneTenantCloneKit -Scope CurrentUser
Import-Module IntuneTenantCloneKit
Get-Command -Module IntuneTenantCloneKit
```

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

> The zero-touch orchestrator (`Invoke-IntuneCloneKit-Unattended.ps1`) stays a bundle script for now;
> the composable cmdlets above cover the same flow: `Export-IntuneConfiguration` -> (`Restore-*`) ->
> `Import-IntuneConfiguration` -> `Copy-IntuneAssignment` -> `Test-IntuneExport`.

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

@{
    RootModule           = 'IntuneTenantCloneKit.psm1'
    ModuleVersion        = '1.0.2'
    GUID                 = '2dfaf5e5-83c3-4d11-97b5-edc8c1a1bd89'
    Author               = 'Houmak'
    CompanyName          = 'Minerva IA'
    Copyright            = '(c) 2026 Houmak / Minerva IA. Released under the MIT License.'
    Description          = 'Reliably clone a Microsoft Intune configuration from one tenant to another (SOURCE -> TARGET): export, correct the classic serialization pitfalls, import, remap assignments by name, plus backup-grade helpers (checksums/verify, drift compare) and AI-assisted recreation for the manual remainder.'

    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    RequiredModules      = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
    )

    FunctionsToExport    = @(
        'Export-IntuneConfiguration',
        'Import-IntuneConfiguration',
        'Compare-IntuneExport',
        'Test-IntuneExport',
        'Copy-IntuneAssignment',
        'New-IntuneAppIdMap',
        'Remove-IntuneImportedObject',
        'Restore-IntuneScriptContent',
        'Restore-IntuneOmaSecret',
        'Invoke-IntuneAIAssist',
        'Convert-IntunePortalCapture',
        'Publish-IntuneApp',
        'New-IntuneCloneAppRegistration'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Intune', 'MicrosoftGraph', 'MEM', 'Endpoint', 'MDM', 'Migration', 'Backup', 'Windows', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/HoussemMak/intune-tenant-clone-kit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/HoussemMak/intune-tenant-clone-kit'
            ReleaseNotes = @'
1.0.2
- Idempotence hardening: match existing target objects by a composite key (name + @odata.type /
  platform) instead of name alone, and update the seen-set after each CREATE. Prevents duplicates
  and wrong skips for same-name objects of different types (e.g. an app published as iosVppApp and
  androidManagedStoreApp, or iOS vs iOSMobileApplicationManagement filters).
- AppConfigurations: remap targetedMobileApps (source app IDs -> target) via AppIdMap when
  -AppIdMapPath is supplied; SKIP_UNMAPPED instead of POSTing source-tenant IDs invalid in the target.
- Import macOS shell scripts (deviceShellScripts / 05_ScriptsShell), previously exported but not imported.
- Export now warns when a script/remediation body is empty (surfaces the eventual SKIP_EMPTY early).
- Unattended orchestrator: post-export guard aborts before any target write if the export is empty or
  carries the export-bug signature (invalid URL / failed families).
- Also normalises the last ",$all" pagination helper (Get-AllValues) to "return $all" (defence in depth).

1.0.1
- FIX (blocker): the Graph pagination helper Get-All returned ",$all", which the callers
  collapsed with "@(Get-All ...)" into a single-element array. The per-family foreach then
  iterated once over the WHOLE collection, so the per-item id became a space-joined list and
  the per-item URL became "endpoint/<id1> <id2> ...", failing with "The provided URL is not
  valid" and exporting 0 objects (except single-item families). Now streams "return $all".
  Affected: Export-IntuneConfiguration and Copy-IntuneAssignment.

1.0.0
- First PowerShell Gallery release of the intune-tenant-clone-kit as a module.
- Core cmdlets: Export-IntuneConfiguration, Import-IntuneConfiguration (settings inline,
  array preservation, scheduledActionsForRule injection, name-based idempotence, -NamePrefix),
  Copy-IntuneAssignment, New-IntuneAppIdMap, Remove-IntuneImportedObject.
- Backup-grade helpers: Test-IntuneExport (SHA-256 integrity vs checksums.json),
  Compare-IntuneExport (drift between two exports).
- Recovery helpers: Restore-IntuneScriptContent, Restore-IntuneOmaSecret.
- Assist helpers (never write to a tenant): Invoke-IntuneAIAssist, Convert-IntunePortalCapture,
  Publish-IntuneApp (experimental), New-IntuneCloneAppRegistration.
- Requires PowerShell 7.4+ and Microsoft.Graph.Authentication. Conditional Access is imported
  best-effort (created disabled). See project LIMITATIONS.md.
'@
        }
    }
}

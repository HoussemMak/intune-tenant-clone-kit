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
- Hardening (no behaviour change): normalise the last pagination helper (Get-AllValues in
  Import-IntuneConfiguration) from ",$all" to "return $all". Its only caller already piped
  "| ForEach-Object" so it was safe, but this removes the last instance of the collapse-prone
  idiom for defence in depth.

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

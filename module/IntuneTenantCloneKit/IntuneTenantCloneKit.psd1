@{
    RootModule           = 'IntuneTenantCloneKit.psm1'
    ModuleVersion        = '2.0.0'
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
2.0.0  (security hardening - BREAKING)
- SECURITY (P0): assignments are now FAIL-CLOSED. An unresolved exclusion group or assignment filter
  BLOCKS the whole object instead of applying a partial set that would broaden scope. The switch
  -AllowPartialAssignments is renamed -AllowPartialInclusionsOnly and may only omit a redundant
  same-or-narrower inclusion, never widen scope. (Copy-IntuneAssignment)
- SECURITY (P0): the "never write to the SOURCE tenant" safeguard is now parametric (compares
  -SourceTenantId / -TargetTenantId), independent of the manifest file, and hard-fails on a missing or
  corrupt manifest during a write phase. (Copy-IntuneAssignment)
- SECURITY (P0): Invoke-IntuneAIAssist no longer sends anything externally by default. External calls
  require the explicit -SendToProvider switch; a pre-send secret scan hard-fails before any network call;
  secret redaction now handles PSCustomObject (previously a no-op) and a wider key set.
- SECURITY (P0): Conditional Access import is remap-or-refuse. Every tenant-scoped reference class (users,
  groups, roles, apps, named locations, service principals, terms-of-use, authentication strength) is
  remapped to the target; role templates / well-known apps / built-in auth strengths pass through; any
  unresolved reference REFUSES the whole policy (fail-closed), and a backstop refuses any source-tenant
  GUID left in an unhandled slot. Policies are still created DISABLED.
- SECURITY (P0): New-IntuneCloneAppRegistration is least-privilege by default - drops
  DeviceManagementManagedDevices.* (device wipe), creates a NON-EXPORTABLE certificate, and gates
  Policy.ReadWrite.ConditionalAccess behind -EnableConditionalAccess. Group.ReadWrite.All is kept on the
  TARGET so a fresh tenant can still be provisioned.
- CI: a secret-scan workflow (thumbprints, PEM/PFX blobs, OMA secrets) now runs on both en/ and fr/.

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

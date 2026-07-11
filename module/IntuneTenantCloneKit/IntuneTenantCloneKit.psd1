@{
    RootModule           = 'IntuneTenantCloneKit.psm1'
    ModuleVersion        = '2.3.0'
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
2.3.0  (EXPERIMENTAL: ADMX + Enrollment import)
- EXPERIMENTAL - run in PREVIEW first; community feedback welcome. The import now covers two families
  that were previously export-only. All fail-closed, PREVIEW by default, never writes to the source.
- Administrative Templates / ADMX (groupPolicyConfigurations): the configuration is created, then each
  definitionValue is posted with its definition/presentation @odata.bind remapped BY ATTRIBUTES (never a
  source id); an unresolved or ambiguous definition/presentation skips the value (SKIP_UNRESOLVED_DEF).
- Enrollment (deviceEnrollmentConfigurations): only creatable targeted profiles (ESP, device limit,
  single-platform restriction, notifications) are created; tenant defaults / priority-0 / singletons
  (Windows Hello, co-management, windows-restore) are skipped; existing target priorities are never
  reordered (setPriority is never called); a legacy combined platform-restriction is flagged for review.
- Endpoint Security: no importer - the intents API is frozen (~2025-03). Modern Endpoint Security already
  flows through the Settings Catalog family; legacy intents stay manual / AI-assist (reported OutOfScope).

2.2.0  (resilience, honest verification, coverage & docs)
- 429/503/504 backoff: throttled/transient Graph responses are retried (Retry-After + exponential
  backoff) across export, import, assignments and the unattended orchestrator.
- Honest verification: the orchestrator no longer compares counts (target >= source); it uses each
  wave's reconcile.json as the source of truth and paginates backup/verify (no ?$top=999 truncation).
- AppIdMap in -Phase All: a single -Phase All import auto-builds the source->target app id map after
  the Apps wave; an unmapped app is SKIP_UNMAPPED (never a source app GUID POSTed into the target).
- Module exit codes preserved: Test-IntuneExport / Compare-IntuneExport return a usable non-zero code
  (the build turns a top-level 'exit N' into 'return N'; a module cmdlet never exits the host).
- Docs refreshed across en/ and fr/ (reconciliation, fail-closed security, AI assistant, honest
  positioning), new architecture/product images, and a CHANGELOG.

2.1.0  (reconciliation report)
- Import-IntuneConfiguration now emits an object-by-object reconciliation report next to the CSV log:
  reconcile.json (versioned, backend-neutral schema), reconcile.html (per-family tables + a
  SECURITY-CRITICAL NOT APPLIED header) and reconcile.csv. It proves what landed, what did not, and why.
- IdentityKey is recorded on the NON-prefixed source name (sourceName vs appliedName kept distinct);
  a Matched object carries the real target id; two source files with the same IdentityKey hard-fail as
  SKIP_DUP_KEY instead of a silent merge.
- Security-criticality: a Compliance / Conditional Access / Endpoint Security / baseline object left
  Failed, Skipped or OutOfScope (or a CA created DISABLED) raises a red banner and, under -Execute, a
  non-zero exit code (2) - a silently dropped security baseline can no longer read as "all clear".
- Completeness invariant counts source files independently of record emission.

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

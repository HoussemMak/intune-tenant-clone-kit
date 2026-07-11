# Changelog

All notable changes to **intune-tenant-clone-kit** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Scope note: the kit **clones the clonable Intune configuration** tenant-to-tenant
> (export → correct → import). It is not a device/identity/tenant migration — devices
> re-enroll and secrets/tokens re-pair (a cryptographic ceiling no tool crosses).
> We clone the configuration; we guide the rest.

## [2.3.0] — 2026-07-11

> ⚠️ **Experimental.** The new ADMX and Enrollment import writes to the target tenant. It is fail-closed
> and **PREVIEW by default**, but has not been tested by the maintainers on a live tenant — **run in
> PREVIEW first, then `-Execute` on a sandbox, and please open an issue with feedback.**

### Added
- **ADMX / Administrative Templates import** (`14_AdminTemplates` → `groupPolicyConfigurations`). Export
  enriched with `definitionValues`; import creates the configuration then posts each value with its
  definition/presentation `@odata.bind` remapped **by attributes** (never a source id). An unresolved or
  ambiguous definition/presentation skips the whole value (`SKIP_UNRESOLVED_DEF`).
- **Enrollment import** (`16_Enrollment` → `deviceEnrollmentConfigurations`), skip-and-flag. Only creatable
  targeted profiles (ESP, device limit, single-platform restriction, notifications) are created; tenant
  defaults / priority-0 / singletons (Windows Hello, co-management, windows-restore) are skipped; target
  priorities are never reordered; a legacy combined platform-restriction is `SKIP_FLAG_REVIEW` (surfaced as
  security-critical).

### Notes
- **Endpoint Security** (`15_EndpointSecurity`): no importer — the `intents` API is frozen (~2025-03).
  Modern Endpoint Security already imports via the Settings Catalog family; legacy intents remain
  manual / AI-assist and are reported as `OutOfScope`.

## [2.2.0] — 2026-07-11

### Added
- **429/503/504 backoff.** Throttled and transient Graph responses are retried with
  `Retry-After` plus exponential backoff across export, import, assignments and the
  unattended orchestrator, so large tenants no longer abort mid-run.
- **AppIdMap in `-Phase All`.** A single `-Phase All` import auto-builds the
  source → target app id map after the Apps wave; an unmapped app is recorded as
  `SKIP_UNMAPPED` instead of POSTing a source-tenant GUID into the target.

### Changed
- **Honest verification.** The unattended orchestrator no longer verifies by comparing
  counts (`target >= source`); it uses each wave's `reconcile.json` as the source of
  truth. Backup/verify reads now paginate fully (no `?$top=999` truncation).
- **Coverage documentation aligned** with what the code actually exports and re-imports:
  ~20 families cloned; `14_AdminTemplates`, `15_EndpointSecurity` (intents) and
  `16_Enrollment` are exported but not re-imported (surfaced as `OutOfScope` in the
  report); secrets, Apple/Google tokens & connectors, device identities/Autopilot
  hardware hashes and app binaries are not cloned (cryptographic ceiling).

### Fixed
- **Module exit codes preserved.** During module build, `exit N` is rewritten to
  `return N` so `Test-IntuneExport` / `Compare-IntuneExport` still return a usable
  code and a cmdlet never terminates the host process.

## [2.1.0] — Reconciliation report

### Added
- `Import-IntuneConfiguration` now emits an object-by-object **reconciliation report**
  next to the CSV log: `reconcile.json` (versioned, backend-neutral schema),
  `reconcile.html` (per-family tables + a **SECURITY-CRITICAL NOT APPLIED** header) and
  `reconcile.csv`. It proves what landed, what did not, and why — with `outcome`
  (Matched/Created/Failed/Skipped/Preview/OutOfScope), reason, `targetId`, `identityKey`
  and remap for each object.
- `identityKey` is recorded on the **non-prefixed** source name (`sourceName` vs
  `appliedName` kept distinct); a Matched object carries the real target id.

### Security
- **Security-criticality banner + non-zero exit.** A Compliance / Conditional Access /
  Endpoint Security / baseline object left Failed, Skipped or OutOfScope (or a CA created
  DISABLED) raises a red banner and, under `-Execute`, a non-zero exit code (2) — a
  silently dropped security baseline can no longer read as "all clear".

### Changed
- Two source files with the same `identityKey` now hard-fail as `SKIP_DUP_KEY` instead
  of silently merging.
- Completeness invariant counts source files independently of record emission.

## [2.0.0] — Security hardening (BREAKING)

### Security
- **Fail-closed assignments (P0).** An unresolved exclusion group or assignment filter now
  **blocks the whole object** instead of applying a partial set that would broaden scope.
- **Parametric anti-source-write guard (P0).** The "never write to the SOURCE tenant"
  safeguard now compares `-SourceTenantId` / `-TargetTenantId`, is independent of the
  manifest file, and hard-fails on a missing or corrupt manifest during a write phase.
  (`Copy-IntuneAssignment`)
- **AI assistant opt-in (P0).** `Invoke-IntuneAIAssist` no longer sends anything externally
  by default. External calls require the explicit `-SendToProvider` switch; a pre-send
  secret scan hard-fails before any network call; secret redaction now handles
  `PSCustomObject` (previously a no-op) and a wider key set.
- **Conditional Access remap-or-refuse (P0).** Every tenant-scoped reference class (users,
  groups, roles, apps, named locations, service principals, terms-of-use, authentication
  strength) is remapped to the target; role templates / well-known apps / built-in auth
  strengths pass through; any unresolved reference **refuses the whole policy**
  (`SKIP_UNRESOLVED_CA_REF`), and a backstop refuses any source-tenant GUID left in an
  unhandled slot. Policies are still created **DISABLED**.
- **App registration least-privilege (P0).** `New-IntuneCloneAppRegistration` drops
  `DeviceManagementManagedDevices.*` (device wipe), creates a **non-exportable** certificate,
  and gates `Policy.ReadWrite.ConditionalAccess` behind `-EnableConditionalAccess`.
  `Group.ReadWrite.All` is kept on the TARGET so a fresh tenant can still be provisioned.
- **CI secret-scan.** A workflow (thumbprints, PEM/PFX blobs, OMA secrets) now runs on both
  `en/` and `fr/`.

### Changed (BREAKING)
- The switch `-AllowPartialAssignments` is renamed **`-AllowPartialInclusionsOnly`** and may
  only omit a redundant same-or-narrower inclusion, never widen scope.
  (`Copy-IntuneAssignment`)

## [1.0.2]

### Changed
- **Idempotence hardening.** Match existing target objects by a composite key
  (name + `@odata.type` / platform) instead of name alone, and update the seen-set after each
  CREATE. Prevents duplicates and wrong skips for same-name objects of different types (e.g. an
  app published as `iosVppApp` and `androidManagedStoreApp`, or iOS vs
  iOSMobileApplicationManagement filters).
- **AppConfigurations** remap `targetedMobileApps` (source app IDs → target) via AppIdMap when
  `-AppIdMapPath` is supplied; `SKIP_UNMAPPED` instead of POSTing source-tenant IDs invalid in
  the target.
- Export now warns when a script/remediation body is empty (surfaces the eventual `SKIP_EMPTY`
  early).
- Unattended orchestrator: post-export guard aborts before any target write if the export is
  empty or carries the export-bug signature (invalid URL / failed families).
- Normalise the last `,$all` pagination helper (`Get-AllValues`) to `return $all` (defence in
  depth).

### Added
- Import macOS shell scripts (`deviceShellScripts` / `05_ScriptsShell`), previously exported but
  not imported.

## [1.0.1]

### Fixed
- **Blocker:** the Graph pagination helper `Get-All` returned `,$all`, which callers collapsed
  with `@(Get-All ...)` into a single-element array. The per-family `foreach` then iterated once
  over the whole collection, so the per-item id became a space-joined list and the per-item URL
  became `endpoint/<id1> <id2> ...`, failing with "The provided URL is not valid" and exporting
  0 objects (except single-item families). Now streams `return $all`. Affected:
  `Export-IntuneConfiguration` and `Copy-IntuneAssignment`.

## [1.0.0]

### Added
- First PowerShell Gallery release of the intune-tenant-clone-kit as a module.
- Core cmdlets: `Export-IntuneConfiguration`, `Import-IntuneConfiguration` (settings inline,
  array preservation, `scheduledActionsForRule` injection, name-based idempotence, `-NamePrefix`),
  `Copy-IntuneAssignment`, `New-IntuneAppIdMap`, `Remove-IntuneImportedObject`.
- Backup-grade helpers: `Test-IntuneExport` (SHA-256 integrity vs `checksums.json`),
  `Compare-IntuneExport` (drift between two exports).
- Recovery helpers: `Restore-IntuneScriptContent`, `Restore-IntuneOmaSecret`.
- Assist helpers (never write to a tenant): `Invoke-IntuneAIAssist`,
  `Convert-IntunePortalCapture`, `Publish-IntuneApp` (experimental),
  `New-IntuneCloneAppRegistration`.
- Requires PowerShell 7.4+ and `Microsoft.Graph.Authentication`. Conditional Access is imported
  best-effort (created disabled). See `LIMITATIONS.md`.

[Unreleased]: https://github.com/HoussemMak/intune-tenant-clone-kit/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/HoussemMak/intune-tenant-clone-kit/releases/tag/v2.1.0
[2.0.0]: https://github.com/HoussemMak/intune-tenant-clone-kit/releases/tag/v2.0.0
[1.0.2]: https://github.com/HoussemMak/intune-tenant-clone-kit/releases/tag/v1.0.2
[1.0.1]: https://github.com/HoussemMak/intune-tenant-clone-kit/releases/tag/v1.0.1
[1.0.0]: https://github.com/HoussemMak/intune-tenant-clone-kit/releases/tag/v1.0.0

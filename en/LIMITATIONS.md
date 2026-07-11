> [🇫🇷 Version française](../fr/LIMITATIONS.md)

# Limitations

This kit clones **most** of an Intune configuration, but some object types cannot be exported or
recreated automatically — either because of Microsoft Graph / Intune platform constraints, or because
they carry data that is not portable between tenants. Handle the items below **manually** in the
target tenant.

> ### Clone, not migration
>
> This kit **duplicates the _clonable_ Intune configuration** from one tenant to another. It is **not** a
> device, identity, or full-tenant *migration*: on the target, devices **re-enroll** and secrets & tokens
> **re-pair**. That boundary is a **cryptographic ceiling no tool crosses** — not a shortcoming of this one.
> Three honest buckets:
>
> 1. **Cloned automatically** — ~20 configuration families are exported *and* re-imported (coverage table in
>    [`README.md`](README.md)).
> 2. **Imported (experimental), or recreated by hand** — Admin Templates (ADMX) and Enrollment are now
>    re-imported by an **experimental, fail-closed, PREVIEW-by-default** engine (new in v2.3.0 — see the
>    caveat below); **legacy Endpoint Security intents** stay manual (the `intents` API is frozen — modern
>    Endpoint Security already clones via the Settings Catalog family). Whatever is not re-created is surfaced
>    by the reconciliation report as **`OutOfScope`**, so nothing is silently dropped.
> 3. **Never crossed — the cryptographic ceiling** — encrypted secrets (the export never carries the clear
>    value), third-party tokens & connectors (APNs / Apple ADE·VPP / Managed Google Play / NDES), device
>    identities & Autopilot hardware hashes, and app binaries & store/VPP licences.
>
> **We clone the configuration; we guide the rest.** For buckets 2 and 3, the opt-in AI assistant
> ([`Invoke-IntuneAIAssist.ps1`](scripts/Invoke-IntuneAIAssist.ps1)) drafts a recreation **runbook +
> PowerShell/Graph scaffolds** into `ai-output/` for human review — it **bridges the manual toil, not the
> cryptographic ceiling**: it never writes to a tenant, never auto-executes, and redacts secrets before any
> (opt-in) network call.

![What clones vs. what re-pairs](../assets/overview.png)

## Not exported / cloned by the kit

| Object type | Why | What to do |
|---|---|---|
| **Device Inventory policies** (the newer *"collect device inventory"* / properties-catalog configuration) | These policies are **not returned by the standard `deviceManagement` configuration endpoints** the kit enumerates, and are **not exportable with a regular Microsoft Graph token** — the Intune portal uses a separate/internal token for them. | Recreate manually — or `Invoke-IntunePortalCaptureToScript.ps1` turns a portal capture into an AI-drafted recreation script. |
| **Encrypted secrets** (Wi-Fi/PSK, VPN, custom OMA-URI with `secretReferenceValueId`, AppLocker/WDAC blobs) | Intune never exports a secret value in clear text; the reference pointer is tenant-specific. | `Recover-IntuneOmaSecrets.ps1` (or the orchestrator's `-RecoverSecrets`) pulls the clear value from the source and re-injects it — no re-typing (needs source read rights); otherwise recreate and re-enter the secret. |
| **LOB / Win32 / VPP apps** | The installer binary (`.intunewin`, package, VPP token) is not part of the exported JSON metadata. | Provide the binary; `Publish-IntuneApp.ps1` (experimental) orchestrates the Win32 `.intunewin` upload, then re-map assignments. |

## Imported — EXPERIMENTAL (Admin Templates & Enrollment)

> 🧪 **EXPERIMENTAL — run in PREVIEW first.** New in **v2.3.0**, the Admin Templates (ADMX) and Enrollment
> import paths have **not been validated by the maintainers against a real tenant.** **Run them in PREVIEW
> mode first, test on a sandbox tenant, then please
> [open a feedback issue](https://github.com/HoussemMak/intune-tenant-clone-kit/issues).** Both paths are
> **fail-closed** and **PREVIEW by default**: an unresolved or ambiguous case is **skipped, never guessed**.
> This is still **not** a "full migration" — the honest positioning is unchanged.

As of **v2.3.0** two families that used to be export-only are now re-created by the import engine — but
**experimentally** (see the caveat above). This is a best-effort, **skip-and-flag** re-creation, and every
skipped object is still surfaced by the reconciliation report as **`OutOfScope`**.

| Object type | Export folder | What imports | What is skipped (fail-closed) |
|---|---|---|---|
| **Administrative Templates (ADMX)** (`groupPolicyConfigurations`) | `14_AdminTemplates` | Each policy is re-created, remapping its **definition / presentation references by attributes** (name, class, category path) across tenants instead of by tenant-specific ID. | Any value whose definition or presentation cannot be resolved **unambiguously** on the target is refused as **`SKIP_UNRESOLVED_DEF`** — never written blind with a guessed ID. |
| **Enrollment configurations** (`deviceEnrollmentConfigurations`) | `16_Enrollment` | Only the **creatable, targeted** profiles: Enrollment Status Page (ESP), device-limit, single-platform enrollment restriction, and notifications. Existing target **priorities are never reordered**. | Tenant **defaults**, **priority-0** and **singletons** (Windows Hello, co-management, windows-restore) are **skipped**; a **legacy combined platform restriction** is skipped as **`SKIP_FLAG_REVIEW`** (raised as security-critical for human review). |

## Exported, but NOT re-imported automatically (manual re-import)

The family below **is captured by the export**, but is **not part of the import catalog** (`$Catalog`),
so the import engine never re-creates it — recreate it by hand in the target tenant. It is **not**
"missing" from your export: the **reconciliation report** (`reconcile.json` / `.html` / `.csv`) lists every
such object with the outcome **`OutOfScope`** (counted, never silently dropped). An OutOfScope **Endpoint
Security** object — or any object whose name contains *baseline* — additionally raises the
**SECURITY-CRITICAL** banner, and in `-Execute` mode forces a non-zero reconciliation exit code, so a
critical policy is never mistaken for "all clear".

| Object type | Export folder | Why not re-imported | What to do |
|---|---|---|---|
| **Endpoint Security intents / baselines** (legacy) | `15_EndpointSecurity` | The legacy `intents` template API is **frozen by Microsoft (~2025-03)** and absent from the import catalog. **Modern** Endpoint Security already clones through the **Settings Catalog** family (`02_`); only the legacy intents stay manual. | Recreate the legacy intents at the portal (or migrate them to the Settings Catalog). Listed `OutOfScope`; baselines also flagged security-critical. |

> 🤖 This still-manual family — plus the bucket-3 items above — is exactly the **manual gap** the opt-in AI
> assistant targets: point `Invoke-IntuneAIAssist.ps1` at the export for a review-first recreation runbook +
> Graph scaffolds in `ai-output/`. It bridges the toil (drafts the steps and scripts) — it never writes to
> your tenant.

## Other configuration types not cloned

The kit enumerates a fixed set of Intune endpoints; anything outside that set is not exported:

- **Device cleanup rules**.
- **RBAC role assignments** and **built-in role definitions** (custom role *definitions* are cloned;
  built-in roles and role *assignments* — who holds a role — are not).
- **Company branding / Organizational messages** (tenant customization).
- **Enrollment tokens & third-party connectors** — Apple **ADE/VPP** & the **APNs** push certificate,
  **Managed Google Play** / Android Enterprise, and **PKI / NDES / certificate connectors**: secrets or
  infrastructure that **re-pair** against the target tenant (the cryptographic ceiling), not portable.

Recreate these at the portal, or handle them with a dedicated tool.

## Out of scope by design

- **Conditional Access** — exported/imported **best-effort**: each policy is **created DISABLED**. References (users, groups, roles, apps, named locations, service principals, terms-of-use, authentication strength) are **remapped to the target tenant**; any reference that cannot be resolved makes the whole policy **refused (fail-closed)** rather than emitting a source-tenant ID. **Review and enable manually.** The CA scope is **opt-in**: the app-registration tool grants `Policy.ReadWrite.ConditionalAccess` only with **`-EnableConditionalAccess`**.
- **Devices, users, Autopilot hardware hashes, reports / inventory data** — runtime data, not configuration
  (devices **re-enroll** on the target; Autopilot hashes are re-collected from the hardware itself).

## Handled, but tenant-dependent

- **Groups, filters, scope tags, app IDs** are **remapped by name** — the target objects must already
  exist (or be created) first; unresolved references are logged and skipped. **Assignment filters are not
  auto-recreated**: a filtered assignment whose filter is absent in the target is **blocked** (never applied
  without its filter), not silently widened.
- **Managed Google Play / VPP apps** must be approved and synchronized in the target tenant before
  their app configurations apply.
- **Device inventory / reports data** is runtime telemetry, not configuration — out of scope. This kit
  clones **configuration**, not device data.

## Acknowledgements

Thanks to **Rudy Ooms** — Microsoft MVP, [call4cloud.nl](https://call4cloud.nl) — for flagging the
Device Inventory policies limitation.

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
> 2. **Exported, but recreated by hand** — Admin Templates (ADMX), Endpoint Security intents and Enrollment
>    are captured by the export but **not** by the import engine; the reconciliation report surfaces each as
>    **`OutOfScope`**, so nothing is silently dropped.
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

## Exported, but NOT re-imported automatically (manual re-import)

The families below **are captured by the export**, but are **not part of the import catalog** (`$Catalog`),
so the import engine never re-creates them — recreate them by hand in the target tenant. They are **not**
"missing" from your export: the **reconciliation report** (`reconcile.json` / `.html` / `.csv`) lists every
such object with the outcome **`OutOfScope`** (counted, never silently dropped). An OutOfScope **Endpoint
Security** object — or any object whose name contains *baseline* — additionally raises the
**SECURITY-CRITICAL** banner, and in `-Execute` mode forces a non-zero reconciliation exit code, so a
critical policy is never mistaken for "all clear".

| Object type | Export folder | Why not re-imported | What to do |
|---|---|---|---|
| **Administrative Templates (ADMX)** | `14_AdminTemplates` | Not handled by the Settings Catalog import engine; absent from the import catalog. | Recreate at the portal (or migrate them to the Settings Catalog). |
| **Endpoint Security intents / baselines** | `15_EndpointSecurity` | The `intents` template model is not covered by the import engine; absent from the import catalog. | Recreate at the portal. Listed `OutOfScope`; baselines also flagged security-critical. |
| **Enrollment configurations** | `16_Enrollment` | Tenant-specific enrollment restrictions / status pages; absent from the import catalog. | Recreate at the portal. |

> 🤖 These three families are exactly the **manual gap** the opt-in AI assistant targets: point
> `Invoke-IntuneAIAssist.ps1` at the export for a review-first recreation runbook + Graph scaffolds in
> `ai-output/`. It bridges the toil (drafts the steps and scripts) — it never writes to your tenant.

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

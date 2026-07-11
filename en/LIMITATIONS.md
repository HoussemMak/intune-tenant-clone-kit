> [🇫🇷 Version française](../fr/LIMITATIONS.md)

# Limitations

This kit clones **most** of an Intune configuration, but some object types cannot be exported or
recreated automatically — either because of Microsoft Graph / Intune platform constraints, or because
they carry data that is not portable between tenants. Handle the items below **manually** in the
target tenant.

## Not exported / cloned by the kit

| Object type | Why | What to do |
|---|---|---|
| **Device Inventory policies** (the newer *"collect device inventory"* / properties-catalog configuration) | These policies are **not returned by the standard `deviceManagement` configuration endpoints** the kit enumerates, and are **not exportable with a regular Microsoft Graph token** — the Intune portal uses a separate/internal token for them. | Recreate manually — or `Invoke-IntunePortalCaptureToScript.ps1` turns a portal capture into an AI-drafted recreation script. |
| **Encrypted secrets** (Wi-Fi/PSK, VPN, custom OMA-URI with `secretReferenceValueId`, AppLocker/WDAC blobs) | Intune never exports a secret value in clear text; the reference pointer is tenant-specific. | `Recover-IntuneOmaSecrets.ps1` (or the orchestrator's `-RecoverSecrets`) pulls the clear value from the source and re-injects it — no re-typing (needs source read rights); otherwise recreate and re-enter the secret. |
| **LOB / Win32 / VPP apps** | The installer binary (`.intunewin`, package, VPP token) is not part of the exported JSON metadata. | Provide the binary; `Publish-IntuneApp.ps1` (experimental) orchestrates the Win32 `.intunewin` upload, then re-map assignments. |
| **Administrative Templates (ADMX)** | Not handled by the Settings Catalog engine. | Recreate at the portal (or migrate them to the Settings Catalog). |
| **Endpoint Security intents** | The `intents` template model is not covered. | Recreate at the portal. |
| **Enrollment configurations** | Tenant-specific enrollment restrictions / status pages. | Recreate at the portal. |

## Other configuration types not cloned

The kit enumerates a fixed set of Intune endpoints; anything outside that set is not exported:

- **Device cleanup rules**.
- **RBAC role assignments** and **built-in role definitions** (custom role *definitions* are cloned;
  built-in roles and role *assignments* — who holds a role — are not).
- **Company branding / Organizational messages** (tenant customization).
- **Enrollment tokens** (Apple ADE/VPP, Android Enterprise) and **PKI / certificate connectors** —
  secrets or infrastructure, not portable between tenants.

Recreate these at the portal, or handle them with a dedicated tool.

## Out of scope by design

- **Conditional Access** — exported/imported **best-effort**: each policy is **created DISABLED**. References (users, groups, roles, apps, named locations, service principals, terms-of-use, authentication strength) are **remapped to the target tenant**; any reference that cannot be resolved makes the whole policy **refused (fail-closed)** rather than emitting a source-tenant ID. **Review and enable manually.** The CA scope is **opt-in**: the app-registration tool grants `Policy.ReadWrite.ConditionalAccess` only with **`-EnableConditionalAccess`**.
- **Devices, users, Autopilot hardware hashes, reports / inventory data** — runtime data, not configuration.

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

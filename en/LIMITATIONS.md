> [🇫🇷 Version française](../fr/LIMITATIONS.md)

# Limitations

This kit clones **most** of an Intune configuration, but some object types cannot be exported or
recreated automatically — either because of Microsoft Graph / Intune platform constraints, or because
they carry data that is not portable between tenants. Handle the items below **manually** in the
target tenant.

## Not exported / cloned by the kit

| Object type | Why | What to do |
|---|---|---|
| **Device Inventory policies** (the newer *"collect device inventory"* / properties-catalog configuration) | These policies are **not returned by the standard `deviceManagement` configuration endpoints** the kit enumerates, and are **not exportable with a regular Microsoft Graph token** — the Intune portal uses a separate/internal token for them. | Recreate them manually in the target tenant. |
| **Encrypted secrets** (Wi-Fi/PSK, VPN, custom OMA-URI with `secretReferenceValueId`, AppLocker/WDAC blobs) | Intune never exports a secret value in clear text; the reference pointer is tenant-specific. | Recreate the profile and re-enter the secret value. |
| **LOB / Win32 / VPP apps** | The installer binary (`.intunewin`, package, VPP token) is not part of the exported JSON metadata. | Re-upload the binary, then re-map assignments. |
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

- **Conditional Access** policies — these belong to **Microsoft Entra ID**, not Intune.
- **Devices, users, Autopilot hardware hashes, reports / inventory data** — runtime data, not configuration.

## Handled, but tenant-dependent

- **Groups, filters, scope tags, app IDs** are **remapped by name** — the target objects must already
  exist (or be created) first; unresolved references are logged and skipped.
- **Managed Google Play / VPP apps** must be approved and synchronized in the target tenant before
  their app configurations apply.
- **Device inventory / reports data** is runtime telemetry, not configuration — out of scope. This kit
  clones **configuration**, not device data.

## Acknowledgements

Thanks to **Rudy Ooms** — Microsoft MVP, [call4cloud.nl](https://call4cloud.nl) — for flagging the
Device Inventory policies limitation.

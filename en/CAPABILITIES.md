> [🇫🇷 Version française](../fr/CAPACITES.md)

# IntuneTenantCloneKit — What it does (and does not)

> Honest positioning: the kit **duplicates the clonable configuration**; it is **not** a device or
> identity migration. Reflects **v2.3.0**.

## In brief

**IntuneTenantCloneKit** rebuilds a tenant's Intune **configuration** in another tenant (SOURCE → TARGET)
in minutes instead of weeks — with **automatic name-based remapping of groups and filters**, an
**object-by-object proof** of what landed, and an **AI assistant** that drafts the runbooks/scripts for
the remaining manual work. It is **not a device or identity migration**: those are re-created on the target.

> 💡 **Key distinction.** A *migration* moves **state** (devices, identities, tokens, licences). The kit
> duplicates the **configuration** (the shape of the policies). State, secrets and trust links are
> **re-created** — a **cryptographic** ceiling that **no tool** (this one, competitors, or Microsoft's
> native offering) crosses.

## Status legend

| Icon | Status | Meaning |
|:---:|---|---|
| ✅ | **Automated** | Cloned faithfully by the tool (after group/filter remap). |
| 🟡 | **Partial** | Structure cloned but reduced (secret/binary missing, created disabled, to be completed). |
| 🟠 | **Manual — AI-assisted** | Not cloned automatically; the **AI assistant** drafts the runbook + scripts (human review) to recreate it. |
| ❌ | **Out of reach** | Cryptographic/physical ceiling; **re-created** by the admin. No tool crosses it. |

## Coverage table — every element of the "migration"

### 🧩 Configuration profiles
| Element | Status | Detail |
|---|:---:|---|
| Settings Catalog (`configurationPolicies`) | ✅ | Settings posted *inline*, tree preserved verbatim. |
| Classic profiles (`deviceConfigurations`, OMA-URI) | 🟡 | Cloned; an OMA-URI with an **encrypted secret** is skipped (secret to re-enter). |
| Administrative Templates / ADMX | ✅ *(v2.3.0, experimental)* | Definitions/presentations remapped **by attributes**; an unresolved value is skipped (fail-closed). |
| App Configuration (ACP) | 🟡 | Requires the target app to be mapped, otherwise skipped. |

### 🛡️ Compliance
| Element | Status | Detail |
|---|:---:|---|
| Compliance policies | 🟡 | Cloned; a default block action may be **injected** if missing (review before enabling). |
| Notification templates | ✅ | Localized messages included. |
| Compliance scripts (custom) | 🟠 | Not automated yet (roadmap) — AI-assisted recreation. |

### 🔒 Endpoint Security
| Element | Status | Detail |
|---|:---:|---|
| Endpoint Security **modern** (`configurationPolicies`) | ✅ | Flows through the Settings Catalog. |
| Endpoint Security **legacy** (`intents`) | 🟠 | API **frozen** by Microsoft (~2025); manual/AI recreation as Settings Catalog. |
| Security baselines | 🟠 | Versioned / frozen; semi-manual. |

### 📱 Applications
| Element | Status | Detail |
|---|:---:|---|
| Store / winGet apps (metadata) | ✅ | Cloned. |
| Win32 / LOB / VPP / Managed Google Play | 🟡 → ❌ | Metadata clonable; **`.intunewin` binary and licences = out of reach** (re-upload + re-purchase). |
| App Protection / MAM | ✅ | Cloned. |

### 📜 Scripts & remediations
| Element | Status | Detail |
|---|:---:|---|
| PowerShell / Shell scripts (macOS) | ✅ | Content rehydrated. |
| Remediations (proactive) | ✅ | Cloned. |
| Custom attributes (macOS) | 🟠 | Not automated yet (roadmap). |

### 🔄 Windows Update
| Element | Status | Detail |
|---|:---:|---|
| Update rings | ✅ | Cloned. |
| Feature / Quality / Driver update profiles | ✅ | Cloned. |
| Quality update policies (expedite / hotpatch) | 🟠 | Not automated yet (roadmap). |

### 🖥️ Enrollment
| Element | Status | Detail |
|---|:---:|---|
| ESP, device limit, single-platform restriction, notifications | 🟡 *(v2.3.0, experimental)* | Created; **fail-closed**. |
| Tenant defaults / Windows Hello / co-management (singletons) | 🟠 | Not duplicated (priorities/singletons); configure on the target. |
| Apple ADE/DEP, Android COBO | ❌ | Pairing tokens. |

### 🔐 Certificates & network
| Element | Status | Detail |
|---|:---:|---|
| Trusted Root (public certificate) | 🟡 | Cloned (public part). |
| SCEP / PKCS / VPN / Wi-Fi (PSK) | 🟡 → ❌ | Shell cloned; **secret + connector = out of reach** (re-enter + re-pair NDES). |

### 🚪 Conditional Access (Entra, linked)
| Element | Status | Detail |
|---|:---:|---|
| Conditional Access policies | 🟡 | Created **disabled**, references remapped-or-refused, **enable manually**. |
| Named locations / Authentication strength / Terms of Use | 🟠 | Not exported/imported yet (roadmap); block some CA policies. |

### 👤 RBAC
| Element | Status | Detail |
|---|:---:|---|
| Custom roles + scope tags | ✅ | Cloned (built-in roles skipped). |
| Role assignments | 🟠 | Members/SPs = identity references (semi-manual). |

### ⚙️ Tenant administration
| Element | Status | Detail |
|---|:---:|---|
| Terms & Conditions (enrollment) | ✅ | Cloned. |
| Device categories | ✅ | Cloned. |
| Branding / Company Portal | 🟠 | Not automated yet (roadmap). |
| Connectors / partners (MTD…) | ❌ | Pairing. |

### 🎯 Assignments
| Element | Status | Detail |
|---|:---:|---|
| Groups (recreated by name) + assignments | ✅ | Name-based remap; missing groups recreated; **fail-closed** (an unresolved exclusion/filter is blocked, never widened). |
| Assignment filters | 🟡 | Remapped by name; not auto-recreated in some flows. |

### 🚫 State & identity — the ceiling (re-created; no tool clones it)
| Element | Status | Detail |
|---|:---:|---|
| Enrolled devices / Autopilot hashes | ❌ | Identity **sealed to the tenant** → physical re-enrollment. |
| Users / groups (Entra identities) | ❌ | To re-provision / re-sync. |
| Secrets (Wi-Fi/VPN/PFX/OMA) | ❌ | Encrypted by design → manual re-entry. |
| Tokens & connectors (APNs/ADE/VPP/MGP/NDES) | ❌ | Re-pairing. |
| App binaries & licences | ❌ | Re-package (Content Prep Tool) + re-purchase. |

## What makes it unique

- 🧾 **Proof.** Every run emits an **object-by-object reconciliation report** (JSON + HTML): what landed,
  what failed, why. A security policy that didn't apply → red banner + non-zero exit code.
- 🔒 **Fail-closed security.** An unresolved exclusion **blocks** the object (never silently widens scope);
  never writes to the source tenant; secrets are never exfiltrated; app-only, least privilege.
- 🤖 **AI assistant for the rest (opt-in).** For everything marked 🟠, the AI drafts the **runbooks + scripts**
  (PowerShell/Graph, human review) — it **guides**, it does not migrate anything for you.

## What is always manual (the ceiling, summarized)
Re-entering **secrets** · re-pairing **tokens/connectors** (Apple/Google/PKI) · re-enrolling **devices** ·
re-uploading **binaries** + re-purchasing **licences** · re-wiring **Entra references**.

## Disclaimers
- **No device is migrated**; re-enrollment required. · **Secrets are not transferred** (re-enter). ·
  **Conditional Access is created disabled** (enable manually). · **ADMX/Enrollment import is experimental**
  (v2.3.0) — run in **PREVIEW** first. · **GUIDs are not preserved** (new IDs on the target).

---
See also: [`LIMITATIONS.md`](LIMITATIONS.md) · [`../CHANGELOG.md`](../CHANGELOG.md) · reflects **v2.3.0**.

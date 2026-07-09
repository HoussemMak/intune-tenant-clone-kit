> [🇫🇷 Version française](../fr/EXECUTER_AUTO.md)

# EXECUTER_AUTO — ZERO-TOUCH execution (no human intervention)

Full cycle **Export → Cleanup → Import (waves) → Assignments → Verification → Report**,
driven by **a single command**, with no copy-paste, no sign-in popup, no confirmation.

> Difference from [`EXECUTER.md`](EXECUTER.md) (manual step-by-step mode, interactive sign-in):
> here authentication is **app-only via certificate** and the sequence is fully unattended end to end.

---

## What remains (one time) vs what is automatic

| One time (setup, admin) | Every run (100% automatic) |
|---|---|
| Create the app registration + certificate + admin consent in **each** tenant | Export, backup, cleanup, preflight, wave import, assignments, verification, report |

App-only is **the only way** to be truly unattended: Microsoft requires an application
identity (app registration + application permissions + admin consent) for any sign-in
without a human. Once set up, no further intervention is required — including in a scheduled task.

---

## Step A — Prepare the app-only identities (once per tenant)

Signed in as **administrator** (Global Admin, or Privileged Role Admin + Application Admin):

```powershell
$Kit = 'C:\path\to\intune-tenant-clone-kit'   # <-- edit

# SOURCE tenant (READ permissions)
& "$Kit\tools\New-IntuneCloneKitAppRegistration.ps1" -TenantId <SOURCE_TENANT_ID> -Role Source

# TARGET tenant (WRITE permissions)
& "$Kit\tools\New-IntuneCloneKitAppRegistration.ps1" -TenantId <TARGET_TENANT_ID> -Role Target
```

Each call prints, at the end, the `…ClientId` / `…CertThumbprint` lines to paste into `config.ps1`.

> The certificate is created in `Cert:\CurrentUser\My` of the account that runs the helper. The orchestrator
> must run under **the same account / the same machine** (or import the certificate wherever it will run).
> Application permissions granted: `DeviceManagement*.{Read|ReadWrite}.All`, `Group.{Read|ReadWrite}.All`,
> `Organization.Read.All` (RBAC included for Scope Tags).

## Step B — Fill in `config.ps1`

```powershell
Copy-Item "$Kit\config.example.ps1" "$Kit\config.ps1"
# edit config.ps1: SourceTenantId, TargetTenantId, then
#   SourceClientId / SourceCertThumbprint / TargetClientId / TargetCertThumbprint
```

## Step C — Launch the zero-touch execution (PowerShell 7)

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1"
```

That's all. Everything is read from `config.ps1`. At the end: HTML report in `output\`, logs in `logs\`.

### Best practice: a dry run first

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1" -Preview
```

`-Preview` does the export + all previews **without any writes** (no objects created,
no groups, no assignments). Review it in the report, then rerun without `-Preview`.

---

## Useful parameters

| Parameter | Effect |
|---|---|
| `-Preview` | Full simulation, no writes. |
| `-SourcePath <folder>` | Reimport an already produced export instead of exporting anew. |
| `-ImportReport <file>` | Clean up a previous failed import before reimporting (otherwise auto-detected in `input\`). |
| `-SkipAssignments` | Do not migrate groups + assignments. |
| `-SkipVerification` | Do not run the final SOURCE vs TARGET count. |
| `-SkipApps` / `-SkipScripts` / `-SkipMobile` | Skip an import wave. |
| `-IncludeScopeTags` | Keep the `roleScopeTagIds` (requires RBAC.ReadWrite on the target). |
| `-StaticOnlyGroups` | Recreate dynamic groups as empty static ones (safer in a sandbox). |
| `-StopOnImportErrors` | Abort if a wave contains errors. |
| `-AllowInteractive` | Fall back to interactive sign-in if no app-only (breaks zero-touch). |

Without `config.ps1`, everything can be passed as parameters:

```powershell
pwsh -File "$Kit\Invoke-IntuneCloneKit-Unattended.ps1" `
  -SourceTenantId <SRC> -TargetTenantId <TGT> `
  -SourceClientId <APPSRC> -SourceCertThumbprint <THUMBSRC> `
  -TargetClientId <APPTGT> -TargetCertThumbprint <THUMBTGT>
```

---

## Scheduled execution (truly unattended)

Since the certificate is in the store, the orchestrator can run as a scheduled task:

```powershell
$act = New-ScheduledTaskAction -Execute 'pwsh.exe' `
  -Argument '-NoProfile -File "C:\path\to\intune-tenant-clone-kit\Invoke-IntuneCloneKit-Unattended.ps1"'
$trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 3am
Register-ScheduledTask -TaskName 'IntuneCloneKit-ZeroTouch' -Action $act -Trigger $trg -RunLevel Highest
```

---

## What remains manual (Intune limits, not bypassable)

Secret-bearing profiles (Wi-Fi/PSK, AppLocker/WDAC, encrypted OMA), LOB/Win32/VPP apps (binaries),
Admin Templates, Endpoint Security (intents), Enrollment: not clonable from metadata alone.
They are **skipped cleanly** (status `SKIP_*`) and listed in the report for manual follow-up.

> [🇫🇷 Version française](../fr/DISCLAIMER.md)

# Disclaimer

This kit is provided **"as is", without warranty of any kind**, express or implied. The authors and
contributors cannot be held liable for any damage, configuration loss, or service interruption
resulting from its use.

**Scope:** this kit duplicates the *clonable Intune configuration* tenant-to-tenant. It is **not** a device, identity, or tenant migration — devices re-enroll and secrets & tokens are re-created / re-paired manually.

- It **writes** to a Microsoft Intune tenant. A wrong target can modify a production environment.
- **Always** start on a **sandbox / test** tenant, in preview mode (PREVIEW), and **back up** the
  target before any write (see `EXECUTER.md`, backup step).
- You are solely responsible for holding the required **authorizations** on the tenants involved.
- Some data can **never** be migrated automatically (secrets, application binaries): this is a
  Microsoft Intune limitation, not a defect of the kit.
- Review that your usage complies with your organization's policies before any deployment.

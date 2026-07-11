# intune-tenant-clone-kit

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg) ![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE.svg?logo=powershell&logoColor=white) ![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-beta-0078D4.svg) ![Docs EN | FR](https://img.shields.io/badge/docs-EN%20%7C%20FR-informational.svg) ![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

Reliably clone a Microsoft Intune configuration from one tenant to another
(fresh **export → correct → import**). PowerShell 7 + Microsoft Graph.

> **We clone the configuration; we guide the rest.** This kit duplicates the
> *clonable* Intune **configuration** tenant-to-tenant — it is **not** a device
> or identity migration (devices re-enroll, secrets & tokens re-pair).
> *On clone la configuration, on guide le reste. Le kit duplique la
> **configuration** Intune clonable — ce n'est **pas** une migration d'appareils
> ni d'identités (les appareils se ré-enrôlent, les secrets et jetons se re-jumellent).*

![intune-tenant-clone-kit architecture](assets/architecture.png)

## Choose your language · Choisissez votre langue

| | |
|---|---|
| 🇬🇧 **English** | [`en/`](en/) — [read `en/README.md`](en/README.md) |
| 🇫🇷 **Français** | [`fr/`](fr/) — [lire `fr/README.md`](fr/README.md) |

Each folder is a **complete, self-contained bundle** in its language (scripts, docs, sample export).
*Chaque dossier est un **bundle complet et autonome** dans sa langue (scripts, docs, exemple).*

> 📊 **Capability table · Tableau de capacités** — every Intune element, status by status:
> [🇬🇧 `en/CAPABILITIES.md`](en/CAPABILITIES.md) · [🇫🇷 `fr/CAPACITES.md`](fr/CAPACITES.md)

![What the kit clones vs. what re-pairs — at a glance](assets/overview.png)

> ⚠️ Read the DISCLAIMER before any use. Test on a sandbox tenant first.
> *Lire le DISCLAIMER avant tout usage. Toujours tester sur un tenant de bac à sable.*

## License · Licence

[MIT](LICENSE).

# SCWebManager

A browser-based management panel for Survivalcraft servers, developed and maintained by **JIILNetTechStudio**.

> **This repository is for distribution only**: it hosts installer scripts, the version manifest and release downloads.
> The product source code is not public and is not included here.
> Copyright © JIILNetTechStudio. All rights reserved. Copying, redistributing, reverse engineering or any commercial use without written permission is prohibited.

Out of the box: create an instance → start the server → watch the console → manage players and inventories → view the world map → install mods and edit configs → set permissions and scheduled jobs. Everything runs in the browser — no client to install.

---

## Highlights

1. **Deep in-game plugin integration**
   The panel installs the in-game plugin automatically with each instance (it only overwrites the DLL, never your config). Online players, inventories, world data and TPS all come from the plugin in real time. If the plugin is missing, the panel says so and offers a one-click install instead of showing empty pages.

2. **Visual inventory editor**
   Survival and creative inventories (including the clothing slots) are shown slot by slot with validation of quantity and slot rules (clothing slots cannot be swapped with backpack slots). Saving writes straight back to the instance; bulk clearing is supported.

3. **World map rendering with player trails**
   The panel parses save Region files and renders a top-down PNG map with player markers; clicking a marker shows that player's trail and lets you center or teleport.

4. **Multiple instances and container migration**
   One panel manages many instances, and the instance root can be moved to another disk. Migration is lock-guarded (stop → copy → remove old → update record) so nothing is copied twice or deleted by accident.

5. **Event-driven scheduled jobs**
   Besides cron syntax, jobs can react to instance start / stop / crash, TPS below a threshold, or file changes. An "AI job" type runs a prompt unattended on schedule. JSON import/export, per-run timeout, elevated execution and trigger cooldown are supported.

6. **AI assistant with approval and audit**
   Multiple model providers, risk-tiered tool calls (dangerous commands are hard-rejected, unknown ones need approval), rollback of each round's changes, full audit trail, and an isolated workspace that never touches instance directories.

7. **SCKey unified login**
   Players are verified through SCKey before joining, filtering out alt accounts and pirated clients. A three-step wizard binds the instance and writes only the required config fields, leaving existing settings untouched.

8. **Notification guardian**
   Instance crashes, daemon disconnects and CPU / memory / disk threshold breaches can be pushed via SMTP email or Webhook. Even with notifications off, incidents are recorded in the audit log and panel log and surfaced the next time you open the page.

9. **Whole-package auto update**
   Panel, daemon and updater upgrade together: the package is downloaded and verified, a pending-update flag is set, and the daemon launches the updater only when **all instances are stopped**, then restarts the panel — online players are not interrupted.

10. **Fine-grained permissions**
    Groups plus menu-level permissions plus per-instance grants (console, files, backup, resource limits and instance settings are granted separately). File access has three tiers — instance-only, whole-disk read, whole-disk read/write — and regular users only see the instances assigned to them.

11. **Three ways to edit configs**
    JSON and other config files can be edited as key/value forms, as a tree view, or as raw source. GBK / UTF-8 is detected automatically, so Chinese text never turns into mojibake.

12. **Terminal and quick commands**
    Real shell sessions on the host (PowerShell / CMD on Windows, bash on Linux) persist while the panel runs; the console supports preset quick commands sent with one click.

13. **Resource limits and performance charts**
    Per-instance CPU / memory thresholds with an over-limit strategy, plus live TPS and performance charts on the dashboard.

14. **Three backup layers**
    World backups, whole-instance zip backups (custom destination supported) and instance cloning — quick recovery after a bad change.

15. **Standalone maintenance tool (scweb-manage)**
    Installed by the setup script, one copy per machine: desktop and Start Menu shortcuts on Windows, a `~/.local/bin/scweb-manage` command on Linux. Menu actions: start the panel, view autostart state, repair (replace program files, keep config and data), fresh install (adds an instance without touching existing ones), uninstall, check for updates (custom version with validation and pre-release warnings), and set an alias. With multiple panels it first lists each instance's directory, version and install time.

16. **Unified install registry and HTTPS**
    Setup scripts, panels and the maintenance tool share one install registry (Windows registry / Linux config file), and the panel syncs the version after updates. The panel lists all local panel instances and can set aliases. The settings page accepts PEM certificate and private key plus the bound domain; if the certificate is missing, expired or does not match the domain, the panel falls back to HTTP at startup instead of failing to open.

## Modules

| Module | Capabilities |
| --- | --- |
| Dashboard | Instance status, TPS and performance charts, online players, world summary |
| Instances | Create / import / install server, start / stop / restart, console commands |
| Players | Online and offline lists, attributes, visual inventory editing, chat and join/leave history |
| World and map | Region-rendered map, player markers and trails, teleport, world editing |
| Mods | `.netmod` upload, install / uninstall, version detection, NetMods management |
| Files | Browse / upload / download / edit, three access tiers, three editing modes |
| Console | Live log stream, customizable color rules, quick commands |
| Terminal | Multi-session host shell with highlighted output |
| Scheduled jobs | cron, event triggers, AI jobs, JSON import/export, run logs |
| Backup | World backup, whole-instance backup, instance clone |
| Notification guardian | Crash / disconnect / resource alerts via email and Webhook |
| SCKey login | Player verification, wizard binding, rebind and unbind |
| AI assistant | Multi-model, tool calls with approval, rollback, audit, isolated workspace |
| Users and permissions | Super admin / admin / regular user, groups, permissions, instance grants |
| Audit | Logins, permission changes, dangerous operations and AI activity |
| Settings | Port, bind address, site title, access scope, log retention, highlight rules, HTTPS certificate, plugin site address, panel instance list and aliases, UI scale, languages (Chinese / English / Traditional Chinese) |
| Maintenance tool | `scweb` (`scweb-manage` on Windows): start, autostart state, repair, fresh install, uninstall, check updates, set alias |

## Supported platforms

| Platform | Requirement | Architecture |
| --- | --- | --- |
| Windows | Windows 10 / Windows Server 2016 or later | x64, ARM64 |
| Linux | x86_64 / aarch64, mainstream distributions | amd64, arm64 |

Ports: panel `18233`, daemon `18234`, in-game plugin `18244` (installed per instance automatically).

## Installation

Windows (PowerShell):

```powershell
irm https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.ps1 | iex
```

Linux:

```bash
curl -fsSL https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.sh | bash
```

The installer detects the CPU architecture, asks where to install, then starts the daemon and panel and prints the access URL and initial administrator credentials.

It also installs the maintenance tool: on Windows at `%LOCALAPPDATA%\SCWebManager\scweb-manage.exe` with desktop and Start Menu shortcuts; on Linux at `~/.local/bin/scweb`, runnable as `scweb` (the script adds that directory to PATH and registers a global command when `/usr/local/bin` is writable).

If the chosen directory already contains a panel: when it is running you are asked to stop it before reinstalling; when it is stopped you choose between overwrite (keep config and data) and a fresh install in another directory.

Optional arguments: `-1 <dir>` install directory, `-2 <version>`, `-f` silent install, `-json` machine-readable result.

## Manual installation

1. Open the [releases](https://gitee.com/JIILStudio/jiilsc-web-manger/releases) page and download the package for your platform and architecture.
2. Extract to any directory (keep the existing `data` directory to preserve settings and data).
3. Run `scweb-daemon` first (`scweb-daemon.exe -dir <dir>` on Windows), then `scweb-panel`.
4. Open `http://127.0.0.1:18233` and sign in with the initial account printed in the startup log.

## Checksums

`SHA256SUMS` in each release lists the SHA-256 of every package. It is a text file, not a program.

```powershell
Get-FileHash .\scweb-1.5.9-windows-amd64.zip -Algorithm SHA256
```

```bash
sha256sum -c SHA256SUMS
```

## Repository files

| File | Purpose |
| --- | --- |
| `install.ps1` | Windows installer |
| `install.sh` | Linux installer |
| `versions.json` | Version manifest used by installers |
| `version.json` | Update manifest used by the panel |
| `true-list.json` | Minimum OS version requirements |
| `gg.txt` | Announcement text fetched by the panel |
| `ver-pp.json` | Server version presets (one-click install and architecture hints) |

## Updates

The panel checks for updates after login and from Settings → Update. Updates are whole-package: the correct build for the current platform is downloaded and verified, then the daemon replaces all three binaries and restarts the panel once every instance is stopped.

## Feedback

- Community: QQ group **750395354** (mention SCWebManager when joining)
- Forum: <https://bbs.jiil.top>
- Email: <support@jiil.top>

Please include your OS version, CPU architecture, installation method, panel version and any related logs (`data/startup-error.log`, `panel.err.log`).

---

**Copyright**: all rights to this product (packages, UI, documentation) belong to JIILNetTechStudio. This repository is for distribution only and grants no rights to the source code. Redistribution (including republishing on other platforms or bundling into other products), decompilation and republishing of modified builds are prohibited.

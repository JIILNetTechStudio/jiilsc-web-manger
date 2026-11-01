# SCWebManager

A one-stop management panel for Survivalcraft servers, developed and maintained by **JIIL Studio**.

> **This repository is for distribution only**: it hosts installer scripts, the version manifest and release downloads.
> The product source code is not public and is not included here.
> Copyright © JIIL Studio (JIILStudio). All rights reserved. Copying, redistributing, reverse engineering or any commercial use without written permission is prohibited.

---

## Features

- Instance management: start / stop / restart, memory watchdog and auto-restart, online config editing
- Player management: online and offline lists, attributes, inventory viewer and editor, chat and join/leave history
- Map: world render viewer, player markers, movement trails with time travel
- Files and mods: online file manager, mod upload and versioning, one-click updates
- Console: live log stream, command execution, command history
- Scheduled tasks: cron syntax, command / script jobs with audit trail
- AI assistant: multiple model providers, tool calling with tiered approval, per-conversation rollback
- Security: login protection, RBAC permission groups, audit log, network self-check

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

Optional arguments: `-1 <dir>` install directory, `-2 <version>`, `-f` silent install, `-json` machine-readable result.

## Manual installation

1. Open the [releases](https://gitee.com/JIILStudio/jiilsc-web-manger/releases) page and download the package for your platform and architecture.
2. Extract to any directory (keep the existing `data` directory to preserve settings and data).
3. Run `scweb-daemon` first (`scweb-daemon.exe -dir <dir>` on Windows), then `scweb-panel`.
4. Open `http://127.0.0.1:18233` and sign in with the initial account printed in the startup log.

## Checksums

`SHA256SUMS` in each release lists the SHA-256 of every package. It is a text file, not a program.

```powershell
Get-FileHash .\scweb-1.5.8-windows-amd64.zip -Algorithm SHA256
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

## Updates

The panel can check for and install updates from its settings page. The correct package for the current platform is downloaded, verified, and applied by the daemon when all server instances are stopped.

## Feedback

Please open an issue with your OS version, CPU architecture, installation method and any related log (`data/startup-error.log`, `panel.err.log`).

---

**Copyright**: all rights to this product (packages, UI, documentation) belong to JIIL Studio (JIILStudio). This repository is for distribution only and grants no rights to the source code. Redistribution (including republishing on other platforms or bundling into other products), decompilation and republishing of modified builds are prohibited.

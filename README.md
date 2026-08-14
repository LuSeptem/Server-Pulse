# Server Pulse

English user manual · [中文说明](README.zh-CN.md)

Server Pulse is a native Windows desktop widget for watching GPU, VRAM, CPU, and memory usage on SSH servers in real time. It is not a web application: it does not need a browser and does not start a local HTTP service.

The repository seed configuration contains two SSH aliases, `3090` and `a6000`. Existing key-based SSH and `ssh-agent` setups continue to work, and the server manager can also use an ordinary account password.

## What you can do

- Watch several SSH servers in one compact, always-on-top floating window.
- Focus on each GPU's utilization, VRAM, temperature, and model name.
- Inspect CPU, system memory, and per-GPU VRAM attribution by user; user details are hidden until you hover or click a metric.
- Dock the window to the left, right, or top edge, adjust its size, background opacity, and refresh interval.
- Restore, hide, or exit from the system tray without keeping a duplicate taskbar window.
- Switch between dark, light, and system themes, and between Chinese, English, and system language.
- Query minute-level CPU, memory, GPU, VRAM, and temperature history.
- Choose a retention period from 1–3650 calendar days or **Never clean up**, and move the complete local data root from the History page.

## Screenshots

The images in `demo/` are sanitized examples; host addresses and usernames are blurred.

| Dark main window | Light main window |
| --- | --- |
| ![Dark main window](demo/dark_main_ui.png) | ![Light main window](demo/light_main_ui.png) |

| SSH server manager | Add SSH server |
| --- | --- |
| ![SSH server manager](demo/manage_servers.png) | ![Add SSH server](demo/add_server.png) |

| Usage history | History details and user curves |
| --- | --- |
| ![Usage history](demo/usage_history.png) | ![History details](demo/usage_history_details.png) |

## Quick start

### Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 and WPF (included with Windows).
- An OpenSSH client available as `ssh.exe`.
- A Linux remote host with `/proc`, POSIX `sh`, and `nvidia-smi`. Without NVIDIA GPUs, CPU and memory monitoring still works.

### Start the application

Double-click `ServerPulse.exe`. You can also double-click `Start Server Pulse.vbs`; it prefers the EXE and falls back to the PowerShell entry point when the EXE is absent.

To see startup errors from a terminal:

```powershell
.\ServerPulse.exe
# or run the script directly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ServerPulse.ps1
```

Before the first run, check existing passwordless SSH aliases:

```powershell
ssh -o BatchMode=yes 3090 hostname
ssh -o BatchMode=yes a6000 hostname
```

If both commands return a hostname, open **Manage**, select the servers, and choose **Verify and apply**.

## SSH servers and authentication

Open **Manage** beside the online count in the main window, or choose **SSH servers** from the tray menu.

Candidates are merged from:

1. `config/servers.json` in this repository;
2. concrete, non-wildcard `Host` entries in the current Windows user's `~/.ssh/config`;
3. servers added manually in the manager.

The **Monitor** checkbox controls whether a server produces a live card. A server that is not authenticated remains paused and does not block other servers.

### Authentication order

The fixed order is:

1. Passwordless SSH using a key or `ssh-agent` (`BatchMode`);
2. a password saved in Windows Credential Manager;
3. a password entered for the current run only.

The **Passwordless login** checkbox is a verification result, not a way to bypass SSH authentication. Hover the `!` icon for an explanation of keys, `ssh-agent`, Credential Manager, and normal terminal SSH.

Windows Credential Manager is built into Windows; no separate installation is needed. Credentials saved by Server Pulse are used only by Server Pulse. A normal terminal `ssh` command does not read them, and the application does not modify global OpenSSH or `SSH_ASKPASS` settings.

The password field is not saved by default. A credential is written only after you explicitly select **Save to Windows Credential Manager** and verification succeeds. Session-only passwords are cleared when monitoring is cancelled or the application exits; they are never written to server configuration, logs, or history.

For a new host, the manager shows the host-key algorithm and SHA256 fingerprint before writing to the current user's `known_hosts`. A changed fingerprint blocks the connection and is never overwritten automatically.

Each monitored server uses one long-lived SSH collection session. After a network failure, reconnects use backoff (5 s, 15 s, 30 s, 1 min, then 5 min) with jitter. Repeated failures enter a circuit-breaker pause and show the next retry time; **Recheck** immediately clears that pause. This avoids opening a new SSH connection on every refresh.

## Main window

### Top bar

- **Theme**: Light, Dark, or Follow system (Dark by default).
- **Language**: Chinese, English, or Follow system (Chinese is the current default).
- **Opacity**: changes only the background opacity; text, status lights, and progress bars remain clear.
- **Always on top**: the upward-arrow button toggles topmost mode.
- **Dock**: the edge-arrow button enables left, right, and top edge hiding.
- **Refresh**: enter `1`–`300` seconds, then press Enter or leave the field.
- **History**: open the usage-history window.
- **Manage**: open SSH server management.

### Move, dock, and tray

- Drag an empty area of the title bar to move the window.
- Drag the dotted handle in the lower-right corner to resize it; the minimum is approximately 340 × 300.
- Drag to the left, right, or top edge. After a short delay the window retracts to a narrow edge strip.
- Move the pointer away from the edge, then touch that edge again to restore it. Keeping the pointer inside the expanded window does not start the retract timer; leaving the whole window does.
- The `—` button hides the window to the tray; `×` exits. Left-click the tray icon to restore, or right-click for show, hide, and exit.

## Metrics and user details

- **CPU** is the whole-server CPU percentage.
- **MEM** shows percentage and used/total memory, for example `73% · 92.2/125.5 GB`.
- **GPU** cards show the model, utilization, used/total VRAM, and temperature.

Hover a CPU, MEM, or per-card VRAM value/progress bar to preview user attribution. Click to pin the panel; click the same metric again, click empty space, or press `Esc` to close it. Clicking another metric replaces the pinned panel. The first eight users by current usage are shown, with **System / unattributed** always listed separately at the end.

Attribution status can be **ok**, **partial**, or **unavailable**. Permission problems are reported explicitly and are never displayed as zero usage.

## History, curves, and storage

Click the prominent **History** button. The default query is the most recent hour. Start and end fields accept year, month, day, hour, and minute independently; invalid or out-of-range values are marked with a red border and `!`.

History supports:

- Independent visibility switches for GPU, VRAM, and temperature curves;
- Minute-level hover markers with the complete timestamp and all metrics from that minute;
- Click-to-pin detail panels and double-click-to-unpin behavior;
- Up to three selected user curves per chart, with stable colors and removable labels;
- Gaps for missing monitoring data instead of connecting points across the gap;
- Mixed reading of legacy JSON and the append-only JSONL format on the same date.

### Local history layout

History stays on the current Windows user's machine. The default data root is `%LOCALAPPDATA%\\ServerPulse\\`. The first visit to History asks you to save a policy, preselecting 7 days. The query range has no separate maximum; an interval earlier than retained data simply reports that no records are available.

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json           # UI, refresh, and retention settings
├─ servers.json            # server list; no passwords
├─ error.log               # local error summary
└─ history\\
   ├─ yyyy-MM-dd.v2.jsonl  # new format: one appended minute record per line
   └─ yyyy-MM-dd.json      # legacy format; still read
```

Storage rules:

- New records append to `yyyy-MM-dd.v2.jsonl`. Retention is calendar-day based and accepts 1–3650 days; **Never clean up** disables automatic deletion.
- Corrupt or out-of-range settings return safely to the unconfigured state and ask for confirmation on the next History visit; they do not stop the main monitor.
- Saving History settings applies retention, Never clean up, and cleanup-paused state together. Invalid input stays in the dialog and does not stop monitoring.
- Legacy JSON and new JSONL can be queried together; old files are not migrated or deleted.
- Duplicate records for the same minute are merged using valid-sample counts. A user absent from an available sample contributes zero; unavailable samples are excluded from that resource's denominator. Legacy records without user fields create a curve gap, not a false zero.
- Cleanup handles both `.json` and `.v2.jsonl`. Removing the `history` folder removes records only, not UI settings or server configuration.
- Files contain UID, username, and minute aggregates, never PIDs, process names, command lines, or passwords.

History can contain sensitive operational information. Never commit `%LOCALAPPDATA%\\ServerPulse\\history` or any live `servers.json` to a public repository.

### Data-root settings, migration, and fallback

The **History settings** path is the complete data root, not only the `history` subfolder. Environment variables such as `%LOCALAPPDATA%` are accepted. The path must be a local absolute path; relative paths and UNC network paths are rejected. Missing directories are created and read/write access is tested before saving.

Changing the path first flushes the current minute, pauses new history writes, and shows a migration summary. If the destination contains matching names, choose overwrite, automatic merge, or cancel; cancel is the default. Overwrite creates a backup first. Automatic merge de-duplicates identical JSON/JSONL records, keeps conflicting minute records, and appends `error.log`. A successful migration renames the old root to a timestamped backup and atomically updates:

```text
%LOCALAPPDATA%\\ServerPulse.location.json
```

This pointer stores only the preferred/active root and synchronization state. Windows credentials are not migrated. If a preferred root disappears or loses permission, the current run explicitly falls back to the default root and asks you to choose again; it never silently switches to an unknown directory.

## Local configuration

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json       # theme, language, position, size, refresh, retention
├─ servers.json        # current server list; no passwords
├─ history\\            # minute history
└─ error.log           # UI/history error summary
```

Persistent passwords are stored by Windows Credential Manager under a normalized `username@host:port` identity, not in these JSON files. The repository `config/servers.json` is only a first-run seed and contains no password.

## Repository layout

```text
server_monitoring/
├─ ServerPulse.exe          # runnable Windows host
├─ ServerPulse.ps1          # main window entry point
├─ Start Server Pulse.vbs   # compatibility launcher
├─ assets/                  # SVG/ICO icons
├─ config/                  # first-run seed configuration
├─ scripts/                 # build scripts
├─ src/                     # collector, history, storage, SSH, theme, and host code
├─ tests/                   # automation and mock SSH
├─ docs/DEVELOPMENT.md      # contributor/developer documentation
├─ README.md                # English user manual
└─ README.zh-CN.md          # Chinese user manual
```

## Troubleshooting

**A server is offline.** Run `ssh -o BatchMode=yes <alias> hostname` and check the alias, key, VPN, jump host, and host fingerprint. One failed server does not block the others.

**GPU count is zero.** Run `nvidia-smi` on the remote host. CPU and memory collection does not require NVIDIA tools.

**User attribution is partial.** `/proc` or NVIDIA process visibility may be restricted, or a process may have exited between samples. The aggregate metric remains available and the attribution status is shown.

**Will a saved password be used by terminal SSH?** No. It is available only to Server Pulse; terminal `ssh` continues to use its own keys, agent, or interactive password flow.

**The window is hidden.** Touch the enabled edge or click the tray icon. If its position is unusable, remove `%LOCALAPPDATA%\\ServerPulse\\settings.json` to restore defaults.

**How should I report a problem?** Include the app version, Windows version, EXE/script mode, reproduction steps, and a sanitized `error.log`. Never upload history, passwords, private keys, real host addresses, or user lists.

## Development

Architecture, collection protocol, history format, building, testing, security boundaries, and the release checklist are in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). End users only need this manual.

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for the complete text.

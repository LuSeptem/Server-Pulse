# Server Pulse

English user manual · [中文说明](README.zh-CN.md)

Server Pulse is a native Windows desktop widget for watching GPU, VRAM, CPU, and memory usage on SSH servers in real time. It is not a web application: it does not need a browser and does not start a local HTTP service.

The repository seed configuration contains two SSH aliases, `3090` and `a6000`. Existing key-based SSH and `ssh-agent` setups continue to work, and the server manager can also use an ordinary account password.

Current release: **v1.1.0** · [Bilingual release notes](CHANGELOG.md)

## Tauri 2.0 Preview

The `codex/tauri-port` branch contains the cross-platform rewrite. It keeps the existing PowerShell/WPF release as the `port-baseline-v1.1.0` tag while the new application is developed in the same repository. The Preview targets Windows 10/11 x64 and macOS Intel/Apple Silicon; Linux desktop is out of scope for v1.

The current vertical slice includes the Vue 3 + TypeScript monitor window, Pinia event state, ECharts history view, tray and secondary windows, Tokio collectors, the canonical POSIX sampler, JSON/JSONL storage, data-root migration primitives, system OpenSSH, OpenSSH config discovery and diagnostics, SSH-config-aware host-key probing, legacy Windows server-config migration, host-key confirmation, OS-keyring and session-only password authentication, persistent framed SSH collection, retry backoff, and redacted error events. Windows SSH helper processes are hidden when the Preview is launched from Explorer, and a failed automatic start is shown on its server card without aborting other servers. The Preview is unsigned and intended for internal testing. macOS UI behavior has not been verified on a physical Mac; macOS code is kept compile-compatible.

From the repository root:

```powershell
npm ci --prefix frontend
npm --prefix frontend run typecheck
npm --prefix frontend run test:unit
npm --prefix frontend run build
cargo test --workspace --manifest-path src-tauri/Cargo.toml
npm --prefix frontend exec -- tauri build --config src-tauri/tauri.conf.json --ci
```

The complete scope, milestones, CI matrix, migration rules, and acceptance gates are documented in [`docs/TAURI-PORT-PLAN.md`](docs/TAURI-PORT-PLAN.md). Do not treat this branch as a stable public release.

## What you can do

- Watch several SSH servers in one compact, always-on-top floating window.
- Focus on each GPU's utilization, VRAM, temperature, and model name.
- Inspect CPU, system memory, and per-GPU VRAM attribution by user (displaying active process counts such as `(x2)` when >= 2); user details are hidden until you hover or click a metric.
- Dock the window to the left, right, or top edge, adjust its size, background opacity, and refresh interval.
- Restore, hide, or exit from the system tray without keeping a duplicate taskbar window.
- Switch between dark, light, and system themes, and between Chinese, English, and system language.
- Query minute-level CPU, memory, GPU, VRAM, and temperature history.
- Choose a retention period from 1–3650 calendar days or **Never clean up**, and move the complete local data root from the History page.
- Inject a persistent server-side monitoring agent for any saved server, check its status and control it from Manage, and merge its records into local history — monitoring continues while the app is closed.

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

- Windows 10/11 x64 or macOS (Intel / Apple Silicon).
- An OpenSSH client available as `ssh.exe` (Windows) or `ssh` (macOS).
- A Linux remote host with `/proc`, POSIX `sh`, and `nvidia-smi`. Without NVIDIA GPUs, CPU and memory monitoring still works.

### Start the application

- **Direct Portable Run**: Double-click `ServerPulse-Portable.exe` in the repository root (standalone portable build).
- **Development Mode**:
  ```powershell
  # Start desktop dev window
  npm run tauri dev --prefix frontend
  # Or start frontend browser preview
  npm run dev --prefix frontend
  ```
- **Build Release Bundle**:
  ```powershell
  npm run build --prefix frontend
  cargo build --release --manifest-path src-tauri/Cargo.toml
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

1. the existing data-root `servers.json` (including the legacy Windows `Servers` / `SshTarget` / `HostName` schema);
2. concrete, non-wildcard `Host` entries in the current user's `~/.ssh/config` and `Include` files, automatically resolved via OpenSSH `ssh -G`;
3. servers added manually in the manager.

The manager provides an **Add server** form, a **Reload** action, interactive discovered alias badges, and a **Discovered from SSH config** candidates section with one-click **+ Add to monitor** and **Import all**. Discovered aliases automatically resolve default hostnames, ports, and usernames. Passwords are never written to `servers.json`. The page shows the exact config path, discovered aliases, candidates, and any read error.

The **Monitor** checkbox controls whether a server produces a live card. A server that is not authenticated remains paused and does not block other servers.

### Authentication order

When password authentication is selected, the fixed order is:

1. a password entered for the current run only;
2. a password saved in Windows Credential Manager or macOS Keychain;
3. a key or `ssh-agent` identity.

The **Passwordless SSH** checkbox selects key/`ssh-agent` authentication with `BatchMode=yes`. Turn it off when the server needs a password. The manager can use the password only for the current run, or save it explicitly in the OS credential store.

Windows Credential Manager is built into Windows; no separate installation is needed. Credentials saved by Server Pulse are used only by Server Pulse. A normal terminal `ssh` command does not read them, and the application does not modify global OpenSSH or `SSH_ASKPASS` settings.

The password field is not saved by default. A credential is written only after you explicitly select **Save password in the OS credential store** and verification succeeds. Session-only passwords are cleared when monitoring stops, verification is cancelled, or the application exits; they are never written to server configuration, command lines, ordinary environment variables, logs, or history.

For a new host, the manager—or the first automatic monitoring start—shows the host-key algorithm and SHA256 fingerprint before writing to the application data-root `known_hosts`. The user's existing `~/.ssh/known_hosts` is read-only compatibility input. A changed fingerprint blocks the connection and is never overwritten automatically; use **Forget application key and reverify** only after checking the new fingerprint.

Each monitored server uses one long-lived SSH collection session. The remote sampler emits framed protocol-v2 snapshots over that connection. After a network failure, reconnects use backoff (5 s, 15 s, 30 s, 1 min, then 5 min) with jitter. Repeated failures enter a circuit-breaker pause and show the next retry time; **Recheck** immediately clears that pause. This avoids opening a new SSH connection on every refresh.

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
- **Close (×)**: close the main window. The empty title-bar area is draggable; the buttons themselves are not.

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

The window appears immediately; the initial query runs at background priority after the window is shown. Queries parse only the requested minute window instead of the whole day files, so opening History and switching time ranges stay responsive even with long retention.

### Local history layout

History stays on the current Windows user's machine. The default data root is `%LOCALAPPDATA%\\ServerPulse\\`. The first visit to History asks you to save a policy, preselecting 7 days. The query range has no separate maximum; an interval earlier than retained data simply reports that no records are available.

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json           # UI, refresh, and retention settings
├─ servers.json            # server list; no passwords
├─ known_hosts             # application-owned host keys; user known_hosts is never modified
├─ error.log               # local error summary
└─ history\\
   ├─ yyyy-MM-dd.v2.jsonl  # new format: one appended minute record per line
   └─ yyyy-MM-dd.json      # legacy format; still read
```

Storage rules:

- New records append to `yyyy-MM-dd.v2.jsonl` using UTC `Z` timestamps and UTC file dates. A History query accepts a local calendar date, converts it to a UTC range, and displays matching timestamps in local time. Retention is calendar-day based and accepts 1–3650 days; **Never clean up** disables automatic deletion.
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

## Server-side monitoring

For a saved server you can inject a small agent that keeps sampling and recording even while the application is closed, the laptop sleeps, or the network drops. The agent runs as your login user on the server (no root, no systemd, no crontab) and stores records under `~/.serverpulse/`:

```text
~/.serverpulse/
├─ agent.sh               # self-contained POSIX sh agent (generated)
├─ config                 # interval, retention days, server identity
├─ state/                 # pid and heartbeat files for status detection
├─ records/yyyy-MM-dd.v2.jsonl  # minute records, same format as local history (UTC timestamps)
└─ agent.log              # agent output
```

Open **Manage** and use the server-side monitoring row under each server:

- **Status badge**: Running, Stale (process alive but heartbeat expired), Stopped, Not installed, or Unknown.
- **Inject** writes the agent and starts it detached from the SSH session; it keeps running when the app exits or the connection drops. Injecting again while it is running is a no-op.
- **Stop** sends TERM (KILL after a grace period); **Restart** rewrites and restarts the agent; **Uninstall** stops it and removes `~/.serverpulse` (records included — merge them first if you still need them).
- **Configure** sets the sample interval (1–3600 s), server-side retention in days (1–3650), and whether a stopped agent is re-injected automatically when the app starts.
- **Merge records** pulls the server-side records, keeps their UTC `Z` timestamps and UTC file-date partitions, and merges them into local history. Local-date history queries and chart labels convert matching instants to the local timezone. Per-user CPU, memory, and per-GPU VRAM attribution is preserved whenever the server sample contains it; unavailable or partial collection remains explicit. For a minute that exists on both sides, the record with more online samples wins; a tie keeps the local record. An incremental cursor avoids re-pulling merged minutes, and **Merge all** does this for every configured server. Bulk history pulls have a dedicated 120-second operation deadline; Agent status and control commands retain the shorter interactive SSH deadline. The merge dialog can also delete the merged server-side files afterwards (off by default; the agent itself prunes records older than the configured retention).
- The History settings panel has **Auto-merge server records on startup** (off by default).

Notes and limits:

- The agent writes UTC minute timestamps; local history retains UTC storage and converts instants only for local-date queries and display, so timezone differences between the server and your machine are handled.
- After updating Server Pulse, use **Restart** or **Inject** once for an existing server-side agent so it receives the current aggregation script; previously generated records cannot be retroactively reconstructed with user details.
- A server reboot stops the agent (it is a plain user process). The badge shows Stopped; re-inject manually or enable auto-restore in Configure.
- Records contain the same data as local history — UIDs, usernames, and minute aggregates — never PIDs, process names, command lines, or passwords.
- The server needs POSIX `sh`, `awk`, `/proc`, and optionally `nvidia-smi` — the same requirements as live monitoring.

## Local configuration

```text
%LOCALAPPDATA%\\ServerPulse\\
├─ settings.json       # theme, language, position, size, refresh, retention
├─ servers.json        # current server list; no passwords
├─ known_hosts         # application-owned host keys; user known_hosts is read-only
├─ history\\            # minute history
└─ error.log           # UI/history error summary
```

Persistent passwords are stored by Windows Credential Manager or macOS Keychain under a normalized `username@host:port` identity, not in these JSON files. The repository `config/servers.json` is only a first-run seed and contains no password.

## Repository layout

```text
server_monitoring/
├─ ServerPulse.exe          # runnable Windows host
├─ ServerPulse.ps1          # main window entry point
├─ Start Server Pulse.vbs   # compatibility launcher
├─ assets/                  # SVG/ICO icons
├─ config/                  # first-run seed configuration
├─ scripts/                 # build scripts
├─ src/                     # collector, history, storage, SSH, agent, theme, and host code
├─ frontend/                # Vue 3 + TypeScript Preview UI
├─ src-tauri/               # Tauri shell and platform-independent Rust crates
├─ assets/serverpulse-sample.sh # canonical LF-only remote sampler
├─ tests/fixtures/          # protocol and history golden fixtures
├─ tests/                   # automation and mock SSH
├─ docs/DEVELOPMENT.md      # contributor/developer documentation
├─ docs/TAURI-PORT-PLAN.md  # Tauri cross-platform port plan
├─ CHANGELOG.md             # bilingual version history and release notes
├─ README.md                # English user manual
└─ README.zh-CN.md          # Chinese user manual
```

## Troubleshooting

**A server is offline.** Run `ssh -o BatchMode=yes <alias> hostname` and check the alias, key, VPN, jump host, and host fingerprint. One failed server does not block the others.

**GPU count is zero.** Run `nvidia-smi` on the remote host. CPU and memory collection does not require NVIDIA tools.

**User attribution is partial.** `/proc` or NVIDIA process visibility may be restricted, or a process may have exited between samples. The aggregate metric remains available and the attribution status is shown.

**Will a saved password be used by terminal SSH?** No. It is available only to Server Pulse; terminal `ssh` continues to use its own keys, agent, or interactive password flow.

**The window is hidden.** Touch the enabled edge or click the tray icon. If its position is unusable, remove `%LOCALAPPDATA%\\ServerPulse\\settings.json` to restore defaults.

**A terminal window appears when launching the Preview.** Use the generated `ServerPulse-Portable.exe` or `serverpulse-tauri.exe` from Explorer or a shortcut. The release build and its Windows SSH/host-key helper processes use the GUI/no-console configuration; if it was started by typing the command in Windows Terminal, that parent terminal remains open by design.

**A monitored card stays stopped at startup.** The Preview resolves SSH aliases with `ssh -G` before running `ssh-keyscan`, so the probe uses the configured hostname and port. If probing or IPC still fails, the card changes to `offline` and shows the error instead of silently aborting startup; check the SSH alias, VPN, jump host, and host fingerprint.

**SSH aliases are not listed.** Open **Manage** and press **Reload**. Check the displayed config path, detected aliases, and read error. The Preview reads concrete `Host` entries from `~/.ssh/config` and simple `Include` files; wildcard-only entries are intentionally skipped.

**How should I report a problem?** Include the app version, Windows version, EXE/script mode, reproduction steps, and a sanitized `error.log`. Never upload history, passwords, private keys, real host addresses, or user lists.

## Development

Architecture, collection protocol, history format, building, testing, security boundaries, and the release checklist are in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). End users only need this manual.

The cross-platform (Tauri) port plan is in [`docs/TAURI-PORT-PLAN.md`](docs/TAURI-PORT-PLAN.md).

Local agent instructions in `AGENTS.md` are kept outside version control and are not included in published source snapshots.

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for the complete text.

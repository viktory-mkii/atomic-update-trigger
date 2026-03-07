# atomic-update-trigger

> Automatic atomic updates on shutdown/reboot for openSUSE Tumbleweed and Slowroll.

Automatically runs [`atomic-update`](https://github.com/pavinjosdev/atomic-update) on shutdown and/or reboot on openSUSE Tumbleweed and Slowroll. Updates are applied atomically into a new btrfs snapshot — your running system is never touched, and if anything goes wrong the snapshot is discarded and the system boots unchanged.

Developed with the assistance of [Claude](https://claude.ai) by Anthropic.

---

## Contents
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Rolling back an update](#rolling-back-an-update)
- [Uninstall](#uninstall)

## How it works

When you shut down or reboot (depending on your preference), a systemd service fires `atomic-update dup` before the system powers off. If updates are available:

- A new btrfs snapshot of the root filesystem is created
- Updates are applied inside the snapshot
- The snapshot becomes the default on next boot

If the update fails or is interrupted for any reason, the snapshot is discarded. Your system boots from the previous snapshot unchanged, as if nothing happened.

When there is nothing to update, the system shuts down normally with no delay.

---

## Requirements

- openSUSE Tumbleweed or Slowroll
- btrfs root filesystem
- snapper configured for `/` (a root config must exist)
- systemd
- python3
- `libnotify-tools` (for desktop notifications — the installer will offer to install this)

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/viktory-mkii/atomic-update-trigger/main/install-atomic-update.sh -o install-atomic-update.sh
sudo bash install-atomic-update.sh
```

The installer will:
1. Check all prerequisites
2. Download the latest `atomic-update` binary from its upstream repository
3. Walk you through configuration
4. Install and enable all components
5. Verify the installation

---

## Configuration

Settings live in `/etc/atomic-update.conf` and take effect immediately — no reinstall or service restart needed.

```bash
sudo nano /etc/atomic-update.conf
```

### `UPDATE_ON`

Controls when updates run.

| Value | Behaviour |
|-------|-----------|
| `poweroff` | Run on shutdown/halt only, skip on reboot *(default)* |
| `reboot` | Run on reboot only, skip on shutdown |
| `both` | Run on both shutdown and reboot |
| `none` | Disable updates without removing the service |

### `VERBOSE_SHUTDOWN`

Controls whether `atomic-update`'s full output is shown on the TTY during shutdown/reboot.

| Value | Behaviour |
|-------|-----------|
| `yes` | Full output shown on screen *(default, recommended)* |
| `no` | Output suppressed on screen; always written to log |

> **Note:** Setting this to `no` may result in a blank screen for the duration of a long update. This setting is intended for advanced users.

### `NOTIFY_ON_SUCCESS`

Show a desktop notification after login when an update was applied successfully.

| Value | Behaviour |
|-------|-----------|
| `no` | No notification on success *(default)* |
| `yes` | Notify on successful update |

### `NOTIFY_ON_PROBLEM`

Show a desktop notification after login when an update was skipped (package conflicts) or failed unexpectedly.

| Value | Behaviour |
|-------|-----------|
| `yes` | Notify on skip or failure *(default)* |
| `no` | No notification |

---

## Logs

Updates are logged to `/var/log/atomic-update-trigger.log`. The log is readable without root:

```bash
cat /var/log/atomic-update-trigger.log
```

Each run produces an entry like:

```
======================================================================
[2026-03-06 21:00:00] atomic-update-trigger fired
[config] VERBOSE_SHUTDOWN=yes UPDATE_ON=poweroff
======================================================================
... atomic-update output ...

[2026-03-06 21:00:45] Result: SUCCESS — new snapshot set as default
----------------------------------------------------------------------
```

Possible result values:

| Result | Meaning |
|--------|---------|
| `SUCCESS` | Update applied; new snapshot active on next boot |
| `NOTHING TO DO` | System already up to date; no snapshot created |
| `SKIPPED` | Update skipped due to package conflicts (exit code 9) |
| `FAILED` | Unexpected failure; check log for details |

The journal also captures output:

```bash
sudo journalctl -u atomic-update-trigger
```

Logs are rotated monthly, keeping 12 months of history.

---

## Rolling back an update

If you want to undo an update after it has been applied:

1. Reboot the system
2. In the bootloader menu, select the **previous snapshot** (the one before the update)
3. Once booted into the old snapshot, run:
   ```bash
   sudo atomic-update rollback
   ```
4. Reboot again — the old snapshot is now the permanent default

> **Important:** Running `rollback` from the already-updated system has no effect. You must first boot into the previous snapshot via the bootloader, then run the command from there.

Your personal files in `/home` are on a separate btrfs subvolume and are **never** affected by snapshots or rollbacks.

---

## Useful commands

```bash
# Check service status
systemctl status atomic-update-trigger

# Temporarily disable updates
sudo systemctl disable atomic-update-trigger

# Re-enable updates
sudo systemctl enable atomic-update-trigger --now

# View log
cat /var/log/atomic-update-trigger.log

# View journal
sudo journalctl -u atomic-update-trigger

# Manual rollback (must be run from previous snapshot — see above)
sudo atomic-update rollback
```

---

## Desktop notifications

After login, a desktop notification will appear if an update was skipped or failed (configurable via `NOTIFY_ON_PROBLEM`). Notifications use `notify-send` and are compatible with any desktop environment that implements the [freedesktop notification spec](https://specifications.freedesktop.org/notification-spec/notification-spec-latest.html) — including KDE Plasma, GNOME, XFCE, and others.

> **GNOME users:** Notifications will work correctly. GNOME ignores the `--expire-time` flag and manages notification persistence through its own notification centre instead.

> **Lightweight DE users (XFCE, LXQt, etc.):** If notifications don't appear, your DE may not register with `graphical-session.target` reliably. Try increasing the `ExecStartPre` sleep value in `~/.config/systemd/user/atomic-update-notify.service`.

---

## A note on reboot detection

This tool distinguishes between a shutdown and a reboot by reading systemd's internal job queue at the moment the service stops. This has been tested and works reliably, but it is not an officially documented systemd guarantee. It is mentioned here for transparency — it is not likely to cause problems in normal use.

---

## Uninstall

```bash
sudo bash install-atomic-update.sh --uninstall
```

This removes all installed components and prompts whether to keep or remove your configuration file. The `atomic-update` binary and log file are kept and must be removed manually if desired.

---

## Credits

- **[atomic-update](https://github.com/pavinjosdev/atomic-update)** by [pavinjosdev](https://github.com/pavinjosdev) — the transactional update tool this project automates. All credit for the update mechanism belongs to that project.
- **[transactional-update](https://github.com/openSUSE/transactional-update)** by the openSUSE project — the original transactional update system for read-only root filesystems that inspired atomic-update. Credit to them for the foundational concept.
- Installer developed with the assistance of [Claude](https://claude.ai) by Anthropic.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

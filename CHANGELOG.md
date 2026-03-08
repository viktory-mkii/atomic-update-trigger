# Changelog

All notable changes to this project will be documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.1.0] — 2026-03-08

### Added
- `atomic-update-rollback` — safe rollback wrapper that sets a skip-once flag to prevent the trigger from immediately re-applying an update after a rollback; supports optional snapshot number argument
- `atomic-update-skip-once` — sets the skip-once flag to pause one update cycle without changing config
- `UPDATE_ON` validation — unrecognised values now skip the update and log a clear error rather than running unconditionally
- Desktop notification for misconfigured `UPDATE_ON` value, shown regardless of `NOTIFY_ON_PROBLEM` setting
- Rollback protection and config error treated as distinct notification cases from package conflict skips

### Changed
- `VERBOSE_SHUTDOWN` demoted to a hidden advanced option in the config file; removed from installer setup flow and README since output is not visible on Wayland sessions regardless of the setting
- Rollback wrapper installed to `/usr/bin/` for sudo path compatibility
- Log header no longer includes `VERBOSE_SHUTDOWN` field

### Removed
- Plymouth shutdown masking — benefit is marginal on Wayland and the masking touches system configuration outside the project's scope
- `wget` fallback in the atomic-update download step — `curl` is present by default on all target systems

### Fixed
- Post-rollback message no longer incorrectly instructs the user to boot into a previous snapshot after the rollback has already completed
- Notification script no longer incorrectly reports rollback protection skips as package conflict skips

---

## [1.0.0] — 2026-03-07

### Added
- Initial release
- Automatic `atomic-update dup` triggered on shutdown and/or reboot via systemd
- Reboot vs. poweroff detection using systemd job queue
- `UPDATE_ON` config option: `poweroff`, `reboot`, `both`, `none`
- `NOTIFY_ON_SUCCESS` and `NOTIFY_ON_PROBLEM` desktop notification options
- Snapper no-dbus shim for D-Bus-free operation during late shutdown
- Persistent log at `/var/log/atomic-update-trigger.log` with logrotate config
- Config merge on reinstall — preserves existing values, adds missing keys
- `--uninstall` flag with prompt to keep or remove config file
- Compatible with KDE Plasma, GNOME, and other freedesktop-compliant DEs

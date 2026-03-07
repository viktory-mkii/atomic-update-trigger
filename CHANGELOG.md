# Changelog

All notable changes to this project will be documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.0.0] — 2026-03-07

### Added
- Initial release
- Automatic `atomic-update dup` triggered on shutdown and/or reboot via systemd
- Reboot vs. poweroff detection using systemd job queue
- `UPDATE_ON` config option: `poweroff`, `reboot`, `both`, `none`
- `VERBOSE_SHUTDOWN` config option: show full update output on TTY
- `NOTIFY_ON_SUCCESS` and `NOTIFY_ON_PROBLEM` desktop notification options
- Snapper no-dbus shim for D-Bus-free operation during late shutdown
- Plymouth shutdown masking for TTY visibility during updates
- Persistent log at `/var/log/atomic-update-trigger.log` with logrotate config
- Config merge on reinstall — preserves existing values, adds missing keys
- `--uninstall` flag with prompt to keep or remove config file
- Compatible with KDE Plasma, GNOME, and other freedesktop-compliant DEs

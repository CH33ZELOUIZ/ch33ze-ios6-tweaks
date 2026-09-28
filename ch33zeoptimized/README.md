# Optimized

Settings app panel and iOS 6 multitasking tray page for performance cleanup on low-memory devices.

The multitasking tray adds a **CH33ZE Optimizer** panel, inserted to the left of the CH33ZE Brightness page when both tweaks are installed. It shows RAM stats and provides quick buttons:

- **Free RAM**: runs the safest available system purge/sync path.
- **Clear Apps**: terminates App Store apps discovered under `/var/mobile/Applications`, skipping SpringBoard and core system daemons.
- **LP On / LP Off**: toggles Low Power mode.
- **SSH On / SSH Off**: directly controls the OpenSSH launch daemon.

Low Power mode turns on the optimization switches and applies them immediately:

- Disable OTA update daemons
- Disable diagnostics/crash dump daemons
- Disable Mail/account fetch daemon
- Disable Game Center daemon
- Disable Spotlight daemons
- Disable Location Services daemon
- Disable Push/background notification daemon
- Disable SSH daemon

Settings defaults are conservative until Low Power is used:

- Disable OTA update daemons: on
- Disable diagnostics/crash dump daemons: on
- Disable Mail/account fetch daemon: on
- Disable Game Center daemon: off
- Disable Spotlight daemons: off
- Disable Location Services daemon: off
- Disable Push/background notification daemon: off
- Disable SSH daemon: off
- Reduce SpringBoard animations: off

Implementation notes:

- Installs `/usr/bin/optimizedctl` as a root setuid helper through `postinst` so Settings and SpringBoard tray buttons can apply launch daemon changes.
- Daemon disabling renames matching LaunchDaemon plists to `*.optimized-disabled` after attempting `launchctl unload -w`.
- Re-enabling moves only those `*.optimized-disabled` files back and attempts `launchctl load -w`.
- Missing daemon names are skipped so the same package can tolerate minor iOS 6 device differences.
- Turning SSH off can disconnect remote access; the tray and Settings both provide a way to turn it back on locally.

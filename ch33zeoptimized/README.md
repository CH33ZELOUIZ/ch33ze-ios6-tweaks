# Optimized

Settings app panel for iOS 6 performance cleanup on low-memory devices.

Defaults are conservative for a games/music/video iPod:

- Disable OTA update daemons: on
- Disable diagnostics/crash dump daemons: on
- Disable Mail/account fetch daemon: on
- Disable Game Center daemon: off
- Disable Spotlight daemons: off
- Reduce SpringBoard animations: off

The Settings panel includes:

- **Apply Changes**: writes daemon changes without respringing.
- **Apply and Respring**: writes changes, then restarts SpringBoard.

Implementation notes:

- Installs `/usr/bin/optimizedctl` as a root setuid helper through `postinst` so Settings can apply launch daemon changes.
- Daemon disabling renames matching LaunchDaemon plists to `*.optimized-disabled` after attempting `launchctl unload -w`.
- Re-enabling moves only those `*.optimized-disabled` files back and attempts `launchctl load -w`.
- Missing daemon names are skipped so the same package can tolerate minor iOS 6 device differences.

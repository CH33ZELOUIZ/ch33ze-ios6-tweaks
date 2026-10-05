# NavTunes 0.3.0 Testing Report

Date: 2026-10-04

## Build verification

Command run:

    export THEOS=../.theos-probe; make clean package FINALPACKAGE=1

Result: succeeded. Theos produced:

    ch33zenavtunesimporter/packages/com.ch33ze.navtunesimporter_0.3.0_iphoneos-arm.deb

Build warnings observed:

- StoreServices private selectors are intentionally called dynamically, so clang warns that `initWithDownloadManagerOptions:`, `initWithDownloadKinds:`, and `initWithDownloadMetadata:` are not found.
- `CHZPlayLocalPath` and historical `CHZDirectImportItem` are currently unused.
- iOS 6 target/deprecated-link warnings from the armv7 toolchain.

## Package verification

Command run:

    dpkg-deb -I docs/debs/com.ch33ze.navtunesimporter_0.3.0_iphoneos-arm.deb

Verified package metadata:

- Package: `com.ch33ze.navtunesimporter`
- Version: `0.3.0`
- Depiction: `http://cydia.personaltechwiz.com/navtunes.html`
- Icon: `http://cydia.personaltechwiz.com/navtunes-icon.png`

Command run:

    dpkg-deb -c docs/debs/com.ch33ze.navtunesimporter_0.3.0_iphoneos-arm.deb

Verified package contents:

- `Library/MobileSubstrate/DynamicLibraries/CH33ZENavTunesImporter.dylib`
- `Library/MobileSubstrate/DynamicLibraries/CH33ZENavTunesImporter.plist`
- `usr/bin/navtunesimport`
- `usr/bin/navtunesdirect`

## Review follow-up verification

After review feedback, the source was rebuilt and the release package was refreshed in `docs/debs/`.

Changes verified by build/package checks:

- Bug-report diagnostics now include iOS version, device model, NavTunes version, live Subsonic ping status, memory, storage, queue summary, playlist/download counts, and recent logs without password/token fields.
- Settings now opens a real `View Queue` list backed by `/var/mobile/Library/NavTunesImportQueue.plist`; the queue screen auto-refreshes and includes a `Process` action for pending imports.
- Settings now exposes `Direct Music playlist population` as an advanced toggle, defaulting on for the 0.3.0 behavior.
- Playlist downloads now attempt stock Music playlist population by default and publish `Building stock Music playlist…` / `Stock Music playlist updated` status alongside the existing per-track download progress.

Command rerun:

    export THEOS=../.theos-probe; make clean package FINALPACKAGE=1

Result: succeeded with the same expected private-selector/deprecated-target warnings listed above.

Commands rerun:

    cp ch33zenavtunesimporter/packages/com.ch33ze.navtunesimporter_0.3.0_iphoneos-arm.deb docs/debs/
    cd docs && dpkg-scanpackages -m debs > Packages && gzip -9ck Packages > Packages.gz && bzip2 -9ck Packages > Packages.bz2

Result: package copied and repository indexes regenerated with 14 entries.

## Repository verification

Command run:

    dpkg-scanpackages -m docs/debs > docs/Packages
    gzip -9c docs/Packages > docs/Packages.gz
    bzip2 -9c docs/Packages > docs/Packages.bz2

Result: succeeded with 14 package entries. `docs/Packages` includes the new 0.3.0 NavTunes package entry with depiction and icon fields.

## Device/runtime verification not performed

No physical iOS 6 device or simulator was available in this worker session, so runtime behaviors (Music.app launch, actual Navidrome auth, playlist download cancellation, StoreServices import completion, and GitHub issue URL opening on-device) still need on-device smoke testing before public release.

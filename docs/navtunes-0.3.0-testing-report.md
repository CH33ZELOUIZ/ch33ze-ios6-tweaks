# NavTunes 0.3.0 Testing Report

Date: 2026-10-04

## Build verification

Command run:

    export THEOS=/home/jeffrey/theos; make clean package FINALPACKAGE=1

Result: succeeded. Theos produced:

    /home/jeffrey/projects/ch33ze-ios6-tweaks/ch33zenavtunesimporter/packages/com.ch33ze.navtunesimporter_0.3.0_iphoneos-arm.deb

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

## Repository verification

Command run:

    dpkg-scanpackages -m docs/debs > docs/Packages
    gzip -9c docs/Packages > docs/Packages.gz
    bzip2 -9c docs/Packages > docs/Packages.bz2

Result: succeeded with 14 package entries. `docs/Packages` includes the new 0.3.0 NavTunes package entry with depiction and icon fields.

## Device/runtime verification not performed

No physical iOS 6 device or simulator was available in this worker session, so runtime behaviors (Music.app launch, actual Navidrome auth, playlist download cancellation, StoreServices import completion, and GitHub issue URL opening on-device) still need on-device smoke testing before public release.

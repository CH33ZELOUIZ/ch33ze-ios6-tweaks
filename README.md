# CH33ZE iOS 6 Tweaks

Retro-feeling quality-of-life tweaks for jailbroken iOS 6 devices, starting with an iPod touch 4th gen on iOS 6.1.6.

## Current device target

- Device: iPod touch 4,1
- OS: iOS 6.1.6 / 10B500
- Jailbreak runtime: Cydia + MobileSubstrate + PreferenceLoader
- First tweak: battery percentage next to the stock battery icon

## Battery percentage status

The first safe implementation uses SpringBoard's existing preference key:

```text
SBShowBatteryLevel = true
```

This was applied over SSH and verified by reading the preference back from the device.

A real MobileSubstrate version is planned next if we want custom positioning/styling beyond Apple's built-in percentage display.

## Repo layout

```text
device-backups/   Local-only iPod preference backups; git-ignored.
packages/         Built .deb packages; git-ignored until intentionally released.
repo/             Cydia/APT repo output.
tools/            Host-side helper scripts.
tweaks/           Theos tweak source projects.
```

## Safety defaults

- Back up preference files before changing them.
- Prefer reversible SpringBoard-only changes first.
- Avoid LaunchDaemons and background killers until each process is identified.
- Test each tweak manually over SSH before publishing it in the Cydia source.

# iOS 6 Tweaks

A collection of quality-of-life tweaks I made for my jailbroken iPod Touch 4th gen running iOS 6.1.6. These bring some modern conveniences back to the classic iOS 6 interface.

## Installing

Add this Cydia source on your iOS 6 device:

```
http://cydia.personaltechwiz.com/
```

**Important:** Use plain HTTP, not HTTPS. iOS 6's old Cydia can't handle modern TLS certificates.

## What's included

### Brightness Tray

Adds a brightness slider as an extra page in the app switcher. Just swipe past your running apps to adjust brightness without leaving what you're doing.

### Optimized

A system monitor and cleanup panel in the app switcher. Shows RAM usage, lets you toggle SSH and Low Power mode, and includes safe cleanup tools to keep things running smooth.

### NavTunes Importer

Browse and download music from your Navidrome server directly in the native Music app. Adds a new tab where you can see all your music and playlists, then queue songs to download and import into your local library.

To set it up, create `/var/mobile/Library/Preferences/com.ch33ze.navtunes.plist` with your server details:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>server</key>
    <string>http://your-server.com</string>
    <key>username</key>
    <string>your-username</string>
    <key>password</key>
    <string>your-password</string>
</dict>
</plist>
```

You can also use `token` and `salt` instead of `password` if you prefer token auth.

## Building from source

Uses [Theos](https://theos.dev/). Each tweak has its own folder with a Makefile.

```bash
cd ch33zebrightnesstray
make package
```

The .deb files end up in the `packages` folder.

## Target device

- iPod Touch 4,1
- iOS 6.1.6 (10B500)
- Jailbroken with Cydia + MobileSubstrate

These should work on other iOS 6 devices too, but that's what I'm testing on.

## License

Do whatever you want with this code. No warranty, use at your own risk.

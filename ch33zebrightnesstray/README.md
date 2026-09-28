# CH33ZE Brightness Tray

Goal: add one extra iOS 6 multitasking tray page after the stock music/volume pages with a matching brightness slider.

Status: source skeleton ready; package build requires legacy Theos + armv7 iOS SDK/toolchain.

Relevant iOS 6 classes/APIs found:

- `SBAppSwitcherController`
  - owns `_bottomBar`
  - `viewWillAppear` is a safe hook point when the tray appears
- `SBAppSwitcherBarView`
  - owns `_scrollView` and `_auxViews`
  - exposes `-addAuxiliaryViews:` for adding pages beside app/music/volume pages
- `SBBrightnessController`
  - `+sharedBrightnessController`
  - `-setBrightnessLevel:`
  - `-_setBrightnessLevel:showHUD:`
- Brightness value is mirrored in `/var/mobile/Library/Preferences/com.apple.springboard.plist` as `SBBacklightLevel2` on iOS 6.

Evidence/examples:

- iOS 6 SpringBoard headers: https://github.com/Bensge/iOS-6-SpringBoard-Headers
- Old SpringBoard brightness tweak: https://github.com/iHeli0s/SBBrightness
- Existing iOS 6 app switcher hooks/examples: KillBackground/Slide2Kill style tweaks hook `SBAppSwitcherController` and `_bottomBar`.

Implementation approach:

1. Build a custom `UIView` containing:
   - dark/transparent iOS 6 tray background
   - `/Applications/Preferences.app/LessBright.png`
   - `UISlider`
   - `/Applications/Preferences.app/MoreBright.png`
2. Hook `SBAppSwitcherController -viewWillAppear`.
3. Get `SBAppSwitcherBarView *_bottomBar` via `MSHookIvar`.
4. Read the stock `_auxViews`, keep Apple's existing music and volume pages, append the brightness page, then call `addAuxiliaryViews:` with the combined list.
5. Slider changes call `[[SBBrightnessController sharedBrightnessController] _setBrightnessLevel:value showHUD:YES]`.

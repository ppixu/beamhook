# Beamhook

A minimal macOS menubar app that owns the hardware media keys and forwards
play/pause/next/previous to one app you select, with volume sliders for
scriptable apps.

## Build

```bash
git clone https://github.com/ppixu/beamhook
cd beamhook
brew install xcodegen
xcodegen generate
xcodebuild build -project Beamhook.xcodeproj -scheme Beamhook -configuration Release
```

## Tests

```bash
xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Distribution (sign + notarize)

Set `DEVELOPMENT_TEAM` and a real `PRODUCT_BUNDLE_IDENTIFIER` prefix in `project.yml`,
keep a **stable** signing identity across builds (TCC grants bind to code identity;
a changing identity can silently break the event tap), then:

```bash
# Build a signed app with Hardened Runtime (already enabled in project.yml)
xcodebuild -project Beamhook.xcodeproj -scheme Beamhook -configuration Release \
  -derivedDataPath build clean build

# Zip and notarize (uses a stored notary profile created once via `xcrun notarytool store-credentials`)
ditto -c -k --keepParent "build/Build/Products/Release/Beamhook.app" Beamhook.zip
xcrun notarytool submit Beamhook.zip --keychain-profile "Beamhook-Notary" --wait
xcrun stapler staple "build/Build/Products/Release/Beamhook.app"
```

## Permissions

- **Accessibility** — required to capture the media keys. Grant in System Settings →
  Privacy & Security → Accessibility, then quit and reopen the app.
- **Automation** — a one-time per-app prompt the first time Beamhook controls each app.

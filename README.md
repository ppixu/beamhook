# MediaKeyHub

A minimal macOS menubar app that owns the hardware media keys and forwards
play/pause/next/previous to one app you select, with volume sliders for
scriptable apps.

## Build

```bash
brew install xcodegen
cd MediaKeyHub
xcodegen generate
xcodebuild build -project MediaKeyHub.xcodeproj -scheme MediaKeyHub -configuration Release
```

## Tests

```bash
xcodebuild test -project MediaKeyHub.xcodeproj -scheme MediaKeyKit \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Distribution (sign + notarize)

Set `DEVELOPMENT_TEAM` and a real `PRODUCT_BUNDLE_IDENTIFIER` prefix in `project.yml`,
keep a **stable** signing identity across builds (TCC grants bind to code identity;
a changing identity can silently break the event tap), then:

```bash
# Build a signed app with Hardened Runtime (already enabled in project.yml)
xcodebuild -project MediaKeyHub.xcodeproj -scheme MediaKeyHub -configuration Release \
  -derivedDataPath build clean build

# Zip and notarize (uses a stored notary profile created once via `xcrun notarytool store-credentials`)
ditto -c -k --keepParent "build/Build/Products/Release/MediaKeyHub.app" MediaKeyHub.zip
xcrun notarytool submit MediaKeyHub.zip --keychain-profile "MediaKeyHub-Notary" --wait
xcrun stapler staple "build/Build/Products/Release/MediaKeyHub.app"
```

## Permissions

- **Accessibility** — required to capture the media keys. Grant in System Settings →
  Privacy & Security → Accessibility, then quit and reopen the app.
- **Automation** — a one-time per-app prompt the first time MediaKeyHub controls each app.

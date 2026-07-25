# Releasing the official Beamhook build

The official build is the **signed & notarized** app sold on
[Gumroad](https://ppixu.gumroad.com/l/beamhook). GitHub Releases stay
**binary-free** on purpose — the €5 build is the convenience product. Sparkle
serves updates to existing customers from a private host; only the appcast
metadata (`docs/appcast.xml`) is public.

Every release produces **two artifacts from one binary**:

| Artifact | Made by | Goes to | Why |
|---|---|---|---|
| `build/Beamhook.dmg` | `./release.sh` | Gumroad | Humans get the drag-to-Applications window |
| `Beamhook-<version>.zip` | `./scripts/sign-release.sh` | The update host | Sparkle swaps the `.app` in place; it never shows an installer |

Both wrap the same `build/Build/Products/Official/Beamhook.app`. If you ever
doubt it, compare `codesign -dv --verbose=4` CDHashes — they must match.

## One-time setup (already done / verify)

- **Apple Developer Program** membership, a **Developer ID Application**
  certificate in the keychain, and a stored notary profile:
  ```
  xcrun notarytool store-credentials "Beamhook-Notary" \
    --apple-id "you@example.com" --team-id "XXXXXXXXXX" --password "<app-specific>"
  ```
  Override the profile name with `BEAMHOOK_NOTARY_PROFILE` if it differs.
- Sparkle EdDSA private key lives in the **login keychain** of the release
  machine ("Private key for signing Sparkle updates"). Back it up (e.g. export
  to 1Password): losing it strands every shipped app on its current version,
  because `SUPublicEDKey` in the app pins the pair.
- `SUFeedURL` = `https://beamhook.app/appcast.xml` (the old
  `ppixu.github.io/beamhook` URL 301-redirects, so pre-1.1.0 builds still update).
- Update zips are hosted at an **unguessable URL** on a static host (e.g.
  Cloudflare R2 / S3). Do **not** host them in this repo or on GitHub Pages —
  that would put the paid binary in the public repo. (Anyone with the URL can
  fetch the zip; that's fine — GPL already permits redistribution. The €5 is
  convenience, not DRM.)

## Per-release checklist

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`;
   update `CHANGELOG.md`. Commit.
2. Verify before you sign anything:
   ```
   xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook \
     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```
   The browser targeting scripts are only exercised against a fake executor, so
   also smoke-test a real Safari and Chrome window if that code changed.
3. Build, sign, notarize, staple, and package the DMG in one step:
   ```
   ./release.sh
   ```
   It regenerates the project, does a `clean build` of the tracked **`Official`**
   configuration with your Developer ID, deep-signs Sparkle's nested helpers,
   notarizes and staples both the app and the disk image, and leaves
   `build/Beamhook.dmg` plus a stapled `build/Build/Products/Official/Beamhook.app`.
   Do **not** use `./run.sh` for a shippable build — it signs with the free Apple
   Development identity and launches the app. See the appendix if you need to
   drive the steps by hand.
4. Produce the update zip and the signed appcast:
   ```
   ./scripts/sign-release.sh build/Build/Products/Official/Beamhook.app
   ```
   It refuses anything that is not an `Official`, Developer ID-signed, stapled,
   update-capable build, then creates `Beamhook-<version>.zip`, signs the
   archive, regenerates `docs/appcast.xml` with Sparkle's signed-feed metadata,
   and verifies that signature. `UPDATE_BASE_URL` (default
   `https://updates.beamhook.app`) sets the enclosure prefix.
5. Upload the zip to the update host, and upload the DMG to Gumroad under a
   versioned name — `build/Beamhook.dmg` is unversioned and any later build
   wipes it:
   ```
   cp build/Beamhook.dmg ~/Dropbox/Apps/Beamhook/Beamhook-<version>.dmg
   ```
6. Commit and push `docs/appcast.xml` **exactly as generated**. GitHub Pages
   serves the new signed feed and customers get the update.
7. `git tag -a v<version> && git push origin v<version>`, then
   `gh release create v<version>` with notes from the changelog (no binary).
8. Confirm the release is actually live:
   ```
   curl -fsSI https://updates.beamhook.app/Beamhook-<version>.zip
   curl -fsS https://beamhook.app/appcast.xml | diff - docs/appcast.xml
   ```
   The `content-length` must match the `length` in the appcast enclosure, and the
   deployed feed must be byte-identical to the committed one.

## Never hand-edit a signed appcast

Since 1.1.1 the app sets `SURequireSignedFeed`, so the feed itself carries an
EdDSA signature (embedded at the end of the XML). **Any** later edit — even
fixing a typo in release notes — invalidates it and stops updates for every
1.1.1+ user. Re-run `scripts/sign-release.sh`, or re-sign with
`sign_update <appcast.xml>`, rather than touching the file.

## Appendix: driving the steps by hand

`release.sh` is the supported path; these are the same steps if you need to
debug one of them in isolation.

1. Build the `Official` configuration. `Release` opts out of the injected
   `get-task-allow` entitlement and adds the secure timestamp (notarization
   rejects a build missing either); `Official` does the same **and** compiles in
   Sparkle via `OFFICIAL_BUILD`:
   ```
   xcodegen generate
   xcodebuild -project Beamhook.xcodeproj -scheme Beamhook -configuration Official \
     -derivedDataPath build \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="<Developer ID SHA-1>" \
     PROVISIONING_PROFILE_SPECIFIER="" \
     CODE_SIGN_ENTITLEMENTS=Sources/Beamhook/Beamhook-Release.entitlements \
     CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
     OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
     CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES clean build
   ```
2. **Deep-sign** — required, or notarization fails:
   `./scripts/deep-sign.sh build/Build/Products/Official/Beamhook.app`
   Sparkle ships prebuilt helpers nested inside `Sparkle.framework`
   (`Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`). Xcode does
   not re-sign content nested in an SPM framework, so without this they keep
   Sparkle's signature and Apple reports "not signed with a valid Developer ID
   certificate" for each.
3. Notarize and staple the app:
   ```
   ditto -c -k --keepParent build/Build/Products/Official/Beamhook.app Beamhook.zip
   xcrun notarytool submit Beamhook.zip --keychain-profile Beamhook-Notary --wait
   xcrun stapler staple build/Build/Products/Official/Beamhook.app
   ```
   `notarytool submit --wait` exits 0 even when Apple's final status is
   *Invalid* — always check the status, and read `notarytool log <id>` on
   rejection. A DMG must be notarized and stapled separately from the app it
   contains, and re-packing the DMG changes its hash, so it needs its own
   submission after the app inside is stapled.

# Releasing the official Beamhook build

The official build is the **signed & notarized** app sold on
[Gumroad](https://ppixu.gumroad.com/l/beamhook). GitHub Releases stay
**binary-free** on purpose — the €5 build is the convenience product. Sparkle
serves updates to existing customers from a private host; only the appcast
metadata (`docs/appcast.xml`) is public.

## One-time setup (already done / verify)

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
2. Build the tracked `Official` configuration with **Developer ID Application**
   (not the day-to-day
   Apple Development identity `run.sh` auto-picks). Do **not** use `./run.sh
   release` for a shippable build — it launches the app and, more importantly,
   a plain `xcodebuild build` omits the secure timestamp and injects
   `get-task-allow`, both of which notarization rejects. The `Release` config in
   `project.yml` opts out of both, while `Official` also compiles in Sparkle:
   ```
   xcodegen generate
   xcodebuild -project Beamhook.xcodeproj -scheme Beamhook -configuration Official \
     -derivedDataPath build \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="<Developer ID SHA-1>" \
     PROVISIONING_PROFILE_SPECIFIER="" \
     CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES build
   ```
3. **Deep-sign** — required, or notarization fails:
   `./scripts/deep-sign.sh build/Build/Products/Official/Beamhook.app`
   Sparkle ships prebuilt helpers nested inside `Sparkle.framework`
   (`Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`). Xcode does
   not re-sign content nested in an SPM framework, so without this they keep
   Sparkle's signature and Apple reports "not signed with a valid Developer ID
   certificate" for each.
4. Notarize and staple:
   ```
   ditto -c -k --keepParent build/Build/Products/Official/Beamhook.app Beamhook.zip
   xcrun notarytool submit Beamhook.zip --keychain-profile beamhook-notary --wait
   xcrun stapler staple build/Build/Products/Official/Beamhook.app
   ```
5. Produce the final zip and signed appcast:
   `./scripts/sign-release.sh build/Build/Products/Official/Beamhook.app`
   — this verifies the app's Developer ID signature and stapled ticket, creates
   `Beamhook-<version>.zip`, signs the archive, and atomically regenerates
   `docs/appcast.xml` with Sparkle's signed-feed metadata. Do not edit the
   generated appcast afterward; any edit invalidates its signature.
6. Upload the zip to the update host **and** replace the file on Gumroad.
7. Commit and push the generated `docs/appcast.xml` — GitHub Pages serves the
   new signed feed and customers get the update.
8. `git tag -a v<version> && git push origin v<version>`, then
   `gh release create v<version>` with notes from the changelog (no binary).

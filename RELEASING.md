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
- `SUFeedURL` = `https://ppixu.github.io/beamhook/appcast.xml`.
- Update zips are hosted at an **unguessable URL** on a static host (e.g.
  Cloudflare R2 / S3). Do **not** host them in this repo or on GitHub Pages —
  that would put the paid binary in the public repo. (Anyone with the URL can
  fetch the zip; that's fine — GPL already permits redistribution. The €5 is
  convenience, not DRM.)

## Per-release checklist

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`;
   update `CHANGELOG.md`. Commit.
2. Build & sign with **Developer ID Application** (not the day-to-day Apple
   Development identity `run.sh` picks):
   `BEAMHOOK_SIGN_ID="Developer ID Application: …" ./run.sh release`
3. Notarize and staple:
   ```
   ditto -c -k --keepParent build/Build/Products/Release/Beamhook.app Beamhook.zip
   xcrun notarytool submit Beamhook.zip --keychain-profile beamhook-notary --wait
   xcrun stapler staple build/Build/Products/Release/Beamhook.app
   ```
4. Produce the final zip + signed appcast entry:
   `./scripts/sign-release.sh build/Build/Products/Release/Beamhook.app`
   — this creates `Beamhook-<version>.zip`, signs it with the Sparkle key, and
   prints the `<item>` block.
5. Upload the zip to the update host **and** replace the file on Gumroad.
6. Paste the printed `<item>` into `docs/appcast.xml` (newest first), commit,
   push — GitHub Pages serves the new appcast and customers get the update.
7. `git tag -a v<version> && git push origin v<version>`, then
   `gh release create v<version>` with notes from the changelog (no binary).

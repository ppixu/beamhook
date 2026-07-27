#!/usr/bin/env bash
#
# ship.sh — one command that takes Beamhook from a version number to a
# published release.
#
#   ./ship.sh 1.1.3            # full release, pauses before anything public
#   ./ship.sh 1.1.3 --yes      # no prompts (unattended / driven by Claude)
#   ./ship.sh 1.1.3 --dry-run  # preflight only: prove it *would* work, build nothing
#
# It orchestrates the existing scripts rather than replacing them — release.sh
# and scripts/sign-release.sh stay independently runnable for debugging a single
# stage, exactly as RELEASING.md describes.
#
# The ordering principle: every check that can fail is done BEFORE the ten
# minutes of building and notarizing, not after. A release once died on a
# missing keychain credential *after* Apple had already accepted the
# notarization, so credentials are now proven up front.
#
# What it cannot do: attach the DMG to Gumroad. Gumroad's public API is
# read-only for product files, so that stays a manual step and the script hands
# it to you with the exact path.
#
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${BEAMHOOK_NOTARY_PROFILE:-Beamhook-Notary}"
R2_BUCKET="${BEAMHOOK_R2_BUCKET:-beamhook-updates}"
DMG_ARCHIVE_DIR="${BEAMHOOK_DMG_ARCHIVE_DIR:-$HOME/Dropbox/Apps/Beamhook}"
FEED_URL="https://beamhook.app/appcast.xml"

VERSION=""
ASSUME_YES=""
DRY_RUN=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "error: unknown option '$arg'" >&2; exit 2 ;;
    *) VERSION="$arg" ;;
  esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  ✓ %s\n' "$1"; }
die()  { printf '\033[1merror:\033[0m %s\n' "$1" >&2; exit 1; }

confirm() {
  [ -n "$ASSUME_YES" ] && return 0
  printf '\n  %s [y/N] ' "$1" >&2
  local reply
  read -r reply </dev/tty || return 1
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

read_setting() {
  sed -n -E "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\1/p" project.yml | head -1
}

# The CHANGELOG section for a version, as markdown (GitHub release notes).
changelog_section() {
  awk -v ver="$1" '
    $0 ~ "^## \\[" ver "\\]" { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' CHANGELOG.md
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

[ -n "$VERSION" ] || die "usage: ./ship.sh <version> [--yes] [--dry-run]"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version must look like 1.2.3 (got '$VERSION')" ;;
esac

CURRENT_VERSION=$(read_setting MARKETING_VERSION)
CURRENT_BUILD=$(read_setting CURRENT_PROJECT_VERSION)
# release.sh increments the build itself; predict it so the appcast check below
# tests the number that will actually ship.
if [ "$VERSION" = "$CURRENT_VERSION" ]; then
  NEXT_BUILD="$CURRENT_BUILD"      # re-running a version already bumped
else
  NEXT_BUILD=$((CURRENT_BUILD + 1))
fi
ok "releasing $VERSION (build $NEXT_BUILD), currently at $CURRENT_VERSION (build $CURRENT_BUILD)"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || die "on branch '$BRANCH'; the appcast is served from main's /docs — release from main"

git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "tag v$VERSION already exists"

grep -q "^## \[$VERSION\]" CHANGELOG.md \
  || die "CHANGELOG.md has no '## [$VERSION]' section — it becomes the release notes users see"
ok "CHANGELOG section present"

grep -q "<sparkle:version>$NEXT_BUILD</sparkle:version>" docs/appcast.xml \
  && die "build $NEXT_BUILD is already in docs/appcast.xml — Sparkle compares CFBundleVersion, so that release would reach nobody"
ok "build $NEXT_BUILD is not yet published"

# Uncommitted work in anything that affects the binary would ship silently.
DIRTY=$(git status --porcelain -- Sources Tests project.yml Icon | head -20)
if [ -n "$DIRTY" ]; then
  printf '\n%s\n' "$DIRTY"
  confirm "Uncommitted changes above will be BUILT INTO the release. Continue?" \
    || die "stopped; commit or stash first"
fi

command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
command -v gh >/dev/null 2>&1       || die "gh not found (brew install gh)"
command -v wrangler >/dev/null 2>&1 || die "wrangler not found (npm install -g wrangler)"
ok "xcodegen, gh, wrangler present"

security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application' \
  || die "no 'Developer ID Application' certificate in the keychain"
ok "Developer ID certificate present"

# The expensive lesson: prove the notary credential BEFORE the build. This exact
# check exits 69 when the profile is missing, and takes about two seconds.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' is unusable. Recreate it:
       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <you> --team-id <team>"
ok "notary credential '$NOTARY_PROFILE' works"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
wrangler whoami >/dev/null 2>&1 || die "wrangler is not authenticated (wrangler login)"
ok "gh and wrangler authenticated"

wrangler r2 bucket info "$R2_BUCKET" >/dev/null 2>&1 \
  || die "R2 bucket '$R2_BUCKET' is not reachable — the update zip would have nowhere to go"
ok "R2 bucket '$R2_BUCKET' reachable"

[ -d "$DMG_ARCHIVE_DIR" ] || die "$DMG_ARCHIVE_DIR is missing (the versioned DMG for Gumroad goes there)"
ok "DMG archive directory present"

if [ -n "$DRY_RUN" ]; then
  printf '\n\033[1mDry run: every precondition for %s passes. Nothing was built.\033[0m\n' "$VERSION"
  exit 0
fi

# ── Tests ─────────────────────────────────────────────────────────────────────
step "Tests"
mkdir -p build
for scheme in BeamhookKit Beamhook; do
  xcodebuild test -project Beamhook.xcodeproj -scheme "$scheme" \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO >"build/test-$scheme.log" 2>&1 \
    || die "$scheme tests failed — see build/test-$scheme.log"
  ok "$scheme tests pass"
done

# ── Build, notarize, package ──────────────────────────────────────────────────
step "Build, sign, notarize, package"
./release.sh "$VERSION"
APP="build/Build/Products/Official/Beamhook.app"

# ── Update archive, signed feed, upload ───────────────────────────────────────
step "Update archive, signed appcast, R2 upload"
./scripts/sign-release.sh "$APP"

# ── Publish ───────────────────────────────────────────────────────────────────
step "Publish"
printf '  The zip is live at https://updates.beamhook.app/Beamhook-%s.zip\n' "$VERSION"
printf '  Pushing the feed is what offers the update to every existing customer.\n'
confirm "Commit and push docs/appcast.xml, project.yml and CHANGELOG.md?" \
  || die "stopped before publishing. The zip is uploaded; re-run or push by hand when ready."

git add project.yml CHANGELOG.md docs/appcast.xml
git commit -q -m "Release $VERSION" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -q origin main
ok "pushed to main"

step "Waiting for GitHub Pages to serve the new feed"
published=""
for _ in $(seq 1 40); do
  if curl -fsS -H 'Cache-Control: no-cache' "$FEED_URL" 2>/dev/null | grep -q "<sparkle:version>$NEXT_BUILD</sparkle:version>"; then
    published=1
    break
  fi
  sleep 15
done
[ -n "$published" ] || die "the feed did not go live within 10 minutes — check the Pages build"

curl -fsS -H 'Cache-Control: no-cache' "$FEED_URL" | diff -q - docs/appcast.xml >/dev/null \
  || die "the live feed differs from the committed one — do not leave this unresolved"
ok "live feed is byte-identical to the committed feed"

step "Tag and GitHub release"
git tag -a "v$VERSION" -m "Beamhook $VERSION"
git push -q origin "v$VERSION"
# Deliberately binary-free: the DMG is the paid convenience product (RELEASING.md).
changelog_section "$VERSION" | gh release create "v$VERSION" \
  --title "Beamhook $VERSION" --notes-file - >/dev/null
ok "tagged v$VERSION and created the GitHub release"

# ── Handoff ───────────────────────────────────────────────────────────────────
step "Done — $VERSION is live for existing customers"
cat <<EOF

  Existing customers   Sparkle is serving $VERSION from $FEED_URL
  New purchasers       still get the previous build until you update Gumroad

  One manual step remains. Gumroad's public API is read-only for product files,
  so the DMG has to be attached by hand:

      $DMG_ARCHIVE_DIR/Beamhook-$VERSION.dmg

      1. https://app.gumroad.com/products → Beamhook → Content
      2. Upload files → pick the DMG above
      3. Delete the OLD entry (both display as "1.8 MB"; two files would leave
         buyers unable to tell which is current)
      4. Save changes

EOF

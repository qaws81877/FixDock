#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# Copyright (C) 2026 FixDock contributors
#
# Notarizes and staples build/stage/FixDock.app with Apple's notary service,
# then writes the release zip build/release/FixDock-<version>.zip and prints
# its SHA-256 (the Homebrew cask needs it). Adapted from vorssaint-utils
# Tools/notarize.sh; credentials come from a notarytool keychain profile
# instead of CI secrets.
#
#   FIXDOCK_CODESIGN_IDENTITY="<Developer ID SHA-1>" ./build.sh
#   ./Tools/notarize.sh
#
# The profile (default "fixdock", or FIXDOCK_NOTARY_PROFILE) is stored once,
# in your own Terminal, because it prompts for a password:
#   xcrun notarytool store-credentials fixdock --apple-id <you> --team-id <team>
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

APP="build/stage/FixDock.app"
PROFILE="${FIXDOCK_NOTARY_PROFILE:-fixdock}"
OUT_DIR="build/release"

if [[ ! -d "$APP" ]]; then
    echo "✗ $APP not found. Build it first with FIXDOCK_CODESIGN_IDENTITY set." >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP"
SIGNATURE="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
if ! print -r -- "$SIGNATURE" | grep -q "Authority=Developer ID Application"; then
    echo "✗ $APP is not signed with a Developer ID Application identity." >&2
    exit 1
fi
if ! print -r -- "$SIGNATURE" | grep -q "flags=.*runtime"; then
    echo "✗ $APP is not signed with the hardened runtime. Rebuild with ./build.sh." >&2
    exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :FixDockLocalFeedFolder' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "✗ $APP is an update test build (local feed). Rebuild without the test variables." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$OUT_DIR/FixDock-$VERSION.zip"
if [[ -e "$ZIP" ]]; then
    echo "✗ $ZIP already exists. Move it away first; this script never replaces it." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# notarytool takes a zip; the ticket is stapled to the app itself, and the
# release zip is made from the stapled app so it also opens offline.
SUBMIT="$WORK/FixDock-$VERSION-submit.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMIT"

echo "▸ Submitting FixDock $VERSION to the notary service (can take a few minutes)…"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait

# Fails if notarization did not succeed, so a bad result never ships.
echo "▸ Stapling…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

mkdir -p "$OUT_DIR"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
# The in-app updater accepts only a zip whose every entry is under FixDock.app/.
if /usr/bin/zipinfo -1 "$ZIP" | grep -qv '^FixDock\.app/'; then
    echo "✗ $ZIP has an entry outside FixDock.app/; the updater would refuse it." >&2
    exit 1
fi
echo "✓ Notarized and stapled: $ZIP"
shasum -a 256 "$ZIP"
echo "Release: tag v$VERSION with the single asset FixDock-$VERSION.zip, created together in"
echo "one gh release create call. The release notes are shown in the app before installing."

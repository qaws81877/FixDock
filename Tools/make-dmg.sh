#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 FixDock contributors
#
# Packs the notarized, stapled build/stage/FixDock.app into a drag-to-install
# disk image, build/release/FixDock-<version>.dmg: the app beside an
# Applications shortcut. The image is signed with the same Developer ID,
# notarized and stapled, so it opens on another Mac without a warning.
# Double-clicking the app inside the image also works: the app offers to move
# itself into /Applications (Sources/FixDock/Services/InstallMover.swift).
#
#   FIXDOCK_CODESIGN_IDENTITY="<Developer ID SHA-1>" ./build.sh
#   ./Tools/notarize.sh
#   FIXDOCK_CODESIGN_IDENTITY="<Developer ID SHA-1>" ./Tools/make-dmg.sh
#
# Uses the same notarytool keychain profile as Tools/notarize.sh (default
# "fixdock", or FIXDOCK_NOTARY_PROFILE). The window layout is set through
# Finder, which asks once for Automation permission; FIXDOCK_DMG_NO_LAYOUT=1
# skips it (the image then opens with Finder's default view).
#
# The image is for handing out directly (a shared drive, a team chat). The
# GitHub release keeps its single asset FixDock-<version>.zip, which is all
# the in-app updater reads; a copy installed from the image updates from it.
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

APP="build/stage/FixDock.app"
PROFILE="${FIXDOCK_NOTARY_PROFILE:-fixdock}"
OUT_DIR="build/release"
VOLUME="FixDock"
IDENTITY="${FIXDOCK_CODESIGN_IDENTITY:-}"

if [[ -z "$IDENTITY" ]]; then
    echo "✗ Set FIXDOCK_CODESIGN_IDENTITY to the Developer ID Application identity that signed the app." >&2
    exit 1
fi
if [[ ! -d "$APP" ]]; then
    echo "✗ $APP not found. Build and notarize it first (./build.sh, ./Tools/notarize.sh)." >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP"
if ! /usr/bin/codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "✗ $APP is not signed with a Developer ID Application identity." >&2
    exit 1
fi
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "✗ $APP has no stapled ticket. Run ./Tools/notarize.sh first." >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :FixDockLocalFeedFolder' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "✗ $APP is an update test build (local feed). Rebuild without the test variables." >&2
    exit 1
fi
if [[ -e "/Volumes/$VOLUME" ]]; then
    echo "✗ /Volumes/$VOLUME is already mounted. Eject it first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/FixDock-$VERSION.dmg"
if [[ -e "$DMG" ]]; then
    echo "✗ $DMG already exists. Move it away first; this script never replaces it." >&2
    exit 1
fi

WORK="$(mktemp -d)"
MOUNTED=""
cleanup() {
    [[ -n "$MOUNTED" ]] && /usr/bin/hdiutil detach "$MOUNTED" -force >/dev/null 2>&1
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

echo "▸ Staging FixDock $VERSION…"
SOURCE="$WORK/source"
mkdir -p "$SOURCE"
/usr/bin/ditto "$APP" "$SOURCE/FixDock.app"
ln -s /Applications "$SOURCE/Applications"

RW="$WORK/rw.dmg"
/usr/bin/hdiutil create -quiet -volname "$VOLUME" -srcfolder "$SOURCE" -fs HFS+ -format UDRW -ov "$RW"

if [[ "${FIXDOCK_DMG_NO_LAYOUT:-0}" != "1" ]]; then
    echo "▸ Laying out the window…"
    MOUNTED="$(/usr/bin/hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)"
    if [[ "$MOUNTED" != "/Volumes/$VOLUME" ]]; then
        echo "✗ The image mounted at '$MOUNTED', expected /Volumes/$VOLUME." >&2
        exit 1
    fi
    /usr/bin/osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 740, 460}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set position of item "FixDock.app" of container window to {140, 160}
        set position of item "Applications" of container window to {400, 160}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
    sync
    /usr/bin/hdiutil detach "$MOUNTED" -quiet
    MOUNTED=""
fi

echo "▸ Compressing…"
mkdir -p "$OUT_DIR"
/usr/bin/hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

echo "▸ Signing the image…"
/usr/bin/codesign --sign "$IDENTITY" --timestamp "$DMG"
/usr/bin/codesign --verify --strict "$DMG"

echo "▸ Submitting the image to the notary service (can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Fails if notarization did not succeed, so a bad image never ships.
echo "▸ Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "✓ Notarized and stapled: $DMG"
shasum -a 256 "$DMG"

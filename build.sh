#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# Copyright (C) 2026 FixDock contributors
#
# Builds FixDock, assembles the .app bundle, and signs it: ad-hoc, or with
# FIXDOCK_CODESIGN_IDENTITY using the hardened runtime and a secure timestamp
# so the result can be notarized (Tools/notarize.sh).
# Adapted from vorssaint-utils build.sh. The fan helper, Now Playing adapter,
# update feed, and the upstream signing identity are not used.
#
#   ./build.sh            -> build/stage/FixDock.app
#   ./build.sh --install  -> /Applications/FixDock.app
#   ./build.sh --dev      -> build/stage.noindex/FixDock (Developer).app
#
# Requires Xcode Command Line Tools: xcode-select --install
# Set FIXDOCK_CODESIGN_IDENTITY to sign with your own identity instead of ad-hoc.
# This script cannot run on Linux.

set -euo pipefail
cd "$(dirname "$0")"

STAGE_TMP=""
cleanup() {
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

DEV=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        --install) INSTALL=1 ;;
        -h|--help)
            cat <<'EOF'
FixDock build (macOS 14+, Apple Silicon, Xcode Command Line Tools)

  ./build.sh            Build build/stage/FixDock.app
  ./build.sh --install  Install into /Applications and open nothing
  ./build.sh --dev      Developer bundle that can sit beside the release app

Then: open build/stage/FixDock.app
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

if (( DEV )); then
    APP_NAME="FixDock (Developer)"
    EXECUTABLE="FixDockDeveloper"
    APP_BUNDLE_ID="io.github.qaws81877.fixdock.dev"
    OPTIMIZATION=(-Onone)
else
    APP_NAME="FixDock"
    EXECUTABLE="FixDock"
    APP_BUNDLE_ID="io.github.qaws81877.fixdock"
    OPTIMIZATION=(-O)
fi

if ! xcrun --show-sdk-path >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required. Run: xcode-select --install" >&2
    exit 1
fi

# Prefer the macOS 26 SDK when the Command Line Tools have it. The 27 SDK
# turns SwiftUI property wrappers into macros the Command Line Tools cannot
# load yet. Kept from the upstream build.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

APP_SOURCES=()
while IFS= read -r file; do
    APP_SOURCES+=("$file")
done < <(find Sources/FixDock -name '*.swift' | LC_ALL=C sort)
if (( ${#APP_SOURCES} == 0 )); then
    echo "No Swift sources under Sources/FixDock" >&2
    exit 1
fi

mkdir -p build
echo "▸ Compiling ${#APP_SOURCES} files against $(basename "$SDK")…"
swiftc "${OPTIMIZATION[@]}" -swift-version 5 \
    -target arm64-apple-macosx14.0 -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"

echo "▸ Assembling $APP_NAME.app…"
STAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fixdock-stage.XXXXXX")"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp -R Resources/*.lproj "$STAGE/Contents/Resources/"
cp -R Resources/Icons "$STAGE/Contents/Resources/"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"

ICONSET="$STAGE_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
make_icon() {
    local pixels="$1" name="$2"
    sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$ICONSET/$name" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
xattr -cr "$STAGE" 2>/dev/null || true

ENTITLEMENTS="Resources/FixDock.entitlements"
if [[ -n "${FIXDOCK_CODESIGN_IDENTITY:-}" ]]; then
    echo "▸ Signing with $FIXDOCK_CODESIGN_IDENTITY"
    /usr/bin/codesign --force --sign "$FIXDOCK_CODESIGN_IDENTITY" \
        --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$STAGE"
else
    echo "▸ Signing ad-hoc"
    /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$STAGE"
fi
/usr/bin/codesign --verify --deep --strict "$STAGE"

if (( DEV )); then
    DEST_DIR="build/stage.noindex"
else
    DEST_DIR="build/stage"
fi
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/$APP_NAME.app"
ditto --noextattr --noqtn "$STAGE" "$DEST_DIR/$APP_NAME.app"
echo "✓ Bundle ready: $DEST_DIR/$APP_NAME.app"

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
        pkill -x "$EXECUTABLE" 2>/dev/null || true
        for _ in {1..50}; do
            pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    rm -rf "/Applications/$APP_NAME.app"
    ditto --noextattr --noqtn "$STAGE" "/Applications/$APP_NAME.app"
    xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
    if [[ -n "${FIXDOCK_CODESIGN_IDENTITY:-}" ]]; then
        /usr/bin/codesign --force --sign "$FIXDOCK_CODESIGN_IDENTITY" \
            --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
            "/Applications/$APP_NAME.app"
    else
        /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" \
            "/Applications/$APP_NAME.app"
    fi
    /usr/bin/codesign --verify --deep --strict "/Applications/$APP_NAME.app"
    echo "✓ Installed: /Applications/$APP_NAME.app"
fi

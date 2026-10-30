#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 FixDock contributors
#
# Lays out a local fake release for an update test build (see build.sh):
#
#   <folder>/latest.json                                   GitHub's releases/latest shape
#   <folder>/releases/download/v<X>/FixDock-<X>.zip        a copy of <zip>
#
#   ./Tools/make-local-feed.sh build/release/FixDock-1.0.1.zip <folder>
#
# The URLs in latest.json are file: URLs under <folder>, exactly as the app
# derives them, so the app's checks run unchanged against this folder.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <FixDock-X.Y.Z.zip> <folder>" >&2
    exit 1
fi
ZIP="$1"
NAME="$(basename "$ZIP")"
if [[ ! "$NAME" =~ ^FixDock-([0-9]+\.[0-9]+\.[0-9]+)\.zip$ ]]; then
    echo "✗ The zip must be named FixDock-X.Y.Z.zip (Tools/notarize.sh output)." >&2
    exit 1
fi
VERSION="${BASH_REMATCH[1]}"
mkdir -p "$2"
FOLDER="$(cd "$2" && pwd -P)"
if [[ ! "$FOLDER" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "✗ The folder path may contain only letters, digits, . _ / -" >&2
    exit 1
fi

DEST="$FOLDER/releases/download/v$VERSION"
mkdir -p "$DEST"
cp "$ZIP" "$DEST/$NAME"
SIZE="$(stat -f %z "$DEST/$NAME")"
DIGEST="$(shasum -a 256 "$DEST/$NAME" | cut -d' ' -f1)"

python3 -I - "$FOLDER" "$VERSION" "$NAME" "$SIZE" "$DIGEST" <<'EOF'
import json, pathlib, sys
folder, version, name, size, digest = sys.argv[1:]
base = "file://" + folder
release = {
    "tag_name": "v" + version,
    "draft": False,
    "prerelease": False,
    "html_url": f"{base}/releases/tag/v{version}",
    "body": f"Local test release {version}.\n\n- Built for an update test.\n- Not published.",
    "assets": [{
        "name": name,
        "state": "uploaded",
        "size": int(size),
        "browser_download_url": f"{base}/releases/download/v{version}/{name}",
        "digest": "sha256:" + digest,
    }],
}
pathlib.Path(folder, "latest.json").write_text(json.dumps(release, indent=2) + "\n")
EOF
echo "✓ Local feed for v$VERSION: $FOLDER/latest.json"

#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# Copyright (C) 2026 FixDock contributors
#
# Removes FixDock and the preferences, login item, and privacy grants it
# created. Does not remove Vorssaint, vorssaint-utils, or any other app.

set -u
cd "$(dirname "$0")/.."

remove_app() {
    local app="$1"
    local executable="$2"
    [[ -d "$app" ]] || return 0
    echo "▸ Quitting $executable"
    if [[ -x "$app/Contents/MacOS/$executable" ]]; then
        "$app/Contents/MacOS/$executable" --unregister-login-item || true
    fi
    if pgrep -x "$executable" >/dev/null 2>&1; then
        pkill -x "$executable" 2>/dev/null || true
        sleep 0.4
    fi
    rm -rf "$app"
    echo "  removed $app"
}

remove_app "/Applications/FixDock.app" "FixDock"
remove_app "/Applications/FixDock (Developer).app" "FixDockDeveloper"

for id in io.github.qaws81877.fixdock io.github.qaws81877.fixdock.dev; do
    echo "▸ Clearing preferences and privacy grants for $id"
    defaults delete "$id" >/dev/null 2>&1 || true
    /usr/bin/tccutil reset All "$id" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Saved Application State/$id.savedState"
    rm -rf "$HOME/Library/Caches/$id"
    rm -rf "$HOME/Library/Preferences/$id.plist"
done

echo "✓ FixDock user state removed."
echo "  Build copies under this checkout (build/stage) were left in place."
echo "  Vorssaint was not touched."

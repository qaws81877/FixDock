#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 FixDock contributors
"""Static checks for the FixDock shell. Does not compile Swift."""

import hashlib
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
LICENSE_SHA256 = "6b4da0b606f964a03ab8d1efca249fba7c46fe66b4684616467b8d3b52431d6a"
FEATURE_ORDER = [
    "urlCleaner",
    "quitWindowProtection",
    "cleaningMode",
    "textSnippets",
    "mediaTools",
    "airdropAutoZip",
    "cleaner",
    "screenshot",
    "screenRecorder",
]
ALLOWED_URLS = {
    "https://github.com/vorssaint/vorssaint-utils",
    "https://github.com/qaws81877/FixDock",
    "https://github.com/qaws81877/homebrew-tap",
    "https://www.gnu.org/licenses/gpl-3.0.en.html",
}
FORBIDDEN = [
    "com." + "vorssaint",
    "vorssaint" + ".com",
    "screenshots." + "vorssaint",
    "buymeacoffee.com/" + "vorssaint",
    "discord" + ".gg",
    "Vorssaint Utils Signing",
    "vorssaint-signing",
    "hello@" + "vorssaint.com",
]
URL_SCAN_ROOTS = [
    "Sources",
    "Resources",
    "docs",
    ".github",
    "build.sh",
    "Package.swift",
    "README.md",
    "NOTICE",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "SUPPORT.md",
    "Tools/uninstall.sh",
    "Tools/make-placeholder-icon.py",
]
HEADER = (
    "SPDX-License-Identifier: GPL-3.0-or-later",
    "Copyright (C) 2026 Vorssaint",
)


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


def argument_labels(text, symbol):
    marker = f"static let {symbol} = Strings("
    start = text.index(marker)
    labels = []
    for line in text[start:].splitlines()[1:]:
        if line == "    )":
            break
        match = re.match(r"\s{8}([A-Za-z][A-Za-z0-9]*):", line)
        if match:
            labels.append(match.group(1))
    return labels


def brace_balance(text):
    depth = 0
    i = 0
    line = 1
    in_string = False
    in_line_comment = False
    in_block = False
    escape = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if ch == "\n":
            line += 1
            in_line_comment = False
            escape = False
            i += 1
            continue
        if in_line_comment:
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            if end < 0:
                return "unterminated multiline string"
            line += text[i:end].count("\n")
            i = end + 3
            continue
        if ch == "#":
            hashes = 0
            j = i
            while j < len(text) and text[j] == "#":
                hashes += 1
                j += 1
            if j < len(text) and text[j] == '"':
                closer = '"' + ("#" * hashes)
                end = text.find(closer, j + 1)
                if end < 0:
                    return "unterminated raw string"
                line += text[i:end].count("\n")
                i = end + len(closer)
                continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return f"extra closing brace near line {line}"
        i += 1
    if depth != 0:
        return f"unbalanced braces ({depth})"
    return None


def iter_text_files(relative):
    path = ROOT / relative
    if path.is_file():
        yield path
        return
    if not path.exists():
        return
    for child in path.rglob("*"):
        if not child.is_file():
            continue
        if child.suffix in {".png", ".icns", ".gif", ".jpg", ".mp4"}:
            continue
        yield child


def main():
    errors = 0
    license_path = ROOT / "LICENSE"
    digest = hashlib.sha256(license_path.read_bytes()).hexdigest()
    if digest != LICENSE_SHA256:
        errors += fail("LICENSE was modified")

    trademarks = (ROOT / "TRADEMARKS.md").read_text(encoding="utf-8")
    if "Vorssaint" not in trademarks or "bundle identifier" not in trademarks:
        errors += fail("TRADEMARKS.md is missing the upstream trademark terms")

    notice = (ROOT / "NOTICE").read_text(encoding="utf-8")
    for needle in (
        "https://github.com/vorssaint/vorssaint-utils",
        "1cdbd59b1c7dccd036ec1713b2ea048334990d06",
        "io.github.qaws81877.fixdock",
        "GPL-3.0",
    ):
        if needle not in notice:
            errors += fail(f"NOTICE is missing {needle}")

    if (ROOT / "Sources" / "Vorssaint").exists():
        errors += fail("Sources/Vorssaint is still in the tree")
    for leftover in (
        "Sources/FanControlHelper",
        "Sources/NowPlayingAdapter",
        "Sources/HIDEventSystem",
        "Sources/VMStatisticsCompat",
        "Tests",
        "ReleaseAssets",
    ):
        if (ROOT / leftover).exists():
            errors += fail(f"{leftover} is still in the tree")

    swift_files = list((ROOT / "Sources").rglob("*.swift"))
    if not swift_files:
        errors += fail("no Swift sources")
    for path in swift_files:
        if "Sources/FixDock/" not in str(path):
            errors += fail(f"Swift file outside Sources/FixDock: {path}")
        head = "\n".join(path.read_text(encoding="utf-8").splitlines()[:6])
        for line in HEADER:
            if line not in head:
                errors += fail(f"{path.relative_to(ROOT)} is missing {line}")
        problem = brace_balance(path.read_text(encoding="utf-8"))
        if problem:
            errors += fail(f"{path.relative_to(ROOT)}: {problem}")

    english = (ROOT / "Sources/FixDock/Core/Localization.swift").read_text(encoding="utf-8")
    korean = (ROOT / "Sources/FixDock/Core/Strings+Korean.swift").read_text(encoding="utf-8")
    en_labels = argument_labels(english, "enUS")
    ko_labels = argument_labels(korean, "ko")
    if en_labels != ko_labels:
        errors += fail(f"English/Korean string labels differ: {en_labels} vs {ko_labels}")
    if len(en_labels) < 40:
        errors += fail("string catalog looks truncated")

    catalog = (ROOT / "Sources/FixDock/Core/FeatureCatalog.swift").read_text(encoding="utf-8")
    enum_body = catalog.split("enum AppFeature", 1)[1].split("var id:", 1)[0]
    cases = re.findall(r"case (\w+)", enum_body)
    if cases != FEATURE_ORDER:
        errors += fail(f"AppFeature order is {cases}, expected {FEATURE_ORDER}")
    for name in FEATURE_ORDER:
        count = catalog.count(f"case .{name}:")
        if count < 3:
            errors += fail(f"{name} is missing a symbol, title, or summary switch ({count})")
    if (
        "self == .urlCleaner || self == .quitWindowProtection || self == .cleaningMode\n"
        "            || self == .textSnippets || self == .mediaTools || self == .airdropAutoZip\n"
        "            || self == .cleaner\n" not in catalog
    ):
        errors += fail("only the URL cleaner, quit protection, cleaning mode, text snippets, media, AirDrop auto-zip and cleaner should have a service in this step")

    sources_text = "\n".join(
        path.read_text(encoding="utf-8") for path in swift_files
    )
    if re.search(r"\bSettingsPage\b", sources_text):
        errors += fail("SettingsPage must not be reintroduced")
    if re.search(r"\bSettingsNavigation\b", sources_text):
        errors += fail("SettingsNavigation must not be reintroduced")

    settings_pages = ROOT / "Sources/FixDock/UI/FeatureSettingsPages.swift"
    if not settings_pages.exists():
        errors += fail("FeatureSettingsPages.swift is missing")
    else:
        pages_text = settings_pages.read_text(encoding="utf-8")
        if "default:" in pages_text.split("var settingsPage", 1)[-1].split(
            "private func page", 1
        )[0]:
            errors += fail("settingsPage switch must not use default:")
        switch_body = pages_text.split("var settingsPage", 1)[-1].split(
            "private func page", 1
        )[0]
        for name in FEATURE_ORDER:
            if f".{name}" not in switch_body:
                errors += fail(f"settingsPage switch is missing .{name}")

    for path in swift_files:
        relative = str(path.relative_to(ROOT))
        if relative.endswith("FeatureRuntime.swift"):
            continue
        text = path.read_text(encoding="utf-8")
        # Availability writes belong only in FeatureRuntime.
        if re.search(
            r"UserDefaults\.standard\.set\([^,\n]+,\s*forKey:\s*(?:feature\.)?availabilityKey",
            text,
        ):
            errors += fail(f"{relative} writes availability outside FeatureRuntime")

    settings_view = (ROOT / "Sources/FixDock/UI/SettingsView.swift").read_text(
        encoding="utf-8"
    )
    # Sidebar List must not use .id( — revision identity belongs on the hub.
    if "List(selection:" in settings_view:
        after_list = settings_view.split("List(selection:", 1)[1]
        sidebar_block = after_list.split("Divider()", 1)[0]
        if re.search(r"\.id\s*\(", sidebar_block):
            errors += fail("Settings sidebar List must not use .id(")

    hub = (ROOT / "Sources/FixDock/UI/FeatureHubView.swift").read_text(encoding="utf-8")
    if re.search(r"==\s*\.urlCleaner", hub):
        errors += fail("FeatureHubView must not hard-code == .urlCleaner navigation")
    if "SettingsNavigator.shared.open" not in hub or "settingsPage" not in hub:
        errors += fail("FeatureHubView should navigate via settingsPage + open")

    lproj = sorted(p.name for p in (ROOT / "Resources").glob("*.lproj"))
    if lproj != ["en.lproj", "ko.lproj"]:
        errors += fail(f"localizations are {lproj}, expected en and ko only")

    plist = ET.parse(ROOT / "Resources" / "Info.plist")
    keys = [node.text for node in plist.getroot().iter("key")]
    values = [node.text for node in plist.getroot().iter("string")]
    if "io.github.qaws81877.fixdock" not in values:
        errors += fail("Info.plist bundle id is not FixDock")
    if "CFBundleDisplayName" not in keys:
        errors += fail("Info.plist is missing a display name")

    build = (ROOT / "build.sh").read_text(encoding="utf-8")
    if "io.github.qaws81877.fixdock" not in build:
        errors += fail("build.sh does not set the FixDock bundle id")
    if "arm64-apple-macosx14.0" not in build:
        errors += fail("build.sh does not target macOS 14 arm64")

    for relative in URL_SCAN_ROOTS:
        for path in iter_text_files(relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            for needle in FORBIDDEN:
                if needle in text:
                    errors += fail(f"{path.relative_to(ROOT)} contains {needle}")
            for url in re.findall(r"https://[^\s)>\"]+", text):
                url = url.rstrip(".,")
                if not any(url == allowed or url.startswith(allowed) for allowed in ALLOWED_URLS):
                    errors += fail(f"{path.relative_to(ROOT)} has URL {url}")

    if errors:
        print(f"{errors} check(s) failed", file=sys.stderr)
        return 1
    print(f"ok: {len(swift_files)} Swift files, {len(en_labels)} strings, shell only")
    return 0


if __name__ == "__main__":
    sys.exit(main())

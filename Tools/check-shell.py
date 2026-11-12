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
    "inputSwitch",
    "clipboardHistory",
]
ALLOWED_URLS = {
    "https://github.com/vorssaint/vorssaint-utils",
    "https://github.com/qaws81877/FixDock",
    "https://github.com/qaws81877/FixDock.git",
    "https://github.com/qaws81877/homebrew-tap",
    "https://api.github.com/repos/qaws81877/FixDock/releases/latest",
    "https://www.gnu.org/licenses/gpl-3.0.en.html",
    "https://fixdock-feedback.answlals1236.workers.dev",
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
    "3D485" + "NHW29",
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
    "PRIVACY.md",
    "Tools/uninstall.sh",
    "Tools/feedback-relay",
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
        "github.com/codingnoye/gksdud",
        "Copyright (c) 2026 CodingNoye",
        "Permission is hereby granted, free of charge",
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
        "            || self == .cleaner || self == .screenshot || self == .screenRecorder\n"
        "            || self == .inputSwitch || self == .clipboardHistory\n" not in catalog
    ):
        errors += fail("only the URL cleaner, quit protection, cleaning mode, text snippets, media, AirDrop auto-zip, cleaner, screenshot, screen recorder, input switch and clipboard history should have a service")

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

    # Each risky capability lives only in the files listed for it.
    def files_with(needle):
        return sorted(
            str(path.relative_to(ROOT / "Sources/FixDock"))
            for path in swift_files
            if needle in path.read_text(encoding="utf-8")
        )

    for needle, allowed in (
        ("URLSession", ["Services/FeedbackTransport.swift", "Services/UpdateTransport.swift"]),
        ("feedbackRelayURL", ["Core/AppInfo.swift", "Services/FeedbackTransport.swift"]),
        ("RENAME_SWAP", ["Services/Relauncher.swift"]),
        ("FIXDOCK_LOCAL_FEED", ["Services/UpdateTransport.swift"]),
        ("483JM5VB4A", ["Core/AppInfo.swift"]),
        # Input switch: every macOS write lives in one file (docs/input-switch.md).
        ('"UserKeyMapping"', ["Services/InputSwitchSystem.swift"]),
        ("IOHIDServiceClientSetProperty", ["Services/InputSwitchSystem.swift"]),
        ('"com.apple.symbolichotkeys"', ["Services/InputSwitchSystem.swift"]),
        ("CFPreferencesSetAppValue", ["Services/InputSwitchSystem.swift"]),
        ("SystemAdministration.framework", ["Services/InputSwitchSystem.swift"]),
        ('"kern.bootsessionuuid"', ["Services/InputSwitchSystem.swift"]),
        ("OwnKeyEvent.inputSwitchMarker", ["Services/InputSwitchService.swift"]),
        # Typing tools share one tap, and only it posts their output (docs/typo-switch.md 5.12).
        ("CGEvent.tapCreate", ["Services/CleaningModeManager.swift", "Services/InputSwitchService.swift",
                               "Services/QuitProtectionService.swift", "Services/TypingTap.swift"]),
        ("OwnKeyEvent.textSnippetMarker", ["Services/TypingTap.swift"]),
        ("TypingTap.shared.setSnippets", ["Services/TextSnippetService.swift"]),
        # Layout fix: one owner of the learned-words file, the guard's only constructor.
        ('"LayoutFix.json"', ["Core/LayoutFixLearnedStore.swift"]),
        ("LayoutFixLearnedRecords(", ["Core/LayoutFixLearnedStore.swift"]),
        ("IOHIDSetModifierLockState", ["Services/InputSwitchCapsLock.swift"]),
        # Clipboard history: one owner of the file, the guard's only
        # constructor, one store (docs/clipboard-history.md, deletion guard).
        ('"ClipboardHistory.json"', ["Core/ClipboardHistoryStore.swift"]),
        ("ClipboardHistoryRecords(", ["Core/ClipboardHistoryStore.swift"]),
        ("ClipboardHistoryStore(", ["Services/ClipboardHistoryService.swift"]),
        ('"ClipboardHistoryImages"', ["Core/ClipboardHistoryBlobs.swift"]),
        ("ClipboardHistoryBlobs(", ["Core/ClipboardHistoryStore.swift"]),
        ("ClipboardHistoryLandedWrite(", ["Core/ClipboardHistoryStore.swift"]),
        (".sweep(after:", ["Core/ClipboardHistoryStore.swift"]),
        ("ClipboardImagePayload(", ["Core/ClipboardHistoryBlobs.swift"]),
        ("ClipboardHistoryService.ownCopy(", ["Services/RecorderGIFClipboard.swift",
                                              "Services/ScreenshotService.swift"]),
    ):
        found = files_with(needle)
        if found != allowed:
            errors += fail(f"{needle} must appear only in {allowed}, found in {found}")
    # Switching through the system shortcut only: selecting a source directly breaks Hangul composition.
    if files_with("TISSelectInputSource"):
        errors += fail(f"TISSelectInputSource is not allowed (gksdud: switch through the shortcut only), found in {files_with('TISSelectInputSource')}")
    for path in swift_files:
        text = path.read_text(encoding="utf-8")
        if "adapted from gksdud" in text and "Copyright (c) 2026 CodingNoye" not in text:
            errors += fail(f"{path.name}: gksdud-derived code must keep the CodingNoye copyright line")
    # The clipboard history never removes, moves or renames a file, except one
    # unlinkat inside ClipboardHistoryBlobs.sweep(after:), the image sweep that
    # runs only after a durable history write. Comments count too.
    history_store = (ROOT / "Sources/FixDock/Core/ClipboardHistoryStore.swift").read_text(encoding="utf-8")
    if history_store.count("ClipboardHistoryLandedWrite(") != 1 or history_store.count(".sweep(after:") != 1:
        errors += fail("ClipboardHistoryStore.swift: the landed-write token is made once and swept once, in persist()")
    if "writeDurably(encoded.data" not in history_store:
        errors += fail("ClipboardHistoryStore.swift: the history write before a sweep must be durable")
    deletion = re.compile(
        r"\b(removeItem|trashItem|unlink|unlinkat|moveItem|replaceItem|rename|renameat|renamex_np"
        r"|renameatx_np|rmdir|removefile|exchangedata|truncate|ftruncate)\b|\bremove\s*\(\s*[a-zA-Z_.]*(path|url|URL)")
    # The learned-words store never removes, moves or renames a file either. Comments count too.
    if deletion.search((ROOT / "Sources/FixDock/Core/LayoutFixLearnedStore.swift").read_text(encoding="utf-8")):
        errors += fail("LayoutFixLearnedStore.swift must not remove, move or rename a file")
    for path in swift_files:
        if path.name.startswith("ClipboardHistory") or path.name == "ClipboardIgnoredApps.swift":
            text = path.read_text(encoding="utf-8")
            found = [m.group(0) for m in deletion.finditer(text)]
            if path.name == "ClipboardHistoryBlobs.swift":
                start = text.find("func sweep(after")
                body = ""
                if start >= 0 and text.count("func sweep(after") == 1:
                    depth = 0
                    for offset in range(text.index("{", start), len(text)):
                        depth += {"{": 1, "}": -1}.get(text[offset], 0)
                        if depth == 0:
                            body = text[start:offset + 1]
                            break
                if found != ["unlinkat"] or body.count("unlinkat(") != 1:
                    errors += fail("ClipboardHistoryBlobs.swift: exactly one unlinkat, inside sweep(after:), and no other deletion")
                if "ClipboardHistory.json" in text:
                    errors += fail("ClipboardHistoryBlobs.swift must never name the history file")
            elif found:
                errors += fail(f"{path.name}: the clipboard history must not use {sorted(set(found))}")
    # The permission guide only reads System Settings (docs/permission-guide.md),
    # and the rest of the app reaches it only through its three-member surface.
    guide_path = ROOT / "Sources/FixDock/UI/PermissionGuideOverlay.swift"
    guide = guide_path.read_text(encoding="utf-8")
    for needle in ("AXUIElementPerformAction", "AXUIElementSetAttributeValue"):
        if needle in guide:
            errors += fail(f"PermissionGuideOverlay.swift must not use {needle}")
    for path in swift_files:
        if path == guide_path:
            continue
        if re.search(r"PermissionGuideOverlay\.(?!shared\.show\(|shared\.dismiss\(|suppressed\b)",
                     path.read_text(encoding="utf-8")):
            errors += fail(f"{path.relative_to(ROOT)} uses PermissionGuideOverlay beyond shared.show(, shared.dismiss( and suppressed")
    for path in swift_files:
        if path.name.startswith("Update") and path.name != "UpdateWorkspace.swift":
            if "removeItem" in path.read_text(encoding="utf-8"):
                errors += fail(f"{path.name}: removals under Updates belong only in UpdateWorkspace")

    sources = ROOT / "Sources/FixDock"
    policy_imports = re.findall(r"^import (\w+)", (sources / "Core/UpdatePolicy.swift").read_text(encoding="utf-8"), re.M)
    if policy_imports != ["Foundation"]:
        errors += fail(f"UpdatePolicy.swift must import only Foundation, imports {policy_imports}")
    relauncher = (sources / "Services/Relauncher.swift").read_text(encoding="utf-8")
    relauncher_imports = re.findall(r"^import (\w+)", relauncher, re.M)
    if relauncher_imports != ["Darwin", "Foundation", "Security"] or re.search(
        r"\bNS(App|Application|Workspace|RunningApplication)\b", relauncher
    ):
        errors += fail("Relauncher.swift (the helper) must not use AppKit")
    support_imports = re.findall(r"^import (\w+)", (sources / "Core/InputSwitchSupport.swift").read_text(encoding="utf-8"), re.M)
    if support_imports != ["Foundation"]:
        errors += fail(f"InputSwitchSupport.swift must import only Foundation, imports {support_imports}")
    pin_imports = re.findall(r"^import (\w+)", (sources / "Core/ScreenshotPinSupport.swift").read_text(encoding="utf-8"), re.M)
    if pin_imports != ["Carbon", "CoreGraphics", "Foundation", "ImageIO"]:
        errors += fail(f"ScreenshotPinSupport.swift must import only Carbon, CoreGraphics, Foundation and ImageIO, imports {pin_imports}")
    for relative, expected in (
        ("Core/ClipboardHistoryStore.swift", ["Foundation"]),
        ("Core/ClipboardHistorySupport.swift", ["CoreGraphics", "Foundation"]),
        ("Core/ClipboardHistoryBlobs.swift", ["CryptoKit", "Foundation", "ImageIO"]),
        ("Core/ClipboardHistoryKinds.swift", ["Foundation"]),
        ("Core/TypingSupport.swift", ["Foundation"]),
        ("Core/LayoutFixSupport.swift", ["Foundation"]),
        ("Core/LayoutFixLearnedStore.swift", ["Foundation"]),
    ):
        found = re.findall(r"^import (\w+)", (sources / relative).read_text(encoding="utf-8"), re.M)
        if found != expected:
            errors += fail(f"{relative} must import only {expected}, imports {found}")
    # The layout fix reads keys with their Shift state; swappedLayout folds it away (docs/typo-switch.md 5.12).
    if "swappedLayout" in (sources / "Core/LayoutFixSupport.swift").read_text(encoding="utf-8"):
        errors += fail("LayoutFixSupport.swift must not use swappedLayout")
    switch_system = (sources / "Services/InputSwitchSystem.swift").read_text(encoding="utf-8")
    if re.search(r"^import (AppKit|SwiftUI)", switch_system, re.M) or re.search(r"\bNS(App|Application|Workspace)\b", switch_system):
        errors += fail("InputSwitchSystem.swift must not use AppKit (it also runs headless)")
    if "--restore-input-switch" not in (sources / "main.swift").read_text(encoding="utf-8"):
        errors += fail("main.swift must handle --restore-input-switch")
    uninstall = (ROOT / "Tools/uninstall.sh").read_text(encoding="utf-8")
    if not (0 < uninstall.find("pkill") < uninstall.find("--restore-input-switch") < uninstall.find("rm -rf")):
        errors += fail("Tools/uninstall.sh must quit the app, then --restore-input-switch, then remove it")
    statements = [
        line for line in (sources / "main.swift").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith(("//", "import "))
    ]
    if not statements or not statements[0].startswith("Relauncher.runIfHelper("):
        errors += fail("the first statement of main.swift must be Relauncher.runIfHelper")
    if "FIXDOCK_LOCAL_FEED" not in (ROOT / "build.sh").read_text(encoding="utf-8"):
        errors += fail("build.sh should own the local-feed compile flag")

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

    # The update log (Settings › Update log) gains an entry with every release.
    top = list(plist.getroot().find("dict"))
    bundle_version = next(
        (top[i + 1].text for i, node in enumerate(top[:-1])
         if node.tag == "key" and node.text == "CFBundleShortVersionString"),
        None,
    )
    changelog = (sources / "Core/Changelog.swift").read_text(encoding="utf-8")
    if re.findall(r"^import (\w+)", changelog, re.M) != ["Foundation"]:
        errors += fail("Changelog.swift must import only Foundation")
    chunks = changelog.split("ChangelogEntry(")[1:]
    versions = []
    for chunk in chunks:
        head = re.match(r'\s*version: "(\d+)\.(\d+)\.(\d+)", date: "(\d{4}-\d{2}-\d{2})",', chunk)
        if not head:
            errors += fail(f"Changelog.swift: an entry does not start with version: \"x.y.z\", date: \"yyyy-MM-dd\": {chunk[:60]!r}")
            continue
        version = tuple(int(part) for part in head.groups()[:3])
        versions.append(version)
        label = ".".join(map(str, version))
        for language in ("english", "korean"):
            if not re.search(language + r':\s*\[\s*"', chunk):
                errors += fail(f"Changelog.swift: {label} has no {language} items")
    if not versions:
        errors += fail("Changelog.swift has no entries")
    elif ".".join(map(str, versions[0])) != bundle_version:
        errors += fail(
            f"Changelog.swift starts at {'.'.join(map(str, versions[0]))} but Info.plist is {bundle_version}; "
            "add this version's entry in English and Korean before tagging"
        )
    if any(newer <= older for newer, older in zip(versions, versions[1:])):
        errors += fail("Changelog.swift versions must be unique and newest first")

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
                url = url.rstrip(".,`")
                if not any(url == allowed or url.startswith(tuple(allowed + end for end in "/?#"))
                           for allowed in ALLOWED_URLS):
                    errors += fail(f"{path.relative_to(ROOT)} has URL {url}")

    if errors:
        print(f"{errors} check(s) failed", file=sys.stderr)
        return 1
    print(f"ok: {len(swift_files)} Swift files, {len(en_labels)} strings, shell only")
    return 0


if __name__ == "__main__":
    sys.exit(main())

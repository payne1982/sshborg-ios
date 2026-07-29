#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Converts the Android string resources into an iOS String Catalog.

The Android app is the source of truth for wording and translations: 287 strings
in 10 languages, already shipped and reviewed by real users. Retranslating them
for iOS would produce two apps that say different things, so this imports them
instead — and it is a script rather than a one-off edit because the Android side
keeps changing, and every future sync should be a re-run rather than a merge.

    ./scripts/import-android-strings.py ../claude-sshborg

Writes Sources/Resources/Localizable.xcstrings and, next to it, a Swift file of
typed constants so a call site reads `Text(.actionCancel)` and a mistyped key is
a compile error instead of a label that silently shows "action_cancel".

The Android keys are kept verbatim as catalog keys. That is what makes a future
sync mechanical: the two catalogues can be diffed by key.

Read-only with respect to the Android tree. It is never written to.
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Android locale directory -> iOS language code.
LOCALES = {
    "values": "en",
    "values-de": "de",
    "values-es": "es",
    "values-fr": "fr",
    "values-it": "it",
    "values-ja": "ja",
    "values-pt": "pt",
    "values-ru": "ru",
    "values-uk": "uk",
    "values-zh-rCN": "zh-Hans",
}

SOURCE_LANGUAGE = "en"

# Android quantity keywords that iOS also understands. Android has "zero",
# "two" and "few" as well; none are used here, and they map one-to-one if they
# ever are.
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")


def decode(text: str) -> str:
    """Undoes Android's string escaping.

    Android escapes apostrophes and quotes with a backslash and writes newlines
    as \\n. iOS wants the characters themselves, and a stray backslash would be
    shown literally.
    """
    if text is None:
        return ""

    # Order matters: \\ must be handled before the escapes it could produce.
    out = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            nxt = text[index + 1]
            out.append({"n": "\n", "t": "\t", "'": "'", '"': '"', "\\": "\\"}.get(nxt, nxt))
            index += 2
            continue
        out.append(char)
        index += 1

    # Android wraps a whole string in double quotes when it has leading or
    # trailing spaces to preserve.
    result = "".join(out)
    if len(result) >= 2 and result[0] == '"' and result[-1] == '"':
        result = result[1:-1]
    return result


def convert_format_specifiers(text: str) -> str:
    """Rewrites Android's format arguments in the syntax Apple's formatter uses.

    `%s` means "a string" to Java and "a C string" to Apple; the Apple spelling
    for an object is `%@`. Getting this wrong does not fail to build — it
    crashes at the moment the string is shown, which is why it is done here and
    not left to whoever writes the call site.
    """
    text = re.sub(r"%(\d+\$)s", r"%\1@", text)
    text = re.sub(r"(?<!%)%s", "%@", text)
    return text


def swift_identifier(key: str) -> str:
    """`settings_confirm_exit_title` -> `settingsConfirmExitTitle`."""
    head, *rest = key.split("_")
    name = head + "".join(part.capitalize() for part in rest)

    # A digit cannot start an identifier, and a Swift keyword cannot be one.
    if name and name[0].isdigit():
        name = "_" + name
    if name in {"default", "continue", "repeat", "return", "class", "import", "case", "for", "in", "is", "as", "true", "false", "nil"}:
        name += "Value"
    return name


def parse(path: Path) -> tuple[dict[str, str], dict[str, dict[str, str]], set[str]]:
    """Returns (strings, plurals, untranslatable keys) for one resource file."""
    root = ET.parse(path).getroot()

    strings: dict[str, str] = {}
    plurals: dict[str, dict[str, str]] = {}
    untranslatable: set[str] = set()

    for element in root:
        name = element.get("name")
        if not name:
            continue

        if element.tag == "string":
            if element.get("translatable") == "false":
                untranslatable.add(name)
            # itertext() keeps the text of inline markup such as <b>, which the
            # catalog cannot represent anyway.
            strings[name] = convert_format_specifiers(decode("".join(element.itertext())))

        elif element.tag == "plurals":
            items = {}
            for item in element.findall("item"):
                quantity = item.get("quantity")
                if quantity in PLURAL_CATEGORIES:
                    items[quantity] = convert_format_specifiers(decode("".join(item.itertext())))
            if items:
                plurals[name] = items

    return strings, plurals, untranslatable


def load_ios_only(catalog_path: Path, android_keys: set[str]) -> dict[str, dict]:
    """Keeps entries this app added that Android has no equivalent for.

    Some strings exist only here — the ones about jump host chains being active,
    or anything naming Face ID. Without this they would be silently dropped by
    the next run of the importer, which is the sort of loss nobody notices until
    a screen shows a raw key. Anything whose name is not in the Android set is
    carried over untouched.
    """
    if not catalog_path.exists():
        return {}

    try:
        existing = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}

    return {
        key: value
        for key, value in existing.get("strings", {}).items()
        if key not in android_keys
    }


def build_catalog(android_res: Path, catalog_path: Path) -> tuple[dict, list[str], set[str]]:
    base_strings, base_plurals, untranslatable = parse(android_res / "values" / "strings.xml")

    android_keys = set(base_strings) | set(base_plurals)
    entries: dict[str, dict] = load_ios_only(catalog_path, android_keys)
    carried_over = len(entries)

    for key in list(base_strings) + list(base_plurals):
        entries[key] = {"extractionState": "manual", "localizations": {}}

    missing_report: list[str] = []

    for directory, language in LOCALES.items():
        path = android_res / directory / "strings.xml"
        if not path.exists():
            missing_report.append(f"{directory}: no strings.xml")
            continue

        strings, plurals, _ = parse(path)

        for key, value in strings.items():
            if key not in android_keys:
                continue  # present in a translation but not in the base
            if language != SOURCE_LANGUAGE and key in untranslatable:
                continue
            entries[key]["localizations"][language] = {
                "stringUnit": {"state": "translated", "value": value}
            }

        for key, items in plurals.items():
            if key not in android_keys:
                continue
            entries[key]["localizations"][language] = {
                "variations": {
                    "plural": {
                        category: {"stringUnit": {"state": "translated", "value": text}}
                        for category, text in items.items()
                    }
                }
            }

        if language != SOURCE_LANGUAGE:
            absent = [
                key for key in android_keys
                if key not in untranslatable and language not in entries[key]["localizations"]
            ]
            if absent:
                missing_report.append(f"{language}: {len(absent)} untranslated")

    catalog = {
        "sourceLanguage": SOURCE_LANGUAGE,
        "version": "1.0",
        "strings": dict(sorted(entries.items())),
    }
    if carried_over:
        missing_report.append(f"{carried_over} iOS-only keys carried over")

    return catalog, missing_report, set(base_plurals)


def build_swift(catalog: dict, plural_keys: set[str]) -> str:
    lines = [
        "// SPDX-License-Identifier: GPL-3.0-or-later",
        "//",
        "// Generated by scripts/import-android-strings.py — do not edit.",
        "//",
        "// The keys are the Android app's, verbatim, so the two catalogues can be",
        "// diffed by key when the Android side gains or changes a string.",
        "",
        "import Foundation",
        "",
        "extension LocalizedStringResource {",
        "",
    ]

    seen: dict[str, str] = {}
    for key in catalog["strings"]:
        identifier = swift_identifier(key)
        if identifier in seen:
            raise SystemExit(f"identifier clash: {key} and {seen[identifier]} both give {identifier}")
        seen[identifier] = key

        english = (
            catalog["strings"][key]["localizations"]
            .get(SOURCE_LANGUAGE, {})
            .get("stringUnit", {})
            .get("value")
        )
        if english is None and key in plural_keys:
            english = (
                catalog["strings"][key]["localizations"]
                .get(SOURCE_LANGUAGE, {})
                .get("variations", {})
                .get("plural", {})
                .get("other", {})
                .get("stringUnit", {})
                .get("value")
            )

        if english:
            comment = english.replace("\n", " ").strip()
            if len(comment) > 88:
                comment = comment[:85] + "…"
            lines.append(f"    /// {comment}")
        lines.append(f'    static let {identifier} = LocalizedStringResource("{key}")')
        lines.append("")

    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    android_root = Path(sys.argv[1]).expanduser().resolve()
    android_res = android_root / "app" / "src" / "main" / "res"
    if not (android_res / "values" / "strings.xml").exists():
        print(f"no Android resources under {android_res}", file=sys.stderr)
        return 1

    repo = Path(__file__).resolve().parent.parent
    resources = repo / "Sources" / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    catalog_path = resources / "Localizable.xcstrings"

    catalog, missing, plural_keys = build_catalog(android_res, catalog_path)
    catalog_path.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    swift_path = repo / "Sources" / "Resources" / "Strings.swift"
    swift_path.write_text(build_swift(catalog, plural_keys), encoding="utf-8")

    print(f"{len(catalog['strings'])} keys -> {catalog_path.relative_to(repo)}")
    print(f"{len(catalog['strings'])} constants -> {swift_path.relative_to(repo)}")
    for line in missing:
        print(f"  note: {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

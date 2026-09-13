#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Catches mistakes that are cheap to find here and expensive to find on the
# build VM, where a round trip costs several minutes.
#
# Run from the repository root, on any machine, before syncing:
#
#     ./scripts/check-sources.sh
#
# Exits non-zero on the first category that has hits, so it can gate a sync.

set -uo pipefail
cd "$(dirname "$0")/.."

status=0

fail() {
    printf '\n\033[31m%s\033[0m\n' "$1"
    status=1
}

# 1. `await` inside an XCTest macro.
#
# XCTAssert* take autoclosures, which are not async, so `XCTAssertEqual(try
# await …)` does not compile. The fix is always to bind the value first:
#
#     let all = try await hosts.fetchAll()
#     XCTAssertEqual(all.count, 3)
#
# This has been written three times and caught by the compiler three times, at
# a few minutes each. It is the reason this script exists.
hits=$(grep -rn --include='*.swift' -E 'XCT(Assert[A-Za-z]*|Unwrap)\((try )?await ' Tests/ 2>/dev/null)
if [ -n "$hits" ]; then
    fail "await inside an XCTest macro — bind the value to a let first:"
    echo "$hits"
fi

# 2. Missing licence header. The project is GPL-3.0-or-later and every source
#    file carries the SPDX line; a new file that forgets it is easy to miss in
#    review and awkward to fix later across a history.
missing=""
while IFS= read -r file; do
    head -1 "$file" | grep -q 'SPDX-License-Identifier' || missing="$missing$file"$'\n'
done < <(find Sources Tests -name '*.swift' 2>/dev/null)
if [ -n "$missing" ]; then
    fail "missing SPDX licence header:"
    printf '%s' "$missing"
fi

# 3. Function-like libssh2 macros, which Swift does not import. They compile as
#    "cannot find in scope", which is clear enough — but the `_ex` form is not
#    obvious unless you already know, so name it here.
hits=$(grep -rn --include='*.swift' -E '\blibssh2_(session_init|channel_open_session|channel_read|channel_write|userauth_password|channel_close_ex)\(' Sources/ 2>/dev/null)
if [ -n "$hits" ]; then
    fail "function-like libssh2 macro — Swift only sees the _ex form:"
    echo "$hits"
fi

# 4. Localisation keys that do not exist in the catalog.
#
# `Text(.someKey)` and `String(localized: .someKey)` resolve against generated
# constants, so a key that does not exist is a compile error — eventually, after
# a four-minute round trip to the build machine. Four keys were invented in one
# session by plausible analogy with real ones (host_dialog_title_new,
# sftp_upload_cd, sftp_uploading_label, terminalTitle), which is a systematic
# mistake rather than carelessness, so it gets a mechanical check.
hits=$(python3 - <<'PYCHECK'
import json, pathlib, re, sys

catalog = pathlib.Path("Sources/Resources/Localizable.xcstrings")
if not catalog.exists():
    sys.exit(0)

def identifier(key):
    head, *rest = key.split("_")
    name = head + "".join(p.capitalize() for p in rest)
    return "_" + name if name[:1].isdigit() else name

known = {identifier(k) for k in json.loads(catalog.read_text(encoding="utf-8"))["strings"]}

used = re.compile(r'(?:String\(localized:\s*|Text\(|\bTogglee?\()\s*\.([a-z][A-Za-z0-9]*)')
problems = []
for path in sorted(pathlib.Path("Sources").rglob("*.swift")):
    if path.name == "Strings.swift":
        continue
    text = path.read_text(encoding="utf-8")
    for m in used.finditer(text):
        name = m.group(1)
        # SwiftUI has its own leading-dot members; only flag names that look
        # like catalog keys and are absent from it.
        if name not in known and re.match(r'^(ios|action|host|hosts|keys|keygen|settings|sftp|group|terminal|error|backup|about|timeout|hostkey|session|notification|transfer)', name):
            problems.append(f"{path}:{text[:m.start()].count(chr(10)) + 1}: .{name}")

print("\n".join(problems))
PYCHECK
)
if [ -n "$hits" ]; then
    fail "localisation key not in Localizable.xcstrings:"
    echo "$hits"
fi

# 5. An iOS-only string whose English text already exists on the Android side.
#
# The iOS-only keys are meant for text Android has no equivalent for. Two of them
# turned out to be word-for-word copies of existing Android strings under
# different names — `ios_session_number` was `session_picker_session_label` — so
# they were translated here by hand when a reviewed translation already existed.
#
# The earlier check compares *names*, which is exactly what missed this: a
# different name with identical text passes it. This compares the English text.
#
# Needs the Android tree; skipped silently when it is not beside this one.
ANDROID_STRINGS="../claude-sshborg/app/src/main/res/values/strings.xml"
if [ -f "$ANDROID_STRINGS" ]; then
    hits=$(python3 - "$ANDROID_STRINGS" <<'PYDUP'
import json, pathlib, re, sys, xml.etree.ElementTree as ET

catalog = pathlib.Path("Sources/Resources/Localizable.xcstrings")
if not catalog.exists():
    sys.exit(0)

# Pairs that share an English word by coincidence rather than meaning, checked
# by hand. A one-word string like "Actions" will collide with anything, and
# collapsing the two would tie a screen here to a string whose Android meaning
# is different — a later rename there would silently change this app's wording.
#
# Both sides of each pair have been compared in all ten languages and are
# already word for word identical, so nothing is lost by keeping them apart.
ALLOWED = {
    # The SFTP file menu, against the "Actions" group in the key catalogue.
    ("ios_sftp_actions", "extra_key_group_actions"),
}


def normalise(text):
    text = text.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n")
    return re.sub(r'%(\d+\$)s', r'%\1@', text).strip().lower()

android = {}
for element in ET.parse(sys.argv[1]).getroot():
    if element.tag == "string" and element.get("name"):
        android.setdefault(normalise("".join(element.itertext())), element.get("name"))

problems = []
for key, entry in json.loads(catalog.read_text(encoding="utf-8"))["strings"].items():
    if "iOS only" not in (entry.get("comment") or ""):
        continue
    english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    if not english:
        continue
    twin = android.get(normalise(english))
    if twin and (key, twin) not in ALLOWED:
        problems.append(f"  {key} duplicates Android's {twin}")

print("\n".join(problems))
PYDUP
)
    if [ -n "$hits" ]; then
        fail "iOS-only string that Android already has — use the Android key, its translation is reviewed:"
        echo "$hits"
    fi
fi

# 6. iOS 17 API at a 16.0 deployment target.
#
# These compile only because the simulator runs something newer; the phone the
# app is tested on is an A11 device capped at 16.7.x, where they are absent.
# Xcode does report them, but only after a sync and a build — several minutes
# to be told something a grep knows.
#
# `@Observable` has a replacement (`@Perceptible`, from the Perception package)
# and so do the others; see Sources/App/BackDeployment.swift and
# Sources/App/EmptyStateView.swift.
hits=$(grep -rn --include='*.swift' -E \
    '@Observable|@ObservationIgnored|ContentUnavailableView|\.topBar(Leading|Trailing)|\.navigationDestination\(item:' \
    Sources/ 2>/dev/null | grep -v 'Sources/App/EmptyStateView.swift')
if [ -n "$hits" ]; then
    fail "iOS 17 API, and the deployment target is 16.0:"
    echo "$hits"
fi

# 7. `onChange` spelled directly.
#
# The two-parameter closure is iOS 17 and the one-parameter form is deprecated
# there, so every call site goes through `onValueChange` in BackDeployment.swift.
# This check also caught the shim calling itself: a bulk rewrite turned its own
# iOS 17 branch into `onValueChange`, which compiled and would have recursed
# until the stack ran out on every modern device.
hits=$(grep -rn --include='*.swift' -E '\.onChange\(of:' Sources/ 2>/dev/null \
    | grep -v 'Sources/App/BackDeployment.swift')
if [ -n "$hits" ]; then
    fail "onChange used directly — use onValueChange, see Sources/App/BackDeployment.swift:"
    echo "$hits"
fi

# 8. A view or scene that reads observable state without WithPerceptionTracking.
#
# At a 16.0 deployment target @Observable comes from Perception, and a body that
# reads a perceptible object outside WithPerceptionTracking simply stops
# updating. It compiles, and on a modern simulator it even works — Perception
# delegates to real Observation from iOS 17 — so nothing catches it until the
# phone.
#
# This exists because the audit that wrapped every body was written to look for
# `struct X: View` and therefore skipped SSHBorgApp, which is `some Scene`. Its
# `lock.isLocked` was read on every pass of the scene, untracked: a stream of
# runtime warnings on the device, and a lock cover that could never come down.
# The check is deliberately coarse — file-level, not body-level — because that
# is what makes it hard to slip past.
hits=""
for f in $(grep -rl --include='*.swift' -E 'body: some (View|Scene)|func body\(content:' Sources/); do
    grep -q 'WithPerceptionTracking' "$f" && continue
    # Both spellings matter. Naming the type is the obvious one; reaching the
    # object through AppEnvironment is the one that actually got past this
    # check on the first attempt, because SSHBorgApp names no perceptible type
    # at all — it reads `environment.lock.isLocked`.
    reads=$(grep -nE '\b(AppPreferences|AppLock|SessionManager|TerminalSession|HostsModel|KeysModel|SettingsModel|SFTPModel|SFTPBrowsers|TransferManager|KeyboardVisibility)\b|\.(lock|preferences|sessions|browsers|transfers)\.[a-zA-Z_]' "$f" \
        | grep -vE '^[0-9]+:\s*(//|///)' | head -3)
    [ -n "$reads" ] && hits="$hits\n$f\n$reads"
done
if [ -n "$hits" ]; then
    fail "view or scene reads observable state with no WithPerceptionTracking:"
    printf '%b\n' "$hits"
fi

# 9. Navigation driven by `SessionManager.selected`.
#
# That property falls back to the first tab when nothing is selected, so it
# reports the same session whether the terminal is on screen or the host list
# is. Anything that navigates on a *change* of it therefore misses the only
# case that matters: resuming the single open session, where the value before
# and after are identical. On the phone that was a terminal you could leave and
# never get back into — the host row, the resume entry and the session picker
# all did nothing, and only a second session made it work. See RootView and the
# note on the property itself; `selectedID` is the one to navigate on.
hits=$(grep -rn --include='*.swift' -E '(onValueChange|onChange)\(of: [^,)]*\.selected[^I]' Sources/ 2>/dev/null)
if [ -n "$hits" ]; then
    fail "navigation keyed on .selected — it cannot see a resume; use .selectedID:"
    echo "$hits"
fi

# 10. A preference that nothing reads.
#
# A setting offered in Settings, stored and carried in backups while no code acts
# on it looks exactly like a finished feature. It happened seven times during the
# port, and then four more at once, found on 13/09/2026 only because the website's
# user guide was being checked against the code: keep screen on, the double-tap
# action, scrollback lines and inverted scrolling — in the build already sent for
# review.
#
# Every property of AppPreferences needs a reader outside the files that only
# store it, back it up or edit it. The exceptions are deliberate and say why in
# their doc comments.
hits=""
for p in $(grep -oE '^    var [a-zA-Z]+' Sources/Data/AppPreferences.swift | awk '{print $2}'); do
    case "$p" in allowScreenshots|confirmExit) continue ;; esac
    n=$(grep -rnE "\\.$p\\b" --include='*.swift' Sources/ \
        | grep -vE 'Sources/Data/(AppPreferences|BackupArchive|BackupService)\.swift|Sources/Features/Settings/SettingsScreen\.swift' \
        | wc -l)
    [ "$n" -eq 0 ] && hits="$hits  $p\n"
done
if [ -n "$hits" ]; then
    fail "preference that nothing reads — wire it up, or say in its doc comment why not:"
    printf '%b' "$hits"
fi

if [ "$status" -eq 0 ]; then
    printf '\033[32mok\033[0m — no known-pattern problems\n'
fi

exit "$status"

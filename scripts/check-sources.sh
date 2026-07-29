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

if [ "$status" -eq 0 ]; then
    printf '\033[32mok\033[0m — no known-pattern problems\n'
fi

exit "$status"

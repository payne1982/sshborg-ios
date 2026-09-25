#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adds one *working* host to the simulator's database, for the UI tests that
need a server to be there.

    ./scripts/dev/seed-live-host.py <sqlite> <label> <hostname> <user> <password-file>

`seed-simulator-hosts.py` deliberately seeds no credentials: its hosts exist to
be listed, sorted and photographed, and a fixture carrying a password is a
fixture nobody can share. This is the other case — the editor and the file
browser cannot be photographed at all without a server that answers — so it
takes one host and reads its password from a file, never from the command line,
where it would land in the shell history and the process list.

Everything it writes lives in one simulator's container and goes with `simctl
erase`. Nothing here belongs in a repository.
"""
import pathlib
import sqlite3
import sys

if len(sys.argv) != 6:
    print(__doc__)
    raise SystemExit(2)

db, label, hostname, user, password_file = sys.argv[1:]
password = pathlib.Path(password_file).read_text().strip()

connection = sqlite3.connect(db)
connection.execute("DELETE FROM hosts WHERE label = ?", (label,))
# The schema differs between versions; build the statement from what is there.
columns = {row[1] for row in connection.execute("PRAGMA table_info(hosts)")}
values = {
    "label": label,
    "hostname": hostname,
    "port": 22,
    "username": user,
    "password": password,
    "agentForwarding": 0,
    "jumpMode": "simple",
    "sftpStartMode": "home",
    "allowLegacyCiphers": 0,
    "sftpShowHidden": 0,
    "connectCount": 0,
}
present = {name: value for name, value in values.items() if name in columns}
connection.execute(
    "INSERT INTO hosts ({}) VALUES ({})".format(
        ", ".join(present), ", ".join("?" for _ in present)
    ),
    tuple(present.values()),
)
connection.commit()
print(f"seeded {label} -> {user}@{hostname}")

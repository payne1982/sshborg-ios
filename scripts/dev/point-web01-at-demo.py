#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Points the seeded `web-01` at the temporary screenshot server.

Run after the host-list screenshot, which must show the fictional
web01.example.com, and before the terminal and SFTP ones. The label stays
`web-01`, which is all those two screens show.

    point-web01-at-demo.py <sshborg.sqlite> <host> <port> <user>

Prints the public key of `deploy@web-01` so the harness can authorise it.
"""
import sqlite3
import sys

db, host, port, user = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
connection = sqlite3.connect(db)
cursor = connection.cursor()
key = cursor.execute("SELECT id, publicKey FROM ssh_keys WHERE label = 'deploy@web-01'").fetchone()
if key is None:
    sys.exit("no key labelled deploy@web-01 — run the key pass first")
cursor.execute(
    "UPDATE hosts SET hostname = ?, port = ?, username = ?, keyId = ?, password = NULL,"
    " knownHostsEntry = NULL, sftpStartMode = 'fixed', sftpStartDir = '/home/deploy'"
    " WHERE label = 'web-01'",
    (host, port, user, key[0]),
)
if cursor.rowcount != 1:
    sys.exit(f"expected one web-01, updated {cursor.rowcount}")
connection.commit()
print(key[1])

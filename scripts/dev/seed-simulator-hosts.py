#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Puts a plausible host list into the simulator's database.

    ./scripts/dev/seed-simulator-hosts.py "$(xcrun simctl get_app_container \\
        <device-udid> com.sshborg data)/Library/Application Support/sshborg.sqlite"

Run it with the app not running. Several UI tests skip on an empty list — the
host menu ones have nothing to long-press — so a fresh simulator quietly stops
checking the things they were written for.


Fictional names only — nothing from anybody's real network — and no
credentials: the list draws, sorts and reorders perfectly well without them,
and a fixture that carries a password is a fixture nobody can share.

The shape is chosen so the four orders actually differ from each other:
usage counts and last-connected times that do not follow the labels, two
hosts never connected to, and two groups so the section headers and the
group move have something to move.

Positions are left null on purpose. That is the real starting state, and it
means switching to the manual order exercises the lazy seeding rather than
stepping around it.
"""
import sqlite3
import sys

db = sys.argv[1]

GROUPS = [
    # name, ARGB colour from HostGroup.swatches, collapsed
    ("Production", 0xFF039BE5, 0),
    ("Lab",        0xFF43A047, 0),
]

# label, hostname, port, username, group, lastConnected (ms), connectCount, legacy
HOSTS = [
    ("backup-nas",    "nas.example.net",    22,   "admin",    None,         1788900000000,  3, 0),
    ("raspberry",     "pi.example.org",     22,   "pi",       None,         None,           0, 0),
    ("vps-frankfurt", "fra1.example.com",   22,   "root",     None,         1789200000000, 12, 0),
    ("web-01",        "web01.example.com",  22,   "deploy",   "Production", 1789100000000, 27, 0),
    ("web-02",        "web02.example.com",  22,   "deploy",   "Production", 1788000000000,  5, 0),
    ("db-primary",    "db1.example.com",    2222, "postgres", "Production", 1788500000000,  9, 0),
    ("testbed",       "lab.example.org",    22,   "tester",   "Lab",        1787000000000,  1, 0),
    ("old-switch",    "switch.example.org", 22,   "admin",    "Lab",        None,           0, 1),
]

connection = sqlite3.connect(db)
cursor = connection.cursor()

group_ids = {}
for name, colour, collapsed in GROUPS:
    cursor.execute(
        'INSERT INTO host_groups ("name", "color", "collapsed", "position") VALUES (?, ?, ?, NULL)',
        (name, colour, collapsed),
    )
    group_ids[name] = cursor.lastrowid

for label, hostname, port, username, group, last, count, legacy in HOSTS:
    cursor.execute(
        'INSERT INTO hosts ("label", "hostname", "port", "username", "groupId",'
        ' "lastConnected", "connectCount", "allowLegacyCiphers", "position")'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)',
        (label, hostname, port, username, group_ids.get(group), last, count, legacy),
    )

connection.commit()
print("groups:", cursor.execute("SELECT count(*) FROM host_groups").fetchone()[0])
print("hosts: ", cursor.execute("SELECT count(*) FROM hosts").fetchone()[0])
connection.close()

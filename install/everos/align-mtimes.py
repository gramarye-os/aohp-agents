#!/usr/bin/env python3
"""Make a shipped EverOS index accept the local Markdown files as already indexed.

The index records each file's mtime (md_change_state.mtime). A copy of the
index made on another host carries that host's mtimes, so the scanner here
would see every file as modified and index it again. This sets the recorded
mtime of each finished row to the local file's mtime. Run it with EverOS
stopped, and only when the store is at the commit the index was made from.

usage: align-mtimes.py <everos root> [--dry-run]
"""
import os
import sqlite3
import sys

root = sys.argv[1]
dry = "--dry-run" in sys.argv[2:]
db = sqlite3.connect(os.path.join(root, ".index", "sqlite", "system.db"))
rows = db.execute(
    "select md_path, mtime, status, change_type from md_change_state"
).fetchall()
changed = same = missing = other = 0
for md_path, mtime, status, change_type in rows:
    if status != "done" or change_type == "deleted":
        other += 1
        print("left alone: %s status=%s change=%s" % (md_path, status, change_type))
        continue
    try:
        local = os.stat(os.path.join(root, md_path)).st_mtime
    except FileNotFoundError:
        missing += 1
        print("not on disk: %s" % md_path)
        continue
    if abs(local - mtime) < 1e-6:
        same += 1
        continue
    changed += 1
    if not dry:
        db.execute(
            "update md_change_state set mtime = ? where md_path = ?", (local, md_path)
        )
if not dry:
    db.commit()
db.close()
print("rows=%d aligned=%d already_equal=%d missing=%d left_alone=%d%s" % (
    len(rows), changed, same, missing, other, " (dry run)" if dry else ""))
sys.exit(1 if missing or other else 0)

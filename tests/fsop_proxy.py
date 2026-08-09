#!/usr/bin/env python3
"""A transparent proxy in front of the real daemon that fakes fs-op failures.

The daemon-backed paste has three failure exits that a healthy daemon on a
healthy filesystem will not take, and that no amount of fixture-building in
Vim can reach:

  * the backend answers an `fs_op` with a protocol-level `error` instead of an
    `fs_op_done` (it does this when the request is refused before it is ever
    dispatched, e.g. at the active-request limit),
  * the backend dies with a transfer still outstanding,
  * a transfer fails *after* the old target has already been displaced, so the
    reply carries `installed: false` together with a non-empty `backup`.

All three leave the paste chain hanging or the user's original file orphaned
under a hidden name if the frontend mishandles them, so they need coverage.
This process gives it to them: every request is forwarded to the real daemon
and every reply is forwarded back, so the tree lists, watches and expands for
real — except that an `fs_op` whose source name contains one of the trigger
words below is answered here instead.  Selecting the behaviour by filename
keeps a single daemon instance serving every scenario in one test run.

  refuse   -> {"type":"error", "id":N, ...}, no fs_op_done ever
  orphan   -> fs_op_done with installed:false and a backup path
  crash    -> no reply at all; the proxy and the daemon both exit

Usage: SIMPLETREE_PROXY_TARGET=/path/to/simpletree-daemon tests/fsop_proxy.py
"""

import json
import os
import subprocess
import sys
import threading

BACKUP_SUFFIX = ".simpletree-backup-proxy"
REFUSAL = "backend refused the transfer"
ORPHAN_MESSAGE = "install failed and rollback failed: simulated by fsop_proxy"

_write_lock = threading.Lock()


def emit(obj):
    with _write_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def main():
    target = os.environ.get("SIMPLETREE_PROXY_TARGET", "")
    if not target:
        sys.stderr.write("fsop_proxy: SIMPLETREE_PROXY_TARGET is not set\n")
        return 2

    child = subprocess.Popen(
        [target],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def pump():
        for reply in child.stdout:
            with _write_lock:
                sys.stdout.write(reply)
                sys.stdout.flush()
        # The daemon is gone; so is the point of this process.
        os._exit(0)

    threading.Thread(target=pump, daemon=True).start()

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            request = {}

        if isinstance(request, dict) and request.get("type") == "fs_op":
            rid = request.get("id", 0)
            src = os.path.basename(request.get("src", ""))
            if "refuse" in src:
                emit({"type": "error", "id": rid, "message": REFUSAL})
                continue
            if "orphan" in src:
                emit({
                    "type": "fs_op_done",
                    "id": rid,
                    "installed": False,
                    "source_removed": False,
                    "backup": request.get("dst", "") + BACKUP_SUFFIX,
                    "message": ORPHAN_MESSAGE,
                })
                continue
            if "crash" in src:
                child.kill()
                os._exit(1)

        child.stdin.write(line)
        child.stdin.flush()

    child.stdin.close()
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())

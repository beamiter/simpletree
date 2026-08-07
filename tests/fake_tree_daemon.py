#!/usr/bin/env python3
"""Minimal SimpleTree daemon for deterministic frontend reveal tests."""

import json
import os
import sys
import time


def emit(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def list_entries(request):
    entries = []
    show_hidden = bool(request.get("show_hidden", False))
    for entry in sorted(os.scandir(request.get("path", "")), key=lambda item: item.name.lower()):
        if not show_hidden and entry.name.startswith("."):
            continue
        item = {
            "name": entry.name,
            "path": entry.path,
            "is_dir": entry.is_dir(follow_symlinks=False),
            "is_symlink": entry.is_symlink(),
        }
        if request.get("meta"):
            stat = entry.stat(follow_symlinks=False)
            item["size"] = stat.st_size
            item["mtime"] = int(stat.st_mtime)
        entries.append(item)
    limit = max(1, int(request.get("max", 200)))
    return entries[:limit]


def main():
    first_list = True
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            emit({"type": "error", "message": "bad json"})
            continue

        request_type = request.get("type", "")
        request_id = request.get("id", 0)
        if request_type == "ping":
            emit({
                "type": "pong",
                "id": request_id,
                "protocol_version": 3,
                "capabilities": [],
            })
        elif request_type == "list":
            try:
                entries = list_entries(request)
                if first_list:
                    first_list = False
                    deferred = [entry for entry in entries if entry["name"] == "top.txt"]
                    early = [entry for entry in entries if entry["name"] != "top.txt"]
                    emit({
                        "type": "list_chunk",
                        "id": request_id,
                        "entries": early,
                        "warnings": [],
                        "done": False,
                    })
                    time.sleep(1.1)
                    entries = deferred
                emit({
                    "type": "list_chunk",
                    "id": request_id,
                    "entries": entries,
                    "warnings": [],
                    "done": True,
                })
            except OSError as error:
                emit({"type": "error", "id": request_id, "message": str(error)})
        elif request_type == "cancel":
            emit({"type": "ok", "id": request_id})
        else:
            emit({
                "type": "error",
                "id": request_id,
                "message": "unknown type " + request_type,
            })


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Install PixelCat's Claude Code editing hook without replacing existing hooks."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path


MATCHER = "Edit|Write|NotebookEdit"
COMMAND = (
    "python3 /Users/khomkrit.ain/.pixelcat/session.py coding "
    "'กำลังแก้ไฟล์ด้วย Claude Code'"
)


def install(target: Path, *, backup: bool = True) -> tuple[bool, Path | None]:
    try:
        settings = json.loads(target.read_text(encoding="utf-8")) if target.exists() else {}
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"อ่าน settings ไม่สำเร็จ: {error}") from error

    if not isinstance(settings, dict):
        raise RuntimeError("settings.json ต้องมี JSON object เป็นค่าหลัก")
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise RuntimeError("ค่า hooks เดิมไม่ใช่ JSON object จึงไม่แก้ทับให้")
    pre_tool_use = hooks.setdefault("PreToolUse", [])
    if not isinstance(pre_tool_use, list):
        raise RuntimeError("ค่า hooks.PreToolUse เดิมไม่ใช่ JSON array จึงไม่แก้ทับให้")

    for group in pre_tool_use:
        if not isinstance(group, dict) or group.get("matcher") != MATCHER:
            continue
        handlers = group.get("hooks", [])
        if any(isinstance(item, dict) and item.get("command") == COMMAND for item in handlers):
            return False, None

    pre_tool_use.append(
        {
            "matcher": MATCHER,
            "hooks": [{"type": "command", "command": COMMAND}],
        }
    )

    target.parent.mkdir(parents=True, exist_ok=True)
    backup_path = None
    if backup and target.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = target.with_name(f"{target.name}.pixelcat-backup-{stamp}")
        suffix = 1
        while backup_path.exists():
            backup_path = target.with_name(
                f"{target.name}.pixelcat-backup-{stamp}-{suffix}"
            )
            suffix += 1
        shutil.copy2(target, backup_path)

    mode = target.stat().st_mode if target.exists() else 0o600
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.pixelcat-", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            json.dump(settings, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return True, backup_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--target",
        type=Path,
        default=Path.home() / ".claude" / "settings.json",
    )
    parser.add_argument("--no-backup", action="store_true")
    args = parser.parse_args()

    try:
        changed, backup_path = install(args.target.expanduser(), backup=not args.no_backup)
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if changed:
        print("installed PixelCat Claude editing hook")
        if backup_path:
            print(f"backup: {backup_path}")
    else:
        print("PixelCat Claude editing hook already installed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

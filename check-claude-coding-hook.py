#!/usr/bin/env python3
"""Regression check for the idempotent Claude Code hook installer."""

import json
import tempfile
from pathlib import Path

from install_claude_coding_hook import COMMAND, MATCHER, install


with tempfile.TemporaryDirectory(prefix="pixelcat-hook-check-") as directory:
    target = Path(directory) / "settings.json"
    original = {
        "theme": "dark",
        "hooks": {
            "Stop": [
                {"hooks": [{"type": "command", "command": "existing-hook"}]}
            ]
        },
    }
    target.write_text(json.dumps(original), encoding="utf-8")

    changed, backup = install(target)
    assert changed and backup and backup.exists()
    installed = json.loads(target.read_text(encoding="utf-8"))
    assert installed["theme"] == "dark"
    assert installed["hooks"]["Stop"] == original["hooks"]["Stop"]
    groups = installed["hooks"]["PreToolUse"]
    assert any(
        group.get("matcher") == MATCHER
        and any(hook.get("command") == COMMAND for hook in group.get("hooks", []))
        for group in groups
    )

    changed_again, second_backup = install(target)
    assert not changed_again and second_backup is None
    assert len(installed["hooks"]["PreToolUse"]) == len(
        json.loads(target.read_text(encoding="utf-8"))["hooks"]["PreToolUse"]
    )

print("PASS: Claude editing hook installs once and preserves existing settings")

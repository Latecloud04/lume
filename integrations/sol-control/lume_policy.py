#!/usr/bin/python3
"""Persistent two-mode policy shared by Lume and Sol Control."""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import stat
import tempfile
import time
from typing import Any

SCHEMA = 1
MAX_BYTES = 4096
VALID_MODES = {"openai", "quota-save"}


class StateError(Exception):
    pass


def codex_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex")


def policy_path() -> pathlib.Path:
    return codex_home() / "sol-control-policy.json"


def _safe_read(path: pathlib.Path) -> dict[str, Any]:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise StateError("missing") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise StateError("not a regular file")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise StateError("unsafe permissions")
    if info.st_size > MAX_BYTES:
        raise StateError("too large")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_size > MAX_BYTES
            or opened.st_dev != info.st_dev
            or opened.st_ino != info.st_ino
        ):
            raise StateError("file changed during validation")
        data = os.read(descriptor, MAX_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(data) > MAX_BYTES:
        raise StateError("too large")
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StateError("invalid JSON") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise StateError("invalid schema")
    return value


def _ensure_parent(path: pathlib.Path) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.parent.lstat()
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) & 0o022
    ):
        raise StateError("unsafe parent directory")


def _atomic_write(path: pathlib.Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    if len(payload) > MAX_BYTES:
        raise StateError("payload too large")
    _ensure_parent(path)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def _read_mode() -> tuple[str, str]:
    try:
        value = _safe_read(policy_path())
        if set(value) != {"schema", "mode", "updatedAt"}:
            raise StateError("invalid fields")
        updated_at = value.get("updatedAt")
        if isinstance(updated_at, bool) or not isinstance(updated_at, (int, float)) or not math.isfinite(float(updated_at)):
            raise StateError("invalid timestamp")
        mode = value.get("mode")
        if mode in VALID_MODES:
            return str(mode), "policy"
        return "openai", "default"
    except StateError:
        return "openai", "default"


def resolve() -> dict[str, Any]:
    mode, source = _read_mode()
    return {
        "schema": SCHEMA,
        "mode": mode,
        "configuredMode": mode,
        "source": source,
        "remainingPercentage": None,
        "signalStatus": "not-used",
        "reason": f"selected {mode} mode" if source == "policy" else "default openai mode",
    }


def set_mode(mode: str) -> dict[str, Any]:
    value = {"schema": SCHEMA, "mode": mode, "updatedAt": time.time()}
    _atomic_write(policy_path(), value)
    return value


def doctor() -> dict[str, Any]:
    home = codex_home()
    installed_helper = home / "skills" / "sol-control" / "scripts" / "lume_policy.py"
    skill = home / "skills" / "sol-control" / "SKILL.md"
    checks = {
        "helper": installed_helper.is_file() and os.access(installed_helper, os.X_OK),
        "skill": skill.is_file() and "LUME-SOL-CONTROL-BEGIN" in skill.read_text(errors="ignore"),
    }
    return {"schema": SCHEMA, "available": all(checks.values()), "checks": checks, "resolution": resolve()}


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("resolve")
    set_parser = commands.add_parser("set-mode")
    set_parser.add_argument("mode", choices=sorted(VALID_MODES))
    commands.add_parser("doctor")
    args = parser.parse_args()
    try:
        if args.command == "resolve":
            output = resolve()
        elif args.command == "set-mode":
            output = set_mode(args.mode)
        else:
            output = doctor()
        json.dump(output, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")
    except (OSError, StateError) as error:
        print(f"lume_policy: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    import sys

    main()

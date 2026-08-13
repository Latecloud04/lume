#!/usr/bin/python3
"""Shared Lume/Sol Control state reader and atomic policy writer."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import stat
import sys
import tempfile
import time
from typing import Any

SCHEMA = 1
MAX_BYTES = 4096
FRESH_SECONDS = 15 * 60
LOW_FALLBACK_SECONDS = 24 * 60 * 60
VALID_MODES = {"auto", "openai", "quota-save"}


class StateError(Exception):
    pass


def codex_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex")


def signal_path() -> pathlib.Path:
    override = os.environ.get("LUME_STATE_PATH")
    if override:
        return pathlib.Path(override)
    return pathlib.Path.home() / "Library" / "Application Support" / "Lume" / "sol-control-state.json"


def policy_path() -> pathlib.Path:
    return codex_home() / "sol-control-policy.json"


def _number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise StateError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise StateError(f"{name} must be finite")
    return result


def _safe_read(path: pathlib.Path) -> dict[str, Any]:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise StateError("missing") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise StateError("not a regular file")
    if info.st_uid != os.getuid():
        raise StateError("wrong owner")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise StateError("unsafe permissions")
    if info.st_size > MAX_BYTES:
        raise StateError("too large")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
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


def _require_keys(value: dict[str, Any], required: set[str], optional: set[str] | None = None) -> None:
    allowed = required | (optional or set())
    if set(value) != required and not (required <= set(value) <= allowed):
        raise StateError("invalid fields")


def _ensure_parent(path: pathlib.Path) -> None:
    parent = path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = parent.lstat()
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
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _read_policy() -> tuple[str, str | None]:
    try:
        value = _safe_read(policy_path())
        _require_keys(value, {"schema", "mode", "updatedAt"})
        mode = value.get("mode")
        if mode not in VALID_MODES:
            raise StateError("invalid mode")
        _number(value.get("updatedAt"), "updatedAt")
        return str(mode), None
    except StateError as error:
        return "auto", str(error)


def _read_signal(now: float) -> tuple[dict[str, Any] | None, str | None]:
    try:
        value = _safe_read(signal_path())
        _require_keys(
            value,
            {"schema", "status", "remainingPercentage", "observedAt", "lowUntil", "suggestedMode"},
            {"resetsAt"},
        )
        remaining = _number(value.get("remainingPercentage"), "remainingPercentage")
        observed = _number(value.get("observedAt"), "observedAt")
        low_until = _number(value.get("lowUntil"), "lowUntil")
        status_value = value.get("status")
        if not 0 <= remaining <= 100 or status_value not in {"low", "normal"}:
            raise StateError("invalid signal values")
        expected_mode = "quota-save" if status_value == "low" else "openai"
        if value.get("suggestedMode") != expected_mode:
            raise StateError("invalid suggested mode")
        if "resetsAt" in value:
            resets_at = _number(value.get("resetsAt"), "resetsAt")
            if resets_at < 0:
                raise StateError("invalid reset time")
        if observed > now + 300 or low_until < observed:
            raise StateError("invalid signal times")
        result = dict(value)
        result["remainingPercentage"] = remaining
        result["observedAt"] = observed
        result["lowUntil"] = low_until
        return result, None
    except StateError as error:
        return None, str(error)


def resolve(now: float) -> dict[str, Any]:
    configured_mode, policy_error = _read_policy()
    signal, signal_error = _read_signal(now)
    remaining = signal.get("remainingPercentage") if signal else None
    signal_status = signal.get("status") if signal else "unavailable"
    if configured_mode in {"openai", "quota-save"}:
        return {
            "schema": SCHEMA,
            "mode": configured_mode,
            "configuredMode": configured_mode,
            "source": "override",
            "remainingPercentage": remaining,
            "signalStatus": signal_status,
            "reason": f"persistent {configured_mode} override",
            "policyError": policy_error,
            "signalError": signal_error,
        }
    if signal and signal["status"] == "low" and now <= signal["lowUntil"]:
        mode = "quota-save"
        source = "lume"
        reason = "Lume reports low 7D allowance"
    elif signal and signal["status"] == "normal" and now - signal["observedAt"] <= FRESH_SECONDS:
        mode = "openai"
        source = "lume"
        reason = "Lume reports normal 7D allowance"
    else:
        mode = "openai"
        source = "fallback"
        reason = "Lume signal is unavailable or expired"
    return {
        "schema": SCHEMA,
        "mode": mode,
        "configuredMode": "auto",
        "source": source,
        "remainingPercentage": remaining,
        "signalStatus": signal_status,
        "reason": reason,
        "policyError": policy_error,
        "signalError": signal_error,
    }


def publish(path: pathlib.Path, remaining: float, observed_at: float, resets_at: float | None, low_until: float | None) -> dict[str, Any]:
    remaining = _number(remaining, "remaining")
    observed_at = _number(observed_at, "observedAt")
    resets_at = _number(resets_at, "resetsAt") if resets_at is not None else None
    low_until = _number(low_until, "lowUntil") if low_until is not None else None
    if not 0 <= remaining <= 100:
        raise StateError("remaining must be between zero and one hundred")
    if observed_at < 0 or (resets_at is not None and resets_at < 0):
        raise StateError("timestamps must be non-negative")
    previous_status = "normal"
    try:
        previous = _safe_read(path)
        if previous.get("status") in {"low", "normal"}:
            previous_status = str(previous["status"])
    except StateError:
        pass
    if remaining < 20:
        status_value = "low"
    elif remaining >= 25:
        status_value = "normal"
    else:
        status_value = previous_status
    if low_until is None:
        low_until = (resets_at + FRESH_SECONDS) if resets_at is not None else (observed_at + LOW_FALLBACK_SECONDS)
    if low_until < observed_at:
        raise StateError("lowUntil must not precede observedAt")
    value: dict[str, Any] = {
        "schema": SCHEMA,
        "status": status_value,
        "remainingPercentage": remaining,
        "observedAt": observed_at,
        "lowUntil": low_until,
        "suggestedMode": "quota-save" if status_value == "low" else "openai",
    }
    if resets_at is not None:
        value["resetsAt"] = resets_at
    _atomic_write(path, value)
    return value


def doctor() -> dict[str, Any]:
    home = codex_home()
    installed_helper = home / "skills" / "sol-control" / "scripts" / "lume_policy.py"
    installed_hook = home / "hooks" / "lume-sol-control" / "user_prompt_submit.py"
    skill = home / "skills" / "sol-control" / "SKILL.md"
    hook_config = home / "hooks.json"
    checks = {
        "helper": installed_helper.is_file() and os.access(installed_helper, os.X_OK),
        "hook": installed_hook.is_file() and os.access(installed_hook, os.X_OK),
        "skill": skill.is_file() and "LUME-SOL-CONTROL-BEGIN" in skill.read_text(errors="ignore"),
        "hookConfig": False,
        "hookProof": False,
    }
    try:
        config = json.loads(hook_config.read_text())
        groups = config.get("hooks", {}).get("UserPromptSubmit", [])
        checks["hookConfig"] = any("lume-sol-control/user_prompt_submit.py" in json.dumps(group) for group in groups)
    except (OSError, json.JSONDecodeError, AttributeError):
        pass
    try:
        proof = _safe_read(home / "lume-sol-control-hook-proof.json")
        _require_keys(proof, {"schema", "eventAt", "hookDigest", "helperDigest"})
        event_at = _number(proof.get("eventAt"), "eventAt")
        checks["hookProof"] = (
            event_at <= time.time() + 300
            and proof.get("hookDigest") == hashlib.sha256(installed_hook.read_bytes()).hexdigest()
            and proof.get("helperDigest") == hashlib.sha256(installed_helper.read_bytes()).hexdigest()
        )
    except (OSError, StateError):
        pass
    return {"schema": SCHEMA, "available": all(checks.values()), "checks": checks, "resolution": resolve(time.time())}


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    resolve_parser = commands.add_parser("resolve")
    resolve_parser.add_argument("--now", type=float, default=time.time())
    set_parser = commands.add_parser("set-mode")
    set_parser.add_argument("mode", choices=sorted(VALID_MODES))
    publish_parser = commands.add_parser("publish")
    publish_parser.add_argument("--path", type=pathlib.Path, default=signal_path())
    publish_parser.add_argument("--remaining", type=float, required=True)
    publish_parser.add_argument("--observed-at", type=float, required=True)
    publish_parser.add_argument("--resets-at", type=float)
    publish_parser.add_argument("--low-until", type=float)
    commands.add_parser("doctor")
    args = parser.parse_args()
    try:
        if args.command == "resolve":
            output = resolve(args.now)
        elif args.command == "set-mode":
            output = {"schema": SCHEMA, "mode": args.mode, "updatedAt": time.time()}
            _atomic_write(policy_path(), output)
        elif args.command == "publish":
            output = publish(args.path, args.remaining, args.observed_at, args.resets_at, args.low_until)
        else:
            output = doctor()
        json.dump(output, sys.stdout, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")
    except (OSError, StateError) as error:
        json.dump({"schema": SCHEMA, "error": str(error)}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        raise SystemExit(1)


if __name__ == "__main__":
    main()

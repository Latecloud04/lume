#!/usr/bin/python3
"""Inject Lume routing state only for explicit Sol Control prompts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import sys
import time


def load_policy():
    installed = pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex") / "skills" / "sol-control" / "scripts" / "lume_policy.py"
    path = installed if installed.is_file() else pathlib.Path(__file__).with_name("lume_policy.py")
    spec = importlib.util.spec_from_file_location("lume_policy", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load Lume policy helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--now", type=float, default=time.time())
    args = parser.parse_args()
    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError:
        raise SystemExit(0)
    if hook_input.get("hook_event_name") != "UserPromptSubmit":
        return
    prompt = str(hook_input.get("prompt") or "")
    if not re.search(r"\$sol-control\b", prompt, re.IGNORECASE):
        return
    try:
        policy = load_policy()
        helper_path = pathlib.Path(policy.__file__).resolve()
        hook_path = pathlib.Path(__file__).resolve()
        proof = {
            "schema": policy.SCHEMA,
            "eventAt": args.now,
            "hookDigest": hashlib.sha256(hook_path.read_bytes()).hexdigest(),
            "helperDigest": hashlib.sha256(helper_path.read_bytes()).hexdigest(),
        }
        policy._atomic_write(policy.codex_home() / "lume-sol-control-hook-proof.json", proof)
        structured = re.search(r"\bmode\s*=\s*(auto|openai|quota-save)\b", prompt, re.IGNORECASE)
        if structured:
            mode = structured.group(1).lower()
            policy._atomic_write(policy.policy_path(), {"schema": policy.SCHEMA, "mode": mode, "updatedAt": args.now})
        resolution = policy.resolve(args.now)
        remaining = resolution.get("remainingPercentage")
        remaining_text = "unknown" if remaining is None else f"{remaining:g}%"
        context = (
            f"SOL_CONTROL_CONFIGURED_MODE={resolution['configuredMode']}\n"
            f"SOL_CONTROL_RESOLVED_MODE={resolution['mode']}\n"
            f"SOL_CONTROL_MODE_SOURCE={resolution['source']}\n"
            f"LUME_7D_REMAINING={remaining_text}\n"
            "This trusted local machine state applies only to explicit Sol Control routing. "
            "A user directive limited to this call overrides it. Re-run the installed resolver immediately before every new worker spawn."
        )
        json.dump(
            {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}},
            sys.stdout,
            ensure_ascii=False,
            separators=(",", ":"),
        )
    except Exception:
        # A routing aid must never block the user's Codex prompt.
        return


if __name__ == "__main__":
    main()

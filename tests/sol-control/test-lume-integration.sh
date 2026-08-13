#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HELPER="$ROOT/integrations/sol-control/lume_policy.py"
HOOK="$ROOT/integrations/sol-control/user_prompt_submit.py"
INSTALLER="$ROOT/integrations/sol-control/install.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lume-sol-control-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

json_field() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

run_resolve() {
  CODEX_HOME="$TMP_ROOT/codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
    /usr/bin/python3 "$HELPER" resolve --now "$1"
}

mkdir -p "$TMP_ROOT/codex"

[[ -f "$HELPER" ]] || fail "missing policy helper"
[[ -f "$HOOK" ]] || fail "missing UserPromptSubmit hook"
[[ -x "$INSTALLER" ]] || fail "missing executable installer"

result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "missing signal must fail open"

/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 19.9 \
  --observed-at 900 --resets-at 2000 --low-until 2900 >/dev/null
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == quota-save ]] || fail "fresh low signal must select quota-save"

/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 22 \
  --observed-at 950 --resets-at 2000 --low-until 2900 >/dev/null
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == quota-save ]] || fail "twenty-two percent must preserve the low hysteresis state"

/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 25 \
  --observed-at 1000 --resets-at 3000 --low-until 3900 >/dev/null
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "twenty-five percent must recover auto mode"

CODEX_HOME="$TMP_ROOT/codex" /usr/bin/python3 "$HELPER" set-mode openai >/dev/null
/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 5 \
  --observed-at 1000 --resets-at 3000 --low-until 3900 >/dev/null
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "persistent openai override must win"

CODEX_HOME="$TMP_ROOT/codex" /usr/bin/python3 "$HELPER" set-mode quota-save >/dev/null
/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 100 \
  --observed-at 1000 --resets-at 3000 --low-until 3900 >/dev/null
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == quota-save ]] || fail "persistent quota-save override must win"

CODEX_HOME="$TMP_ROOT/codex" /usr/bin/python3 "$HELPER" set-mode auto >/dev/null
chmod 0644 "$TMP_ROOT/lume.json"
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "unsafe signal permissions must fail open"
chmod 0600 "$TMP_ROOT/lume.json"
mv "$TMP_ROOT/lume.json" "$TMP_ROOT/real-lume.json"
ln -s "$TMP_ROOT/real-lume.json" "$TMP_ROOT/lume.json"
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "signal symlink must fail open"

rm -f "$TMP_ROOT/lume.json"
printf '{"schema":1,"unexpected":true}\n' >"$TMP_ROOT/lume.json"
chmod 0600 "$TMP_ROOT/lume.json"
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "unknown signal fields must fail open"

/usr/bin/python3 - "$TMP_ROOT/lume.json" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b"x" * 4097)
PY
chmod 0600 "$TMP_ROOT/lume.json"
result=$(run_resolve 1000)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "oversized signal must fail open"

rm -f "$TMP_ROOT/lume.json"
/usr/bin/python3 "$HELPER" publish --path "$TMP_ROOT/lume.json" --remaining 10 \
  --observed-at 100 --resets-at 200 --low-until 300 >/dev/null
result=$(run_resolve 301)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "expired low signal must fail open"

hook_input='{"hook_event_name":"UserPromptSubmit","turn_id":"turn-1","prompt":"[$sol-control] 修复测试"}'
hook_output=$(printf '%s' "$hook_input" | CODEX_HOME="$TMP_ROOT/codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
  /usr/bin/python3 "$HOOK" --now 250)
printf '%s' "$hook_output" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit"; assert "SOL_CONTROL_RESOLVED_MODE=quota-save" in d["hookSpecificOutput"]["additionalContext"]' \
  || fail "hook must inject resolved Sol Control context"

structured_input='{"hook_event_name":"UserPromptSubmit","turn_id":"turn-mode","prompt":"[$sol-control] mode=openai"}'
structured_output=$(printf '%s' "$structured_input" | CODEX_HOME="$TMP_ROOT/codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
  /usr/bin/python3 "$HOOK" --now 250)
printf '%s' "$structured_output" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert "SOL_CONTROL_CONFIGURED_MODE=openai" in d["hookSpecificOutput"]["additionalContext"]; assert "SOL_CONTROL_RESOLVED_MODE=openai" in d["hookSpecificOutput"]["additionalContext"]' \
  || fail "structured mode directive must persist before resolution"
CODEX_HOME="$TMP_ROOT/codex" /usr/bin/python3 "$HELPER" set-mode auto >/dev/null

plain_output=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","turn_id":"turn-2","prompt":"普通问题"}' \
  | CODEX_HOME="$TMP_ROOT/codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" /usr/bin/python3 "$HOOK" --now 250)
[[ -z "$plain_output" ]] || fail "hook must ignore prompts without Sol Control"

discussion_output=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","turn_id":"turn-discussion","prompt":"讨论 Sol Control 的设计"}' \
  | CODEX_HOME="$TMP_ROOT/codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" /usr/bin/python3 "$HOOK" --now 250)
[[ -z "$discussion_output" ]] || fail "hook must require an explicit dollar-prefixed Sol Control invocation"

mkdir -p "$TMP_ROOT/read-only-codex"
chmod 0500 "$TMP_ROOT/read-only-codex"
failure_output=$(printf '%s' "$hook_input" | CODEX_HOME="$TMP_ROOT/read-only-codex" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
  /usr/bin/python3 "$HOOK" --now 250)
chmod 0700 "$TMP_ROOT/read-only-codex"
[[ -z "$failure_output" ]] || fail "hook failures must not emit malformed routing context"

install_home="$TMP_ROOT/install-codex"
mkdir -p "$install_home/hooks/codex-deepseek-subagent" "$install_home/skills/sol-control"
printf '%s\n' '#!/usr/bin/python3' >"$install_home/hooks/codex-deepseek-subagent/plaintext_handoff.py"
cat >"$install_home/skills/sol-control/SKILL.md" <<'MARKDOWN'
---
name: sol-control
---
# Sol Control
## Select the mode
- Default to `openai`.
- Never silently switch modes.

In `openai` mode:
- Use OpenAI workers.
MARKDOWN
cat >"$install_home/hooks.json" <<'JSON'
{"description":"existing","hooks":{"SubagentStart":[{"matcher":"^v4-flash-worker$","hooks":[{"type":"command","command":"existing-v4-hook"}]}]}}
JSON
CODEX_HOME="$install_home" "$INSTALLER" --source-root "$ROOT" >/dev/null
CODEX_HOME="$install_home" "$INSTALLER" --source-root "$ROOT" >/dev/null
/usr/bin/python3 - "$install_home/hooks.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert len(data["hooks"]["SubagentStart"]) == 1
assert data["hooks"]["SubagentStart"][0]["hooks"][0]["command"] == "existing-v4-hook"
assert len(data["hooks"]["UserPromptSubmit"]) == 1
PY

[[ -x "$install_home/skills/sol-control/scripts/lume_policy.py" ]] || fail "installer did not install helper"
[[ -x "$install_home/hooks/lume-sol-control/user_prompt_submit.py" ]] || fail "installer did not install hook"
rg -q 'lume_policy.py.*resolve' "$install_home/skills/sol-control/SKILL.md" \
  || fail "installer did not add the resolver contract to Sol Control"

installed_hook_input='{"hook_event_name":"UserPromptSubmit","turn_id":"turn-3","prompt":"[$sol-control] 验证联动"}'
printf '%s' "$installed_hook_input" | CODEX_HOME="$install_home" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
  /usr/bin/python3 "$install_home/hooks/lume-sol-control/user_prompt_submit.py" --now 250 >/dev/null
doctor=$(CODEX_HOME="$install_home" LUME_STATE_PATH="$TMP_ROOT/lume.json" \
  /usr/bin/python3 "$install_home/skills/sol-control/scripts/lume_policy.py" doctor)
[[ $(printf '%s' "$doctor" | json_field available) == True ]] \
  || fail "doctor must require proof from the currently installed trusted hook contents"

printf 'PASS Lume Sol Control integration tests\n'

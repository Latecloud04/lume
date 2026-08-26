#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HELPER="$ROOT/integrations/sol-control/lume_policy.py"
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

run_helper() {
  CODEX_HOME="$TMP_ROOT/codex" /usr/bin/python3 "$HELPER" "$@"
}

mkdir -p "$TMP_ROOT/codex"
[[ -f "$HELPER" ]] || fail "missing policy helper"
[[ -x "$INSTALLER" ]] || fail "missing executable installer"

result=$(run_helper resolve)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "new policy defaults to openai"
[[ $(printf '%s' "$result" | json_field configuredMode) == openai ]] || fail "resolved default is a persistent user mode"

run_helper set-mode quota-save >/dev/null
result=$(run_helper resolve)
[[ $(printf '%s' "$result" | json_field mode) == quota-save ]] || fail "quota-save persists"

run_helper set-mode openai >/dev/null
result=$(run_helper resolve)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "openai persists"

if run_helper set-mode auto >/dev/null 2>&1; then
  fail "auto is not a selectable mode"
fi

printf '{"schema":1,"mode":"auto","updatedAt":1}\n' >"$TMP_ROOT/codex/sol-control-policy.json"
chmod 0600 "$TMP_ROOT/codex/sol-control-policy.json"
result=$(run_helper resolve)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "legacy auto normalizes to openai"

printf '{"schema":1,"mode":"unknown","updatedAt":1}\n' >"$TMP_ROOT/codex/sol-control-policy.json"
chmod 0600 "$TMP_ROOT/codex/sol-control-policy.json"
result=$(run_helper resolve)
[[ $(printf '%s' "$result" | json_field mode) == openai ]] || fail "invalid policy normalizes to openai"

install_home="$TMP_ROOT/install-codex"
mkdir -p "$install_home/hooks/lume-sol-control" "$install_home/skills/sol-control"
printf '%s\n' '#!/usr/bin/python3' >"$install_home/hooks/lume-sol-control/user_prompt_submit.py"
printf '%s\n' '{"schema":1}' >"$install_home/lume-sol-control-hook-proof.json"
printf '%s\n' '{"schema":1}' >"$TMP_ROOT/legacy-signal.json"
cat >"$install_home/skills/sol-control/SKILL.md" <<'MARKDOWN'
---
name: sol-control
---
# Sol Control
## Select the mode
- Default to `openai`.

In `openai` mode:
- Use OpenAI workers.
MARKDOWN
cat >"$install_home/hooks.json" <<JSON
{
  "description": "existing",
  "hooks": {
    "SubagentStart": [{"matcher":"^v4-flash-worker$","hooks":[{"type":"command","command":"existing-v4-hook"}]}],
    "UserPromptSubmit": [
      {"hooks":[{"type":"command","command":"/usr/bin/python3 $install_home/hooks/lume-sol-control/user_prompt_submit.py"}]},
      {"hooks":[{"type":"command","command":"keep-user-hook"}]}
    ]
  }
}
JSON

CODEX_HOME="$install_home" LUME_STATE_PATH="$TMP_ROOT/legacy-signal.json" "$INSTALLER" --source-root "$ROOT" >/dev/null
CODEX_HOME="$install_home" LUME_STATE_PATH="$TMP_ROOT/legacy-signal.json" "$INSTALLER" --source-root "$ROOT" >/dev/null

/usr/bin/python3 - "$install_home/hooks.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["hooks"]["SubagentStart"][0]["hooks"][0]["command"] == "existing-v4-hook"
assert len(data["hooks"]["UserPromptSubmit"]) == 1, data
assert data["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"] == "keep-user-hook"
PY

[[ -x "$install_home/skills/sol-control/scripts/lume_policy.py" ]] || fail "installer did not install helper"
[[ ! -e "$install_home/hooks/lume-sol-control/user_prompt_submit.py" ]] || fail "installer retained its legacy prompt hook"
[[ ! -e "$install_home/lume-sol-control-hook-proof.json" ]] || fail "installer retained its legacy proof"
[[ ! -e "$TMP_ROOT/legacy-signal.json" ]] || fail "installer retained its legacy signal"
rg -q 'Persistent modes are `openai` and `quota-save`' "$install_home/skills/sol-control/SKILL.md" \
  || fail "installer did not add the two-mode resolver contract"

doctor=$(CODEX_HOME="$install_home" /usr/bin/python3 "$install_home/skills/sol-control/scripts/lume_policy.py" doctor)
[[ $(printf '%s' "$doctor" | json_field available) == True ]] || fail "doctor must validate helper and skill"

printf 'PASS Lume Sol Control integration tests\n'

#!/bin/bash
set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SOURCE_ROOT=""
while (($#)); do
  case "$1" in
    --source-root)
      SOURCE_ROOT="$2"
      SOURCE_DIR="$SOURCE_ROOT/integrations/sol-control"
      shift 2
      ;;
    *)
      printf 'usage: install.sh [--source-root PATH]\n' >&2
      exit 2
      ;;
  esac
done

CODEX_ROOT=${CODEX_HOME:-$HOME/.codex}
SKILL_DIR="$CODEX_ROOT/skills/sol-control"
HOOK_DIR="$CODEX_ROOT/hooks/lume-sol-control"
HOOKS_JSON="$CODEX_ROOT/hooks.json"

[[ -f "$SKILL_DIR/SKILL.md" ]] || { printf 'Sol Control is not installed: %s\n' "$SKILL_DIR/SKILL.md" >&2; exit 1; }
for file in lume_policy.py user_prompt_submit.py sol-control-mode.md; do
  [[ -f "$SOURCE_DIR/$file" ]] || { printf 'Missing integration resource: %s\n' "$SOURCE_DIR/$file" >&2; exit 1; }
done

mkdir -p "$SKILL_DIR/scripts" "$HOOK_DIR"
install -m 0755 "$SOURCE_DIR/lume_policy.py" "$SKILL_DIR/scripts/lume_policy.py"
install -m 0755 "$SOURCE_DIR/user_prompt_submit.py" "$HOOK_DIR/user_prompt_submit.py"

/usr/bin/python3 - "$SKILL_DIR/SKILL.md" "$SOURCE_DIR/sol-control-mode.md" <<'PY'
import os
import pathlib
import tempfile
import sys

skill = pathlib.Path(sys.argv[1])
block = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").strip()
text = skill.read_text(encoding="utf-8")
start_marker = "<!-- LUME-SOL-CONTROL-BEGIN -->"
end_marker = "<!-- LUME-SOL-CONTROL-END -->"
if start_marker in text:
    start = text.index(start_marker)
    end = text.index(end_marker, start) + len(end_marker)
    updated = text[:start] + block + text[end:]
else:
    heading = "## Select the mode"
    next_heading = "In `openai` mode:"
    start = text.index(heading) + len(heading)
    end = text.index(next_heading, start)
    updated = text[:start] + "\n\n" + block + "\n\n" + text[end:]
descriptor, temporary = tempfile.mkstemp(prefix=f".{skill.name}.", dir=skill.parent)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    stream.write(updated)
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, skill)
PY

/usr/bin/python3 - "$HOOKS_JSON" "$HOOK_DIR/user_prompt_submit.py" <<'PY'
import json
import os
import pathlib
import tempfile
import sys

path = pathlib.Path(sys.argv[1])
hook = pathlib.Path(sys.argv[2])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except FileNotFoundError:
    data = {"description": "User-level Codex hooks", "hooks": {}}
if not isinstance(data, dict) or not isinstance(data.setdefault("hooks", {}), dict):
    raise SystemExit("hooks.json has an unsupported shape")
groups = data["hooks"].setdefault("UserPromptSubmit", [])
if not isinstance(groups, list):
    raise SystemExit("hooks.json UserPromptSubmit must be an array")
groups[:] = [group for group in groups if "lume-sol-control/user_prompt_submit.py" not in json.dumps(group)]
groups.append({
    "hooks": [{
        "type": "command",
        "command": f'/usr/bin/python3 "{hook}"',
        "timeout": 2,
        "statusMessage": "Resolving Lume quota routing",
        "additionalContextLimit": 1000,
    }]
})
path.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(data, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, path)
PY

printf 'PASS installed Lume Sol Control integration into %s\n' "$CODEX_ROOT"

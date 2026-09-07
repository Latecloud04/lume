#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
VERIFIER="$ROOT/packaging/verify-lume.sh"
BUILD_SCRIPT="$ROOT/scripts/build-lume.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lume-packaging-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_fail() {
  if "$@" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr"; then
    fail "expected command to fail: $*"
  fi
}

create_fixture() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as stream:
    plistlib.dump(
        {
            "CFBundleDisplayName": "Lume",
            "CFBundleExecutable": "Lume",
            "CFBundleIconFile": "Lume.icns",
            "CFBundleIdentifier": "local.lume.codex",
            "CFBundleName": "Lume",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.3.0",
            "CFBundleVersion": "1.3.0",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": True,
        },
        stream,
    )
PY
  printf '#!/bin/sh\nexit 0\n' >"$app/Contents/MacOS/Lume"
  printf 'fixture icns\n' >"$app/Contents/Resources/Lume.icns"
  chmod +x "$app/Contents/MacOS/Lume"
}

copy_valid() {
  local name="$1"
  cp -R "$TMP_ROOT/valid" "$TMP_ROOT/$name"
}

mutate_plist() {
  local app="$1"
  local key="$2"
  local value="$3"
  python3 - "$app/Contents/Info.plist" "$key" "$value" <<'PY'
import plistlib
import sys

path, key, value = sys.argv[1:]
with open(path, "rb") as stream:
    plist = plistlib.load(stream)
if value == "__DELETE__":
    plist.pop(key, None)
elif value == "true":
    plist[key] = True
elif value == "false":
    plist[key] = False
else:
    plist[key] = value
with open(path, "wb") as stream:
    plistlib.dump(plist, stream)
PY
}

mkdir -p "$TMP_ROOT/valid"
create_fixture "$TMP_ROOT/valid/Lume.app"

# Minimal fixture is intentionally unsigned/non-Mach-O; both allow flags make
# the verifier test deterministic on hosts without Apple's signing toolchain.
"$VERIFIER" --app "$TMP_ROOT/valid/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid missing-lsui
mutate_plist "$TMP_ROOT/missing-lsui/Lume.app" LSUIElement __DELETE__
assert_fail "$VERIFIER" --app "$TMP_ROOT/missing-lsui/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid false-lsui
mutate_plist "$TMP_ROOT/false-lsui/Lume.app" LSUIElement false
assert_fail "$VERIFIER" --app "$TMP_ROOT/false-lsui/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid ls-background-only
mutate_plist "$TMP_ROOT/ls-background-only/Lume.app" LSBackgroundOnly true
assert_fail "$VERIFIER" --app "$TMP_ROOT/ls-background-only/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid wrong-bundle-id
mutate_plist "$TMP_ROOT/wrong-bundle-id/Lume.app" CFBundleIdentifier local.lume.other
assert_fail "$VERIFIER" --app "$TMP_ROOT/wrong-bundle-id/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid wrong-name
mutate_plist "$TMP_ROOT/wrong-name/Lume.app" CFBundleName Other
assert_fail "$VERIFIER" --app "$TMP_ROOT/wrong-name/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid wrong-version
assert_fail "$VERIFIER" --app "$TMP_ROOT/wrong-version/Lume.app" --expected-version 9.9.9 \
  --allow-unsigned --allow-non-arm64

copy_valid wrong-minimum-os
mutate_plist "$TMP_ROOT/wrong-minimum-os/Lume.app" LSMinimumSystemVersion 13.0
assert_fail "$VERIFIER" --app "$TMP_ROOT/wrong-minimum-os/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid helper
mkdir -p "$TMP_ROOT/helper/Lume.app/Contents/Helpers"
printf 'forbidden\n' >"$TMP_ROOT/helper/Lume.app/Contents/Helpers/marker"
assert_fail "$VERIFIER" --app "$TMP_ROOT/helper/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid tessalume-resource
printf 'forbidden\n' >"$TMP_ROOT/tessalume-resource/Lume.app/Contents/Resources/Tessalume.marker"
assert_fail "$VERIFIER" --app "$TMP_ROOT/tessalume-resource/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid dotnet
printf 'managed\n' >"$TMP_ROOT/dotnet/Lume.app/Contents/Resources/runtime.dll"
assert_fail "$VERIFIER" --app "$TMP_ROOT/dotnet/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid windows
printf 'windows\n' >"$TMP_ROOT/windows/Lume.app/Contents/Resources/app.exe"
assert_fail "$VERIFIER" --app "$TMP_ROOT/windows/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid themes
mkdir -p "$TMP_ROOT/themes/Lume.app/Contents/Resources/themes"
printf 'themes\n' >"$TMP_ROOT/themes/Lume.app/Contents/Resources/themes/marker"
assert_fail "$VERIFIER" --app "$TMP_ROOT/themes/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid telemetry
printf 'telemetry\n' >"$TMP_ROOT/telemetry/Lume.app/Contents/Resources/telemetry.json"
assert_fail "$VERIFIER" --app "$TMP_ROOT/telemetry/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid update
printf 'updates\n' >"$TMP_ROOT/update/Lume.app/Contents/Resources/update.json"
assert_fail "$VERIFIER" --app "$TMP_ROOT/update/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid symlink
ln -s "$TMP_ROOT/symlink/Lume.app/Contents/Resources/Lume.icns" \
  "$TMP_ROOT/symlink/Lume.app/Contents/Resources/linked-icon"
assert_fail "$VERIFIER" --app "$TMP_ROOT/symlink/Lume.app" --allow-unsigned --allow-non-arm64

ln -s "$TMP_ROOT/valid/Lume.app" "$TMP_ROOT/app-link.app"
assert_fail "$VERIFIER" --app "$TMP_ROOT/app-link.app" --allow-unsigned --allow-non-arm64

copy_valid sidecar
printf 'sidecar\n' >"$TMP_ROOT/sidecar/Lume.app/Contents/MacOS/sidecar"
assert_fail "$VERIFIER" --app "$TMP_ROOT/sidecar/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid resource-sidecar
printf 'sidecar\n' >"$TMP_ROOT/resource-sidecar/Lume.app/Contents/Resources/sidecar"
assert_fail "$VERIFIER" --app "$TMP_ROOT/resource-sidecar/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid contents-sidecar
printf 'sidecar\n' >"$TMP_ROOT/contents-sidecar/Lume.app/Contents/PkgInfo"
assert_fail "$VERIFIER" --app "$TMP_ROOT/contents-sidecar/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid app-sidecar
printf 'sidecar\n' >"$TMP_ROOT/app-sidecar/Lume.app/README"
assert_fail "$VERIFIER" --app "$TMP_ROOT/app-sidecar/Lume.app" --allow-unsigned --allow-non-arm64

copy_valid extra-macho
python3 - "$TMP_ROOT/extra-macho/Lume.app/Contents/Resources/extra-macho" <<'PY'
import sys

with open(sys.argv[1], "wb") as stream:
    stream.write(bytes.fromhex("cffaedfe"))
    stream.write(b"\0" * 64)
PY
assert_fail "$VERIFIER" --app "$TMP_ROOT/extra-macho/Lume.app" --allow-unsigned --allow-non-arm64

assert_fail "$VERIFIER" --app "$TMP_ROOT/valid/Lume.app"
assert_fail "$VERIFIER" --app "$TMP_ROOT/valid/Lume.app" --allow-non-arm64
assert_fail "$VERIFIER" --app "$TMP_ROOT/valid/Lume.app" --allow-unsigned

for config_case in unknown-key missing-key; do
  mkdir -p "$TMP_ROOT/config-$config_case/packaging"
  cp "$VERIFIER" "$TMP_ROOT/config-$config_case/packaging/verify-lume.sh"
  cp "$ROOT/packaging/lume.json" "$TMP_ROOT/config-$config_case/packaging/lume.json"
  chmod +x "$TMP_ROOT/config-$config_case/packaging/verify-lume.sh"
done
python3 - "$TMP_ROOT/config-unknown-key/packaging/lume.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config["unexpected"] = True
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY
python3 - "$TMP_ROOT/config-missing-key/packaging/lume.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
del config["minimumMacOS"]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY
assert_fail "$TMP_ROOT/config-unknown-key/packaging/verify-lume.sh" \
  --app "$TMP_ROOT/valid/Lume.app" --allow-unsigned --allow-non-arm64
assert_fail "$TMP_ROOT/config-missing-key/packaging/verify-lume.sh" \
  --app "$TMP_ROOT/valid/Lume.app" --allow-unsigned --allow-non-arm64

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/dmg-valid-root"
  cp -R "$TMP_ROOT/valid/Lume.app" "$TMP_ROOT/dmg-valid-root/Lume.app"
  hdiutil create -volname Lume -srcfolder "$TMP_ROOT/dmg-valid-root" -ov -format UDZO \
    "$TMP_ROOT/valid-lume.dmg" >/dev/null
  "$VERIFIER" --app "$TMP_ROOT/valid/Lume.app" --dmg "$TMP_ROOT/valid-lume.dmg" \
    --allow-unsigned --allow-non-arm64

  mkdir -p "$TMP_ROOT/dmg-extra-root"
  cp -R "$TMP_ROOT/valid/Lume.app" "$TMP_ROOT/dmg-extra-root/Lume.app"
  printf 'unexpected payload\n' >"$TMP_ROOT/dmg-extra-root/notes.txt"
  hdiutil create -volname Lume -srcfolder "$TMP_ROOT/dmg-extra-root" -ov -format UDZO \
    "$TMP_ROOT/extra-root-lume.dmg" >/dev/null
  assert_fail "$VERIFIER" --app "$TMP_ROOT/valid/Lume.app" --dmg "$TMP_ROOT/extra-root-lume.dmg" \
    --allow-unsigned --allow-non-arm64
fi

rtk_bash=$(command -v bash)
"$rtk_bash" -n "$VERIFIER"
"$rtk_bash" -n "$BUILD_SCRIPT"
rg -q 'PACKAGE_ROOT="\$ROOT"|\.build/release/Lume|artifacts/lume|Lume\.app|Lume\.dmg' "$BUILD_SCRIPT" \
  || fail "build script does not prove frozen Lume paths"
rg -q 'LumeIcon\.swift|LumeIcon\.svg|iconutil|Lume\.icns' "$BUILD_SCRIPT" \
  || fail "build script does not prove deterministic icon generation"
rg -q 'STAGING=\$\(mktemp -d|COMMIT_STARTED=1|APP_STAGE|DMG_STAGE' "$BUILD_SCRIPT" \
  || fail "build script is missing stage-first atomic output checks"
if rg -qi 'Tessalume|Helpers|themes|\.dll|\.exe|dotnet' "$BUILD_SCRIPT"; then
  fail "build script must not copy legacy helpers, themes, or runtimes"
fi

assert_fail "$BUILD_SCRIPT" --test-mode --output "$ROOT"
rg -q 'output must be under' "$TMP_ROOT/stderr" \
  || fail "unsafe output rejection was masked by an earlier build-script error"

mkdir -p "$TMP_ROOT/existing"
printf 'keep me\n' >"$TMP_ROOT/existing/sentinel.txt"
assert_fail "$BUILD_SCRIPT" --test-mode --output "$TMP_ROOT/existing"
[[ -f "$TMP_ROOT/existing/sentinel.txt" ]] || fail "test mode removed a user file"

python3 - "$ROOT/packaging/lume.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)
expected = {
    "appVersion": "1.3.0",
    "bundleIdentifier": "local.lume.codex",
    "displayName": "Lume",
    "bundleName": "Lume",
    "executable": "Lume",
    "minimumMacOS": "14.0",
}
if config != expected:
    raise SystemExit(f"unexpected Lume config: {config!r}")
PY

printf 'PASS Lume packaging verifier acceptance tests\n'

#!/bin/bash
set -euo pipefail

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CONFIG_PATH="$SCRIPT_ROOT/packaging/lume.json"

usage() {
  cat >&2 <<'EOF'
usage: verify-lume.sh --app PATH [--dmg PATH] [--expected-version VERSION]
       [--allow-unsigned] [--allow-non-arm64]
EOF
  exit 2
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$CONFIG_PATH" ]] || die "Lume config is missing: $CONFIG_PATH"

CONFIG_VALUES=$(python3 - "$CONFIG_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)

required = {
    "appVersion": str,
    "bundleIdentifier": str,
    "displayName": str,
    "bundleName": str,
    "executable": str,
    "minimumMacOS": str,
}
if set(config) != set(required):
    unknown = sorted(set(config) - set(required))
    missing = sorted(set(required) - set(config))
    raise SystemExit(f"Lume config keys must be exactly canonical: unknown={unknown}, missing={missing}")
for key, expected_type in required.items():
    value = config.get(key)
    if not isinstance(value, expected_type) or not value:
        raise SystemExit(f"missing or invalid Lume config key: {key}")
print("\t".join(config[key] for key in required))
PY
)
IFS=$'\t' read -r CONFIG_VERSION CONFIG_BUNDLE_ID CONFIG_DISPLAY_NAME \
  CONFIG_BUNDLE_NAME CONFIG_EXECUTABLE CONFIG_MINIMUM_MACOS <<<"$CONFIG_VALUES"

APP_ARG=""
DMG_ARG=""
EXPECTED_VERSION="$CONFIG_VERSION"
ALLOW_UNSIGNED=0
ALLOW_NON_ARM64=0

while (($#)); do
  case "$1" in
    --app)
      (($# >= 2)) || usage
      APP_ARG="$2"
      shift 2
      ;;
    --dmg)
      (($# >= 2)) || usage
      DMG_ARG="$2"
      shift 2
      ;;
    --expected-version)
      (($# >= 2)) || usage
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --allow-unsigned)
      ALLOW_UNSIGNED=1
      shift
      ;;
    --allow-non-arm64)
      ALLOW_NON_ARM64=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$APP_ARG" ]] || usage

is_macho() {
  local path="$1"
  local description
  local magic
  magic=$(od -An -tx1 -N4 "$path" 2>/dev/null | tr -d '[:space:]' || true)
  case "$magic" in
    cffaedfe|feedfacf|cefaedfe|feedface|cafebabe|bebafeca)
      return 0
      ;;
  esac
  description=$(file -b "$path" 2>/dev/null || true)
  [[ "$description" == *"Mach-O"* ]]
}

verify_app() {
  local app_arg="$1"
  local expected_version="$2"
  local app
  local content
  local info
  local main
  local resources
  local icon

  [[ -e "$app_arg" ]] || die "app directory does not exist: $app_arg"
  [[ ! -L "$app_arg" ]] || die "app path must not be a symlink: $app_arg"
  [[ -d "$app_arg" ]] || die "app path is not a directory: $app_arg"
  app=$(cd "$app_arg" && pwd -P)
  [[ "$(basename "$app")" == "Lume.app" ]] || die "app basename must be Lume.app"

  if symlink=$(find "$app" -type l -print -quit); then
    [[ -z "$symlink" ]] || die "symlink is not allowed in app: $symlink"
  fi

  content="$app/Contents"
  info="$content/Info.plist"
  main="$content/MacOS/Lume"
  resources="$content/Resources"
  icon="$resources/Lume.icns"
  [[ -d "$content" ]] || die "app Contents directory is missing"
  [[ -f "$info" ]] || die "Info.plist is missing: $info"
  [[ -d "$resources" ]] || die "app Resources directory is missing"
  [[ -f "$main" ]] || die "Lume executable is missing: $main"
  [[ -f "$icon" ]] || die "Lume.icns is missing: $icon"

  while IFS= read -r -d '' path; do
    [[ "$(basename "$path")" == "Contents" ]] \
      || die "unexpected app bundle sidecar: ${path#"$app"/}"
  done < <(find "$app" -mindepth 1 -maxdepth 1 -print0)

  [[ ! -e "$content/Helpers" ]] || die "Helpers are forbidden in Lume.app"

  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in
      Info.plist|MacOS|Resources|_CodeSignature)
        ;;
      *)
        die "unexpected Contents sidecar: ${path#"$app"/}"
        ;;
    esac
  done < <(find "$content" -mindepth 1 -maxdepth 1 -print0)

  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in
      Lume.icns|SolControlIntegration)
        ;;
      *)
        die "unexpected Resources sidecar: ${path#"$app"/}"
        ;;
    esac
  done < <(find "$resources" -mindepth 1 -maxdepth 1 -print0)

  [[ -d "$resources/SolControlIntegration" ]] || die "Sol Control integration resources are missing"
  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in
      lume_policy.py|sol-control-mode.md|install.sh)
        ;;
      *)
        die "unexpected Sol Control integration sidecar: ${path#"$app"/}"
        ;;
    esac
  done < <(find "$resources/SolControlIntegration" -mindepth 1 -maxdepth 1 -print0)
  for integration_file in lume_policy.py sol-control-mode.md install.sh; do
    [[ -f "$resources/SolControlIntegration/$integration_file" ]] \
      || die "missing Sol Control integration resource: $integration_file"
  done

  if [[ -e "$content/_CodeSignature" ]]; then
    [[ -d "$content/_CodeSignature" ]] || die "_CodeSignature must be a directory"
    while IFS= read -r -d '' path; do
      [[ "$(basename "$path")" == "CodeResources" ]] \
        || die "unexpected code signature sidecar: ${path#"$app"/}"
    done < <(find "$content/_CodeSignature" -mindepth 1 -maxdepth 1 -print0)
  fi

  while IFS= read -r -d '' path; do
    [[ "$path" == "$main" ]] || die "unexpected MacOS sidecar: ${path#"$app"/}"
  done < <(find "$content/MacOS" -mindepth 1 -maxdepth 1 -print0)

  python3 - "$app" "$content" <<'PY'
import pathlib
import re
import sys

app = pathlib.Path(sys.argv[1])
content = pathlib.Path(sys.argv[2])
name_pattern = re.compile(
    r"(?i)(?:tessalume|dotnet|windows|powershell|(?:^|/)(?:helpers?|themes?)(?:/|$)|"
    r"(?:^|/)(?:telemetry|updates?|updater|sparkle|appcast)(?:[./_-]|$)|"
    r"\.(?:dll|exe|pdb|deps\.json|runtimeconfig\.json|ps1|bat|cmd)$)"
)
content_pattern = re.compile(
    r"(?i)(?:tessalume|system\.windows|microsoft\.win32|powershell(?:\.exe)?|"
    r"net[0-9.]*-windows|usewpf|dotnet|telemetry|sparkle|appcast|updater)"
)

for path in app.rglob("*"):
    relative = path.relative_to(app).as_posix()
    if name_pattern.search(relative):
        raise SystemExit(f"FAIL: forbidden Lume artifact/path: {relative}")
    if not path.is_file() or path.is_symlink():
        continue
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b"\0" in data[:4096]:
        continue
    text = data.decode("utf-8", errors="ignore")
    if content_pattern.search(text):
        raise SystemExit(f"FAIL: forbidden runtime marker in app: {relative}")

PY

  python3 - "$info" "$CONFIG_BUNDLE_ID" "$CONFIG_DISPLAY_NAME" "$CONFIG_BUNDLE_NAME" \
    "$CONFIG_EXECUTABLE" "$CONFIG_MINIMUM_MACOS" "$expected_version" <<'PY'
import plistlib
import sys

path, bundle_id, display_name, bundle_name, executable, minimum_os, expected_version = sys.argv[1:]
with open(path, "rb") as stream:
    plist = plistlib.load(stream)

expected = {
    "CFBundleDisplayName": display_name,
    "CFBundleExecutable": executable,
    "CFBundleIconFile": "Lume.icns",
    "CFBundleIdentifier": bundle_id,
    "CFBundleName": bundle_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": expected_version,
    "CFBundleVersion": expected_version,
    "LSMinimumSystemVersion": minimum_os,
}
for key, value in expected.items():
    if plist.get(key) != value:
        raise SystemExit(f"FAIL: Info.plist {key}={plist.get(key)!r}, expected {value!r}")
if plist.get("LSUIElement") is not True:
    raise SystemExit(f"FAIL: Info.plist LSUIElement={plist.get('LSUIElement')!r}, expected True")
if "LSBackgroundOnly" in plist:
    raise SystemExit("FAIL: Info.plist must not declare LSBackgroundOnly")
PY

  local macho_count=0
  local main_is_macho=0
  local path
  while IFS= read -r -d '' path; do
    if is_macho "$path"; then
      macho_count=$((macho_count + 1))
      if [[ "$path" != "$main" ]]; then
        die "unexpected extra Mach-O: ${path#"$app"/}"
      fi
      main_is_macho=1
    fi
  done < <(find "$app" -type f -print0)

  if ((ALLOW_NON_ARM64 == 0)); then
    ((main_is_macho == 1)) || die "Lume executable is not a Mach-O arm64 binary: $main"
    local main_description
    main_description=$(file -b "$main" 2>/dev/null || true)
    [[ "$main_description" == *"arm64"* ]] \
      || die "Lume executable is not arm64: $main_description"
  fi

  if ((ALLOW_UNSIGNED == 0)); then
    command -v codesign >/dev/null 2>&1 || die "codesign is required unless --allow-unsigned is set"
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
      || die "codesign verification failed for $app"
    if ((macho_count > 0)); then
      while IFS= read -r -d '' path; do
        if is_macho "$path"; then
          codesign --verify "$path" >/dev/null 2>&1 \
            || die "Mach-O is not individually signed: $path"
        fi
      done < <(find "$app" -type f -print0)
    fi
  fi

  printf 'PASS Lume app verification: %s\n' "$app"
}

verify_dmg_root() {
  local mount_point="$1"
  local path
  local name
  while IFS= read -r -d '' path; do
    name=$(basename "$path")
    case "$name" in
      Lume.app|.DS_Store|.fseventsd|.Spotlight-V100|.Trashes|.TemporaryItems|.DocumentRevisions-V100|.VolumeIcon.icns|.vol|".HFS+ Private Directory Data")
        ;;
      *)
        die "DMG contains unexpected root payload: $name"
        ;;
    esac
  done < <(find "$mount_point" -mindepth 1 -maxdepth 1 -print0)
}

verify_app "$APP_ARG" "$EXPECTED_VERSION"

if [[ -n "$DMG_ARG" ]]; then
  [[ -e "$DMG_ARG" ]] || die "DMG does not exist: $DMG_ARG"
  [[ ! -L "$DMG_ARG" ]] || die "DMG path must not be a symlink: $DMG_ARG"
  [[ -s "$DMG_ARG" ]] || die "DMG is missing or empty: $DMG_ARG"
  command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required to verify a DMG"
  hdiutil imageinfo "$DMG_ARG" >/dev/null 2>&1 || die "invalid DMG: $DMG_ARG"

  ATTACH_PLIST=$(mktemp "${TMPDIR:-/tmp}/lume-attach.XXXXXX")
  MOUNT_POINT=""
  MOUNTED=0
  cleanup_mount() {
    if ((MOUNTED)); then
      hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -f "$ATTACH_PLIST"
  }
  trap cleanup_mount EXIT
  hdiutil attach -readonly -nobrowse -noautoopen -plist "$DMG_ARG" >"$ATTACH_PLIST" \
    || die "unable to mount DMG: $DMG_ARG"
  MOUNT_POINT=$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
for entity in info.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
PY
  )
  [[ -n "$MOUNT_POINT" ]] || die "DMG did not provide a mount point"
  MOUNTED=1
  verify_dmg_root "$MOUNT_POINT"
  MOUNTED_APP="$MOUNT_POINT/Lume.app"
  [[ -d "$MOUNTED_APP" ]] || die "DMG does not contain Lume.app"
  verify_app "$MOUNTED_APP" "$EXPECTED_VERSION"
  hdiutil detach "$MOUNT_POINT" >/dev/null || die "unable to detach DMG mount"
  MOUNTED=0
  rm -f "$ATTACH_PLIST"
  trap - EXIT
  printf 'PASS Lume DMG verification: %s\n' "$DMG_ARG"
fi

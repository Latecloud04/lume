#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CONFIG_PATH="$ROOT/packaging/lume.json"
PACKAGE_ROOT="$ROOT"
PACKAGE_MANIFEST="$PACKAGE_ROOT/Package.swift"
SWIFT_RELEASE_OUTPUT="$PACKAGE_ROOT/.build/release/Lume"
ICON_SOURCE="$ROOT/packaging/lume-assets/LumeIcon.swift"
ICON_SVG_SOURCE="$ROOT/packaging/lume-assets/LumeIcon.svg"
OUTPUT_ARG="$ROOT/artifacts/lume"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="${LUME_VERSION:-}"
TEST_MODE=0

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: build-lume.sh [--output PATH] [--identity CODESIGN_IDENTITY]
       [--version VERSION] [--test-mode]
EOF
  exit 2
}

while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || usage
      OUTPUT_ARG="$2"
      shift 2
      ;;
    --identity)
      (($# >= 2)) || usage
      IDENTITY="$2"
      shift 2
      ;;
    --version)
      (($# >= 2)) || usage
      VERSION="$2"
      shift 2
      ;;
    --test-mode)
      TEST_MODE=1
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

if [[ "$OUTPUT_ARG" = /* ]]; then
  OUTPUT_DIR="$OUTPUT_ARG"
else
  OUTPUT_DIR="$ROOT/$OUTPUT_ARG"
fi
OUTPUT_DIR=$(python3 - "$OUTPUT_DIR" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]).rstrip(os.sep) or os.sep)
PY
)

TMP_ROOT=${TMPDIR:-/tmp}
TMP_ROOT=${TMP_ROOT%/}
DEFAULT_OUTPUT="$ROOT/artifacts/lume"

python3 - "$OUTPUT_DIR" "$ROOT" "$DEFAULT_OUTPUT" "$TMP_ROOT" <<'PY'
import os
import pathlib
import sys

output, root, default_output, tmp_root = map(pathlib.Path, sys.argv[1:])
output = pathlib.Path(os.path.abspath(output))
root = pathlib.Path(os.path.abspath(root))
default_output = pathlib.Path(os.path.abspath(default_output))
tmp_root = pathlib.Path(os.path.abspath(tmp_root))

if output in {root, pathlib.Path(output.anchor), tmp_root, pathlib.Path("/tmp")}:
    raise SystemExit(f"output must be under {default_output} or a temporary directory: {output}")

allowed = False
for base in (default_output, tmp_root, pathlib.Path("/tmp")):
    try:
        output.relative_to(base)
        allowed = True
        break
    except ValueError:
        continue
if not allowed:
    raise SystemExit(f"output must be under {default_output} or a temporary directory: {output}")

current = output
while True:
    if current.exists() and current.is_symlink():
        raise SystemExit(f"output path must not be a symlink: {current}")
    if current == current.parent:
        break
    current = current.parent
PY

[[ "$OUTPUT_DIR" != "$ROOT" && "$OUTPUT_DIR" != "/" && "$OUTPUT_DIR" != "$TMP_ROOT" && "$OUTPUT_DIR" != "/tmp" ]] \
  || die "refusing broad output path: $OUTPUT_DIR"
[[ ! -L "$OUTPUT_DIR" ]] || die "output path must not be a symlink: $OUTPUT_DIR"

if [[ -e "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" ]] || die "output path is not a directory: $OUTPUT_DIR"
  OUTPUT_MARKER="$OUTPUT_DIR/.lume-output-owner"
  if [[ "$OUTPUT_DIR" != "$DEFAULT_OUTPUT" && ! -f "$OUTPUT_MARKER" ]]; then
    die "refusing existing temporary output without ownership marker: $OUTPUT_DIR"
  fi
else
  mkdir -p "$OUTPUT_DIR"
fi

OUTPUT_MARKER="$OUTPUT_DIR/.lume-output-owner"
[[ ! -L "$OUTPUT_MARKER" ]] || die "output marker must not be a symlink: $OUTPUT_MARKER"
if [[ ! -f "$OUTPUT_MARKER" ]]; then
  printf 'Lume output owner\n' >"$OUTPUT_MARKER"
fi

APP_OUT="$OUTPUT_DIR/Lume.app"
DMG_OUT="$OUTPUT_DIR/Lume.dmg"
[[ ! -L "$APP_OUT" ]] || die "refusing to replace symlink: $APP_OUT"
[[ ! -L "$DMG_OUT" ]] || die "refusing to replace symlink: $DMG_OUT"

# This mode exercises output ownership and path safety without requiring the
# product source to be present while packaging work is developed in parallel.
if ((TEST_MODE)); then
  printf 'PASS Lume build preflight (--test-mode): %s\n' "$OUTPUT_DIR"
  exit 0
fi

[[ -f "$CONFIG_PATH" ]] || die "Lume config is missing: $CONFIG_PATH"
[[ -f "$PACKAGE_MANIFEST" ]] || die "Lume Swift package is missing: $PACKAGE_MANIFEST"
[[ -f "$ICON_SOURCE" ]] || die "Lume icon drawing source is missing: $ICON_SOURCE"
[[ -f "$ICON_SVG_SOURCE" ]] || die "Lume icon SVG source is missing: $ICON_SVG_SOURCE"

CONFIG_VALUES=$(python3 - "$CONFIG_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)
required = (
    "appVersion",
    "bundleIdentifier",
    "displayName",
    "bundleName",
    "executable",
    "minimumMacOS",
)
if set(config) != set(required):
    unknown = sorted(set(config) - set(required))
    missing = sorted(set(required) - set(config))
    raise SystemExit(f"Lume config keys must be exactly canonical: unknown={unknown}, missing={missing}")
for key in required:
    value = config.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"missing or invalid Lume config key: {key}")
print("\t".join(config[key] for key in required))
PY
)
IFS=$'\t' read -r SOURCE_VERSION BUNDLE_IDENTIFIER DISPLAY_NAME BUNDLE_NAME EXECUTABLE MINIMUM_MACOS \
  <<<"$CONFIG_VALUES"
VERSION="${VERSION:-$SOURCE_VERSION}"
[[ "$VERSION" == "$SOURCE_VERSION" ]] \
  || die "requested version $VERSION does not match $CONFIG_PATH appVersion $SOURCE_VERSION"
[[ "$BUNDLE_IDENTIFIER" == "local.lume.codex" ]] \
  || die "Lume bundle identifier must remain local.lume.codex"
[[ "$DISPLAY_NAME" == "Lume" && "$BUNDLE_NAME" == "Lume" && "$EXECUTABLE" == "Lume" ]] \
  || die "Lume display/name/executable must remain Lume"
[[ "$MINIMUM_MACOS" == "14.0" ]] || die "Lume minimum macOS must remain 14.0"

SWIFT_BIN=$(command -v swift || true)
[[ -n "$SWIFT_BIN" ]] || die "swift executable is not on PATH"
ICONUTIL_BIN=$(command -v iconutil || true)
[[ -n "$ICONUTIL_BIN" ]] || die "iconutil executable is not on PATH"
HDITUIL_BIN=$(command -v hdiutil || true)
[[ -n "$HDITUIL_BIN" ]] || die "hdiutil executable is not on PATH"
CODESIGN_BIN=$(command -v codesign || true)
[[ -n "$CODESIGN_BIN" ]] || die "codesign executable is not on PATH"

(
  cd "$PACKAGE_ROOT"
  "$SWIFT_BIN" build -c release
)

SWIFT_APP="$SWIFT_RELEASE_OUTPUT"
if [[ ! -x "$SWIFT_APP" ]]; then
  SWIFT_APP=$(find "$PACKAGE_ROOT/.build" -type f -path '*/release/Lume' -perm -111 -print -quit 2>/dev/null || true)
fi
[[ -n "$SWIFT_APP" && -x "$SWIFT_APP" ]] || die "Swift release executable is missing under $PACKAGE_ROOT/.build"
[[ ! -L "$SWIFT_APP" ]] || die "Swift release executable must not be a symlink: $SWIFT_APP"

STAGING=$(mktemp -d "$OUTPUT_DIR/.staging.XXXXXX")
COMMITTED=0
COMMIT_STARTED=0
cleanup() {
  if ((COMMITTED == 0 && COMMIT_STARTED == 1)); then
    if [[ -e "$APP_OUT" ]]; then
      mv "$APP_OUT" "$STAGING/failed-Lume.app" || true
    fi
    if [[ -e "$DMG_OUT" ]]; then
      mv "$DMG_OUT" "$STAGING/failed-Lume.dmg" || true
    fi
    if [[ -e "$STAGING/previous/Lume.app" ]]; then
      mv "$STAGING/previous/Lume.app" "$APP_OUT" || true
    fi
    if [[ -e "$STAGING/previous/Lume.dmg" ]]; then
      mv "$STAGING/previous/Lume.dmg" "$DMG_OUT" || true
    fi
  fi
  if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

APP_STAGE="$STAGING/Lume.app"
CONTENT_STAGE="$APP_STAGE/Contents"
MAIN_STAGE="$CONTENT_STAGE/MacOS/Lume"
RESOURCES_STAGE="$CONTENT_STAGE/Resources"
mkdir -p "$CONTENT_STAGE/MacOS" "$RESOURCES_STAGE"
cp "$SWIFT_APP" "$MAIN_STAGE"
chmod +x "$MAIN_STAGE"

ICONSET_STAGE="$STAGING/Lume.iconset"
mkdir -p "$ICONSET_STAGE"
"$SWIFT_BIN" "$ICON_SOURCE" "$ICONSET_STAGE"
"$ICONUTIL_BIN" -c icns "$ICONSET_STAGE" -o "$RESOURCES_STAGE/Lume.icns"
[[ -s "$RESOURCES_STAGE/Lume.icns" ]] || die "generated Lume.icns is missing or empty"

python3 - "$CONTENT_STAGE/Info.plist" "$VERSION" "$BUNDLE_IDENTIFIER" "$DISPLAY_NAME" \
  "$BUNDLE_NAME" "$EXECUTABLE" "$MINIMUM_MACOS" <<'PY'
import plistlib
import sys

path, version, bundle_id, display_name, bundle_name, executable, minimum_os = sys.argv[1:]
with open(path, "wb") as stream:
    plistlib.dump(
        {
            "CFBundleDisplayName": display_name,
            "CFBundleExecutable": executable,
            "CFBundleIconFile": "Lume.icns",
            "CFBundleIdentifier": bundle_id,
            "CFBundleName": bundle_name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": minimum_os,
            "LSUIElement": True,
        },
        stream,
    )
PY

"$CODESIGN_BIN" --force --sign "$IDENTITY" --timestamp=none "$MAIN_STAGE"
"$CODESIGN_BIN" --force --deep --sign "$IDENTITY" --timestamp=none "$APP_STAGE"
"$CODESIGN_BIN" --verify --deep --strict "$APP_STAGE"

DMG_ROOT="$STAGING/dmgroot"
DMG_STAGE="$STAGING/Lume.dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP_STAGE" "$DMG_ROOT/Lume.app"
"$HDITUIL_BIN" create -volname "Lume" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_STAGE"

"$ROOT/packaging/verify-lume.sh" --app "$APP_STAGE" --dmg "$DMG_STAGE" \
  --expected-version "$VERSION"

mkdir -p "$STAGING/previous"
COMMIT_STARTED=1
if [[ -e "$APP_OUT" ]]; then
  mv "$APP_OUT" "$STAGING/previous/Lume.app"
fi
if [[ -e "$DMG_OUT" ]]; then
  mv "$DMG_OUT" "$STAGING/previous/Lume.dmg"
fi
mv "$APP_STAGE" "$APP_OUT"
mv "$DMG_STAGE" "$DMG_OUT"

"$ROOT/packaging/verify-lume.sh" --app "$APP_OUT" --dmg "$DMG_OUT" \
  --expected-version "$VERSION"
COMMITTED=1
printf 'Lume app: %s\nLume DMG: %s\n' "$APP_OUT" "$DMG_OUT"

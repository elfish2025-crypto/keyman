#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DIST_DIR="$PROJECT_ROOT/dist"
# Build first: `--show-bin-path` does not trigger a build on its own.
(cd "$PROJECT_ROOT" && swift build -c release --product Keyman)
BIN_DIR="$(cd "$PROJECT_ROOT" && swift build -c release --product Keyman --show-bin-path)"

mkdir -p "$DIST_DIR"
# Hidden staging prevents development builds from becoming extra Spotlight apps.
STAGING_DIR="$(mktemp -d "$DIST_DIR/.package.noindex.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Keyman.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Keyman" "$APP_DIR/Contents/MacOS/Keyman"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/Keyman"
codesign --force --sign - --identifier com.local.keyman "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_DIR/Keyman.app.zip"
python3 - "$PROJECT_ROOT/scripts" "$STAGING_DIR/Keyman.app.zip" "$APP_DIR" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from app_installation import manifest, verify_archive
verify_archive(pathlib.Path(sys.argv[2]), manifest(pathlib.Path(sys.argv[3])))
PY
mv "$STAGING_DIR/Keyman.app.zip" "$DIST_DIR/Keyman.app.zip"
print "$DIST_DIR/Keyman.app.zip"

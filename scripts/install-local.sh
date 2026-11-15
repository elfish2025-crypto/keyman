#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_ARCHIVE="$PROJECT_ROOT/dist/Keyman.app.zip"

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  print -u2 "Run scripts/package-app.sh first"
  exit 2
fi

exec python3 "$PROJECT_ROOT/scripts/app_installation.py" install --source "$SOURCE_ARCHIVE"

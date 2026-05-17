#!/usr/bin/env bash
# Packages mod/factorio-telemetry into dist/factorio-telemetry_<version>.zip
# with the internal folder Factorio requires (<name>_<version>/...).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/mod/factorio-telemetry"
DIST="$ROOT/dist"

NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/info.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/info.json" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
FOLDER="${NAME}_${VERSION}"
ZIP="$DIST/${FOLDER}.zip"

rm -rf "$DIST/$FOLDER" "$ZIP"
mkdir -p "$DIST/$FOLDER"
cp "$SRC"/*.json "$SRC"/*.lua "$DIST/$FOLDER/"

( cd "$DIST" && zip -qr "${FOLDER}.zip" "$FOLDER" )
rm -rf "$DIST/$FOLDER"

echo "$ZIP"

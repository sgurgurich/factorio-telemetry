#!/usr/bin/env bash
# Uploads a new release of factorio-telemetry to mods.factorio.com.
#
# ONLY works once the mod page already exists on the portal (the first publish
# must be done manually on the website — there is no API to create a new mod).
#
# Requires a Factorio Mod Portal API key with the "ModPortal: Upload Mods"
# usage, created at https://factorio.com/profile :
#   export FACTORIO_API_KEY=...
#
# Usage:  ./deploy/publish-mod.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FACTORIO_API_KEY:?set FACTORIO_API_KEY (Mod Portal API key, 'Upload Mods' usage)}"

NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/mod/factorio-telemetry/info.json" | sed 's/.*"\([^"]*\)"$/\1/')
VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/mod/factorio-telemetry/info.json" | sed 's/.*"\([^"]*\)"$/\1/')
ZIP="$ROOT/dist/${NAME}_${VERSION}.zip"

[ -f "$ZIP" ] || bash "$ROOT/build/build-mod.sh" >/dev/null
[ -f "$ZIP" ] || { echo "missing $ZIP"; exit 1; }
echo ">> publishing $NAME $VERSION ($ZIP)"

UPLOAD_URL=$(curl -sf -H "Authorization: Bearer $FACTORIO_API_KEY" \
  -F "mod=$NAME" \
  https://mods.factorio.com/api/v2/mods/releases/init_upload \
  | sed -n 's/.*"upload_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

[ -n "$UPLOAD_URL" ] || { echo "init_upload failed (bad key, or mod page not created yet?)"; exit 1; }

curl -sf -F "file=@${ZIP};type=application/zip" "$UPLOAD_URL" \
  && echo ">> released $NAME $VERSION" \
  || { echo "upload failed"; exit 1; }

#!/usr/bin/env bash
# Full factorio-telemetry mod release flow. Run ON the Mac Mini from the repo
# root (~/factorio-telemetry). One artifact is built and used for BOTH the
# server PVC and the portal upload, so multiplayer checksums always match.
#
#   build zip -> stage onto server PVC -> restart server -> verify
#             -> publish that same zip to mods.factorio.com
#
# Idempotent: re-running the same version re-stages and treats an
# already-published portal release as a no-op.
set -euo pipefail
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"

NS=factorio
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VER=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' mod/factorio-telemetry/info.json | sed 's/.*"\([^"]*\)"$/\1/')
ZIP="dist/factorio-telemetry_${VER}.zip"
echo ">> releasing factorio-telemetry $VER"

bash build/build-mod.sh >/dev/null
[ -f "$ZIP" ] || { echo "build failed: $ZIP missing"; exit 1; }

echo ">> configmaps"
kubectl -n $NS create configmap ftel-mod   --from-file="factorio-telemetry_${VER}.zip=$ZIP"        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create configmap ftel-stage --from-file=stage_mods.py=deploy/stage_mods.py          --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create configmap ftel-rcon  --from-file=rcon_cmd.py=debug/rcon_cmd.py               --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS create configmap ftel-pub   --from-file=publish_mod.py=deploy/publish_mod.py        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

run_pod() { # name overrides-json -> waits, echoes phase, prints logs
  local name="$1" ov="$2"
  kubectl -n $NS delete pod "$name" --ignore-not-found >/dev/null 2>&1
  kubectl -n $NS run "$name" --restart=Never --image="$3" --overrides="$ov" >/dev/null 2>&1
  local ph=""
  for _ in $(seq 1 45); do
    ph=$(kubectl -n $NS get pod "$name" -o jsonpath="{.status.phase}" 2>/dev/null || true)
    { [ "$ph" = "Succeeded" ] || [ "$ph" = "Failed" ]; } && break
    sleep 2
  done
  echo "$ph"
}

OVR=$(mktemp)

# Publish to the portal FIRST. On a version bump, connected clients can only
# rejoin once the new version exists on the portal — so the portal must be
# updated before the server flips. If this fails we abort before touching the
# running server (players keep playing on the old version).
echo ">> publish $VER to mods.factorio.com"
cat >"$OVR" <<JSON
{"spec":{"containers":[{"name":"p","image":"python:3.12-alpine","command":["python","/s/publish_mod.py"],"env":[{"name":"APIKEY","valueFrom":{"secretKeyRef":{"name":"factorio-telemetry-publish","key":"apiKey"}}}],"volumeMounts":[{"name":"s","mountPath":"/s"},{"name":"m","mountPath":"/mod"}]}],"volumes":[{"name":"s","configMap":{"name":"ftel-pub"}},{"name":"m","configMap":{"name":"ftel-mod"}}]}}
JSON
PB=$(run_pod ftel-pub "$(cat "$OVR")" python:3.12-alpine)
kubectl -n $NS logs ftel-pub 2>&1 | tail -2
[ "$PB" = "Succeeded" ] || { echo "PUBLISH FAILED (server untouched; safe to retry)"; exit 1; }

echo ">> RCON /server-save (best-effort; SIGTERM save is the backstop)"
cat >"$OVR" <<JSON
{"spec":{"containers":[{"name":"p","image":"python:3.12-alpine","command":["python","/s/rcon_cmd.py"],"env":[{"name":"rconpw","valueFrom":{"secretKeyRef":{"name":"factorio-default-config","key":"rconpw"}}},{"name":"CMD","value":"/server-save"}],"volumeMounts":[{"name":"s","mountPath":"/s"}]}],"volumes":[{"name":"s","configMap":{"name":"ftel-rcon"}}]}}
JSON
run_pod ftel-rcon "$(cat "$OVR")" python:3.12-alpine >/dev/null || true
kubectl -n $NS logs ftel-rcon 2>/dev/null | tail -1 || true

echo ">> stage onto server PVC"
cat >"$OVR" <<JSON
{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"p","image":"python:3.12-alpine","command":["python","/s/stage_mods.py"],"env":[{"name":"PORTAL_USERNAME","valueFrom":{"secretKeyRef":{"name":"factorio-default-config","key":"portalUsername"}}},{"name":"PORTAL_TOKEN","valueFrom":{"secretKeyRef":{"name":"factorio-default-config","key":"portalToken"}}}],"volumeMounts":[{"name":"s","mountPath":"/s"},{"name":"modsrc","mountPath":"/modsrc"},{"name":"data","mountPath":"/factorio"}]}],"volumes":[{"name":"s","configMap":{"name":"ftel-stage"}},{"name":"modsrc","configMap":{"name":"ftel-mod"}},{"name":"data","persistentVolumeClaim":{"claimName":"factorio-default-data"}}]}}
JSON
ST=$(run_pod ftel-stage "$(cat "$OVR")" python:3.12-alpine)
kubectl -n $NS logs ftel-stage 2>&1 | tail -3
[ "$ST" = "Succeeded" ] || { echo "STAGING FAILED"; exit 1; }

echo ">> restart server + verify mod load"
kubectl -n $NS rollout restart statefulset/factorio-default >/dev/null
kubectl -n $NS rollout status statefulset/factorio-default --timeout=300s 2>&1 | tail -1
kubectl -n $NS exec factorio-default-0 -- sh -c \
  'grep -nE "script __factorio-telemetry__|Error .*telemetry|Warning.*depend" /factorio/factorio-current.log | tail -3' 2>&1 | grep -v Defaulted || true

echo ">> cleanup (secret factorio-telemetry-publish kept)"
kubectl -n $NS delete pod ftel-rcon ftel-stage ftel-pub --ignore-not-found >/dev/null 2>&1 || true
kubectl -n $NS delete configmap ftel-mod ftel-stage ftel-rcon ftel-pub --ignore-not-found >/dev/null 2>&1 || true
rm -f "$OVR"
echo ">> DONE: factorio-telemetry $VER staged to server AND published to portal"

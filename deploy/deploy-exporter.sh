#!/usr/bin/env bash
# Runs ON the Mac Mini, from the repo root. Builds the exporter image, imports
# it into the k3d 'homelab' cluster, applies manifests, and (re)creates the
# Grafana dashboard ConfigMap. No GHCR/CI required.
set -euo pipefail

export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin"
IMAGE="factorio-telemetry-exporter:0.1.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo ">> docker build $IMAGE"
docker build -t "$IMAGE" ./exporter

echo ">> k3d image import"
k3d image import "$IMAGE" -c homelab

echo ">> apply manifests"
kubectl apply -f deploy/exporter.yaml

echo ">> dashboard configmap"
kubectl -n factorio create configmap factorio-telemetry-dashboard \
  --from-file=factorio-telemetry.json=deploy/dashboards/factorio-telemetry.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n factorio label configmap factorio-telemetry-dashboard \
  grafana_dashboard=1 --overwrite

echo ">> wait for rollout"
kubectl -n factorio rollout status deploy/factorio-telemetry-exporter --timeout=120s

echo ">> done. exporter endpoints:"
kubectl -n factorio get pods -l app=factorio-telemetry-exporter

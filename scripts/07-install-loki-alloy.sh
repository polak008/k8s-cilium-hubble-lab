#!/bin/bash
# ============================================================================
# 07-install-loki-alloy.sh
#
# PURPOSE
#   Installs the logging pipeline: Loki (log storage/query backend) +
#   Grafana Alloy (log collection agent, runs as a DaemonSet on every node).
#
# RUN THIS ON
#   The control-plane node (or anywhere with kubectl access).
#
# ARCHITECTURE
#   Every node runs an Alloy pod (DaemonSet) that:
#     1. Discovers all pods on the cluster via the Kubernetes API
#        (discovery.kubernetes)
#     2. Attaches namespace/pod/container/node/app labels to each log
#        stream (discovery.relabel)
#     3. Tails each pod's logs via the Kubernetes API, not the filesystem
#        (loki.source.kubernetes)
#     4. Ships labeled log lines to Loki (loki.write)
#
#   Loki itself runs as a single all-in-one pod (StatefulSet) using local
#   filesystem storage — fine for a lab cluster; for production use object
#   storage (S3/GCS/MinIO) instead and switch off `target: all-in-one`.
#
# WHY THIS SPECIFIC ALLOY CONFIG
#   The project went through ~10 iterations trying different combinations
#   of loki.process / loki.relabel / loki.source.file / loki.source.podlogs.
#   The combination in values/alloy-values.yaml (discovery.kubernetes ->
#   discovery.relabel -> loki.source.kubernetes -> loki.write) is the one
#   that actually delivers logs end-to-end. loki.source.file requires
#   direct access to container log files on the node's filesystem, which
#   adds unnecessary complexity when loki.source.kubernetes can tail pod
#   logs via the API directly.
#
# WHY THIS SPECIFIC LOKI CONFIG
#   The chart's default "scalable" target expects object storage and
#   separate read/write/backend components. For a single-node lab,
#   `target: all-in-one` with `storage.type: filesystem` is far simpler
#   and is what actually came up healthy (loki-0 Running) after the
#   scalable-target attempts failed with "Cannot run scalable target"
#   errors.
#
# PREREQUISITE
#   - Cilium installed and healthy
#   - Edit values/alloy-values.yaml's loki.write endpoint URL if you are
#     running Loki somewhere other than in-cluster (e.g. a separate VM)
#
# USAGE
#   chmod +x 07-install-loki-alloy.sh
#   ./07-install-loki-alloy.sh
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. Add the Grafana Helm repo (provides both the Loki and Alloy charts)
# ---------------------------------------------------------------------------
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# ---------------------------------------------------------------------------
# 2. Install Loki (all-in-one, filesystem storage)
# ---------------------------------------------------------------------------
helm upgrade --install loki grafana/loki \
  --namespace loki-system --create-namespace \
  -f values/loki-values.yaml

kubectl wait --for=condition=ready pod -n loki-system -l app.kubernetes.io/name=loki --timeout=180s

# ---------------------------------------------------------------------------
# 3. Install Alloy (log collector DaemonSet)
# ---------------------------------------------------------------------------
# NOTE: values/alloy-values.yaml points loki.write at a specific IP. If
# Loki is running in-cluster (as installed above), you'd typically point
# this at the in-cluster service instead, e.g.:
#   http://loki.loki-system.svc.cluster.local:3100/loki/api/v1/push
# This lab's values file currently points at an external Loki instance —
# edit it to match your environment before running.
helm upgrade --install alloy grafana/alloy \
  --namespace alloy-system --create-namespace \
  -f values/alloy-values.yaml

kubectl wait --for=condition=ready pod -n alloy-system -l app.kubernetes.io/name=alloy --timeout=180s

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
kubectl get pods -n loki-system
kubectl get pods -n alloy-system

echo "Checking Alloy logs for delivery errors..."
kubectl logs -n alloy-system -l app.kubernetes.io/name=alloy --tail=30 || true

echo ""
echo "=== Loki + Alloy installed ==="
echo "Alloy UI/metrics NodePort: http://<node-ip>:31128"
echo "Confirm log delivery with:"
echo "  curl http://<loki-host>:3100/api/prom/label"

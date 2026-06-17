#!/bin/bash
# ============================================================================
# 08-install-prometheus.sh
#
# PURPOSE
#   Installs the kube-prometheus-stack (Prometheus + Prometheus Operator +
#   node-exporter + kube-state-metrics) for cluster metrics collection.
#   Grafana and Alertmanager are disabled — this lab uses an external
#   Grafana instance instead (see values/prometheus-values.yaml).
#
# RUN THIS ON
#   The control-plane node (or anywhere with kubectl access).
#
# WHY prometheusOperator.enabled IS EXPLICIT
#   Earlier attempts in this project's history left this at the chart
#   default and ended up with a Prometheus StatefulSet that never
#   reconciled. Setting `prometheusOperator.enabled: true` explicitly is
#   what produced a healthy, running Prometheus pod.
#
# REMOTE WRITE
#   This configuration ships all scraped metrics to an external endpoint
#   via remoteWrite (e.g. a centralized Prometheus/Mimir/Thanos receiver).
#   Edit values/prometheus-values.yaml's remoteWrite URL to point at your
#   own endpoint, or remove the remoteWrite block entirely if you only
#   want to query this Prometheus directly.
#
# EXPOSING PROMETHEUS DIRECTLY (optional)
#   If you want to query this cluster's Prometheus UI directly instead of
#   (or in addition to) remote-writing elsewhere, expose it via NodePort:
#     kubectl expose service prometheus-kube-prometheus-prometheus \
#       --type=NodePort --name=prometheus-nodeport -n prometheus
#
# PREREQUISITE
#   - Cilium installed and healthy
#   - (Recommended) Metrics Server already installed — kube-state-metrics
#     and node-exporter here are complementary, not a replacement
#
# USAGE
#   chmod +x 08-install-prometheus.sh
#   ./08-install-prometheus.sh
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. Add the prometheus-community Helm repo
# ---------------------------------------------------------------------------
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# ---------------------------------------------------------------------------
# 2. Install kube-prometheus-stack
# ---------------------------------------------------------------------------
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace prometheus --create-namespace \
  -f values/prometheus-values.yaml

# ---------------------------------------------------------------------------
# 3. Wait for the Prometheus pod to come up
# ---------------------------------------------------------------------------
# Note: the actual pod name is prefixed by the Prometheus CR name, e.g.
# prometheus-prometheus-kube-prometheus-prometheus-0 — this is normal
# kube-prometheus-stack naming, not a typo.
kubectl wait --for=condition=ready pod -n prometheus \
  -l app.kubernetes.io/name=prometheus --timeout=300s || true

kubectl get pods -n prometheus

# ---------------------------------------------------------------------------
# 4. Confirm remote_write is sending data (if configured)
# ---------------------------------------------------------------------------
echo "Checking Prometheus logs for remote_write activity..."
kubectl logs -n prometheus \
  -l app.kubernetes.io/name=prometheus --tail=50 2>/dev/null \
  | grep -i "sent batch\|remote" || echo "(no remote_write log lines yet — may need a few scrape cycles)"

echo ""
echo "=== Prometheus installed ==="
echo "To expose the Prometheus UI directly via NodePort, run:"
echo "  kubectl expose service prometheus-kube-prometheus-prometheus \\"
echo "    --type=NodePort --name=prometheus-nodeport -n prometheus"

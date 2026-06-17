#!/bin/bash
# ============================================================================
# 04-install-metrics-server.sh
#
# PURPOSE
#   Installs Metrics Server, which powers `kubectl top nodes` /
#   `kubectl top pods` and is also a prerequisite for the Kubernetes
#   Dashboard's resource graphs and for Horizontal Pod Autoscalers (HPA).
#
# RUN THIS ON
#   The control-plane node (or anywhere with kubectl access).
#
# PREREQUISITE
#   - Cilium is installed and healthy (03-install-cilium.sh)
#   - CoreDNS is running
#
# WHY --kubelet-insecure-tls IS USED
#   Metrics Server, by default, verifies the kubelet's serving certificate
#   against the cluster CA. In many kubeadm clusters (including this one),
#   kubelet serving certs are self-signed and not in that trust chain,
#   causing Metrics Server to fail with x509 errors. --kubelet-insecure-tls
#   skips that verification.
#
#   This is acceptable for a lab/internal cluster. For a production cluster
#   handling sensitive workloads, properly provision kubelet serving certs
#   instead (e.g. via the kubelet-csr-approver) and remove this flag.
#
# USAGE
#   chmod +x 04-install-metrics-server.sh
#   ./04-install-metrics-server.sh
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. Add the Helm repo
# ---------------------------------------------------------------------------
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

# ---------------------------------------------------------------------------
# 2. Install
# ---------------------------------------------------------------------------
# See values/metrics-server-values.yaml for the file-based equivalent:
#   helm upgrade --install metrics-server metrics-server/metrics-server \
#     -n kube-system -f values/metrics-server-values.yaml
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\,Hostname,--metric-resolution=15s}'

# ---------------------------------------------------------------------------
# 3. Wait for metrics to populate
# ---------------------------------------------------------------------------
# Metrics Server needs a scrape cycle or two before `kubectl top` returns
# data — querying immediately after install usually returns an empty/error
# response even when the pod itself is Running.
echo "Waiting 30s for metrics to populate..."
sleep 30

kubectl top nodes
kubectl top pods -A

echo ""
echo "=== Metrics Server installed ==="

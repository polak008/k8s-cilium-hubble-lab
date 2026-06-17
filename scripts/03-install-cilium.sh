#!/bin/bash
# ============================================================================
# 03-install-cilium.sh
#
# PURPOSE
#   Installs the Cilium CLI tool and deploys Cilium (CNI + kube-proxy
#   replacement + Hubble) onto the cluster via Helm.
#
# RUN THIS ON
#   The control-plane node only (or any machine with kubectl access to the
#   cluster). Cilium itself deploys as a DaemonSet that runs on every node
#   automatically — you do not need to run this script per-node.
#
# PREREQUISITE
#   - 01-init-control-plane.sh has completed
#   - `kubectl get nodes` shows the control-plane as Ready
#   - If multi-node: all workers have joined via 02-join-worker.sh
#
# WHAT IT DOES
#   1. Downloads and installs the cilium-cli binary (used for status checks,
#      `cilium status`, `cilium hubble observe`, etc. — separate from the
#      Cilium agent itself which is deployed via Helm)
#   2. Adds the official Cilium Helm repo
#   3. Installs Cilium with:
#        - kubeProxyReplacement=true  (eBPF replaces kube-proxy entirely)
#        - routingMode=tunnel + tunnelProtocol=vxlan
#          (works without BGP or special L2 network fabric — easiest mode
#          for cloud VMs / lab environments)
#        - hubble.relay + hubble.ui enabled (network observability)
#   4. Waits for all Cilium pods to become Ready
#   5. Confirms CoreDNS comes up afterward (CoreDNS depends on Cilium
#      networking being functional first)
#
# USAGE
#   chmod +x 03-install-cilium.sh
#   ./03-install-cilium.sh
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# EDIT THIS to match your control-plane node's IP
# ---------------------------------------------------------------------------
CONTROL_PLANE_IP="10.0.2.11"

# ---------------------------------------------------------------------------
# 1. Cilium CLI
# ---------------------------------------------------------------------------
# This is a standalone troubleshooting/status tool (cilium status, cilium
# hubble observe, cilium connectivity test). It is NOT the same as the
# Cilium agent that actually runs the CNI — that part comes from the Helm
# chart below.
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
rm cilium-linux-amd64.tar.gz

# ---------------------------------------------------------------------------
# 2. Helm repo
# ---------------------------------------------------------------------------
helm repo add cilium https://helm.cilium.io/
helm repo update

# ---------------------------------------------------------------------------
# 3. Install Cilium
# ---------------------------------------------------------------------------
# See values/cilium-values.yaml for a file-based equivalent of these same
# settings if you'd rather run:
#   helm upgrade --install cilium cilium/cilium -n kube-system \
#     -f values/cilium-values.yaml
#
# Parameter notes:
#   kubeProxyReplacement=true
#     Cilium handles ClusterIP / NodePort / LoadBalancer / HostPort entirely
#     in eBPF instead of kube-proxy's iptables rules. Requires
#     proxy.disabled: true to have been set in the kubeadm config
#     (see 01-init-control-plane.sh) so kube-proxy's DaemonSet is never
#     deployed in the first place.
#   routingMode=tunnel / tunnelProtocol=vxlan
#     Encapsulates pod-to-pod traffic in VXLAN. Works on any network without
#     needing BGP peering or L2 adjacency between nodes — the simplest
#     routing mode for cloud VMs, NAT'd networks, or lab setups.
#   hubble.relay.enabled / hubble.ui.enabled
#     Deploys Hubble Relay (aggregates flow data across all nodes) and the
#     Hubble UI (web dashboard for browsing those flows).
#   operator.replicas=1
#     Single replica is fine for a lab/single-node cluster. Increase to 2+
#     for HA on a real multi-node production cluster.
#   k8sServiceHost / k8sServicePort
#     Tells the Cilium agent how to reach the API server directly, since
#     kube-proxy (which would normally provide the `kubernetes` ClusterIP
#     service) does not exist in this setup.
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1 \
  --set k8sServiceHost="${CONTROL_PLANE_IP}" \
  --set k8sServicePort=6443 \
  --set cluster.name=kubernetes

# ---------------------------------------------------------------------------
# 4. Wait for Cilium to become healthy
# ---------------------------------------------------------------------------
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=300s

kubectl get pods -n kube-system | grep -E "cilium|hubble"

# ---------------------------------------------------------------------------
# 5. Confirm CoreDNS recovers
# ---------------------------------------------------------------------------
# CoreDNS pods typically sit in ContainerCreating/Pending until Cilium's
# networking is up. They should self-heal within a minute or two of Cilium
# becoming Ready.
echo "Waiting for CoreDNS to stabilize..."
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=kube-dns --timeout=180s || \
  echo "WARNING: CoreDNS not ready yet — check 'kubectl get pods -n kube-system' and docs/troubleshooting.md"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Cilium installed ==="
echo "Hubble UI:   http://${CONTROL_PLANE_IP}:32121"
echo "Status check: cilium status --verbose"

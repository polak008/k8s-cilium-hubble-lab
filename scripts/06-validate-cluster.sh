#!/bin/bash
# ============================================================================
# 06-validate-cluster.sh
#
# PURPOSE
#   Runs a full health check across the cluster — useful both right after
#   initial setup and any time you suspect something's gone sideways.
#
# RUN THIS ON
#   The control-plane node (or anywhere with kubectl + cilium CLI access).
#
# WHAT IT CHECKS (in order)
#   1. Node status            -> are all nodes Ready?
#   2. All pods cluster-wide  -> anything stuck Pending/CrashLoopBackOff?
#   3. Cilium status          -> is the CNI itself healthy?
#   4. KubeProxyReplacement   -> confirms eBPF is actually handling
#                                 ClusterIP/NodePort/LoadBalancer, not a
#                                 silently-failed-back-to-iptables state
#   5. CoreDNS                -> cluster DNS resolution depends on this
#   6. Resource usage         -> requires Metrics Server (04-install-metrics-server.sh)
#   7. NodePort services      -> quick reference of everything externally reachable
#
# USAGE
#   chmod +x 06-validate-cluster.sh
#   ./06-validate-cluster.sh
# ============================================================================
set -euo pipefail
# Note: NOT using -x here (unlike the install scripts) — this script is
# meant to be run repeatedly as a status check, and -x would clutter the
# output we actually want to read.

echo "### 1. Node status"
kubectl get nodes -o wide

echo ""
echo "### 2. All pods (cluster-wide)"
kubectl get pods -A

echo ""
echo "### 3. Cilium status"
cilium status

echo ""
echo "### 4. KubeProxyReplacement details"
# Confirms Cilium's eBPF datapath is actually serving ClusterIP/NodePort/
# LoadBalancer traffic. If this ever shows "False" or is missing entries,
# something has fallen back to a degraded mode and needs investigation.
cilium status --verbose | grep -A10 KubeProxyReplacement || true

echo ""
echo "### 5. CoreDNS"
kubectl get pods -n kube-system | grep coredns

echo ""
echo "### 6. Resource usage (requires Metrics Server)"
kubectl top nodes || echo "(metrics-server not installed yet — see scripts/04-install-metrics-server.sh)"
kubectl top pods -A || true

echo ""
echo "### 7. Services exposing NodePorts"
kubectl get svc -A | grep NodePort

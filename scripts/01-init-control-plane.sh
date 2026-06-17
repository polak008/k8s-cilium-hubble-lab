#!/bin/bash
# ============================================================================
# 01-init-control-plane.sh
#
# PURPOSE
#   Initializes the Kubernetes control-plane. This script is CONTROL-PLANE
#   ONLY — never run it on a worker node.
#
# PREREQUISITE
#   00-common-setup.sh must have already completed successfully on this
#   node (kubelet/kubeadm/kubectl/containerd/Helm all installed).
#
# WHAT IT DOES
#   1. Writes a kubeadm config with kube-proxy disabled (Cilium replaces it)
#   2. Runs `kubeadm init`
#   3. Sets up kubeconfig for the current user so `kubectl` works immediately
#   4. Removes the control-plane NoSchedule taint
#      (only relevant for single-node clusters — see note below)
#   5. Prints the `kubeadm join` command for worker nodes
#
# WHY kube-proxy IS DISABLED HERE
#   Cilium fully replaces kube-proxy's functionality (ClusterIP, NodePort,
#   LoadBalancer, HostPort) using eBPF, which is faster and avoids the
#   linear iptables-rule growth that happens as services scale. Disabling
#   it at the kubeadm level means the kube-proxy DaemonSet is never even
#   deployed, instead of deploying it and then deleting it.
#
# USAGE
#   chmod +x 01-init-control-plane.sh
#   ./01-init-control-plane.sh
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# EDIT THIS to match the control-plane node's IP (same as THIS_NODE_IP in
# 00-common-setup.sh when run on this node)
# ---------------------------------------------------------------------------
CONTROL_PLANE_IP="10.0.2.11"
KUBERNETES_VERSION="v1.34.2"

# Set this to "false" if you are building a MULTI-NODE cluster and want
# regular pods to run only on dedicated worker nodes (the normal,
# production-recommended setup). Leave "true" for a single-node lab
# cluster where the control-plane also needs to run workloads.
SINGLE_NODE_CLUSTER="true"

# ---------------------------------------------------------------------------
# 1. kubeadm config
# ---------------------------------------------------------------------------
# proxy.disabled: true   -> kube-proxy DaemonSet is never deployed
# podSubnet              -> must match the CIDR Cilium's IPAM is configured
#                            for (cluster-pool, see values/cilium-values.yaml)
# serviceSubnet          -> standard Kubernetes service CIDR
cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CONTROL_PLANE_IP}"
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  dnsDomain: cluster.local
  podSubnet: 10.0.0.0/8
  serviceSubnet: 10.96.0.0/12
proxy:
  disabled: true
controlPlaneEndpoint: "${CONTROL_PLANE_IP}:6443"
EOF

# ---------------------------------------------------------------------------
# 2. Initialize the cluster
# ---------------------------------------------------------------------------
sudo kubeadm init --config=kubeadm-config.yaml

# ---------------------------------------------------------------------------
# 3. kubeconfig for the current user
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

# ---------------------------------------------------------------------------
# 4. Remove control-plane taint (single-node clusters only)
# ---------------------------------------------------------------------------
# By default, kubeadm taints the control-plane node with
# node-role.kubernetes.io/control-plane:NoSchedule, which prevents regular
# pods — including Cilium's own DaemonSet — from being scheduled there.
# On a single-node cluster with no workers, this taint must be removed or
# Cilium will sit in Pending forever and the cluster will never become
# healthy. On a real multi-node cluster, leave the taint in place so the
# control-plane is reserved for control-plane components only.
if [ "$SINGLE_NODE_CLUSTER" = "true" ]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
  echo "Control-plane taint removed (single-node mode)."
else
  echo "Leaving control-plane taint in place (multi-node mode)."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Control-plane initialized ==="
echo "Next step: install Cilium with 02-install-cilium.sh"
echo ""
echo "If you are adding worker nodes, run this on each worker (after"
echo "00-common-setup.sh has completed there):"
echo ""
kubeadm token create --print-join-command

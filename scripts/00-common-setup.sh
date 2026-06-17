#!/bin/bash
# ============================================================================
# 00-common-setup.sh
#
# PURPOSE
#   Prepares ANY node (control-plane OR worker) to run Kubernetes with
#   Cilium as the CNI. This script is identical for every node in the
#   cluster — there is nothing control-plane-specific in here.
#
# RUN THIS ON
#   - The control-plane node
#   - Every worker node (if you're building a multi-node cluster)
#
# WHEN TO RUN
#   Once per node, before kubeadm init (control-plane) or kubeadm join
#   (workers). Safe to re-run — most steps are idempotent.
#
# WHAT IT DOES (in order)
#   1. Sets a unique hostname and registers it in /etc/hosts
#   2. Installs base packages (curl, gpg, ca-certificates, etc.)
#   3. Enables NTP time sync (etcd is sensitive to clock skew)
#   4. Disables swap (kubelet refuses to start with swap on)
#   5. Disables UFW (lab default — see README for production firewall rules)
#   6. Loads kernel modules required by the CNI (overlay, br_netfilter, vxlan)
#   7. Sets sysctl flags required for pod networking / bridging
#   8. Installs and configures containerd as the container runtime
#   9. Installs kubelet, kubeadm, kubectl and pins their versions
#  10. Installs Helm (required later to install Cilium via its chart)
#
# USAGE
#   Edit THIS_NODE_IP and THIS_NODE_HOSTNAME below for each node, then:
#     chmod +x 00-common-setup.sh
#     sudo ./00-common-setup.sh
#   (Or run as your normal user — the script calls sudo internally where
#   needed instead of requiring the whole script to run as root.)
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# EDIT THESE PER NODE
# ---------------------------------------------------------------------------
THIS_NODE_IP="10.0.2.11"          # this node's own IP (changes per node!)
THIS_NODE_HOSTNAME="kube-master"  # unique hostname for this node
                                   # e.g. kube-master, kube-worker1, kube-worker2

KUBERNETES_VERSION="v1.34"        # major.minor only — used for the apt repo
PAUSE_IMAGE_VERSION="3.10.1"      # must match what kubelet expects

# ---------------------------------------------------------------------------
# 1. Hostname + /etc/hosts
# ---------------------------------------------------------------------------
# Every node needs a unique, resolvable hostname. Without this, kubeadm
# emits warnings and cluster DNS can misbehave (especially noticeable on
# multi-node clusters where nodes need to resolve each other).
sudo hostnamectl set-hostname "$THIS_NODE_HOSTNAME"
grep -q "$THIS_NODE_IP" /etc/hosts || \
  echo "$THIS_NODE_IP  $THIS_NODE_HOSTNAME" | sudo tee -a /etc/hosts

# NOTE for multi-node clusters: after running this on every node, manually
# add every OTHER node's IP + hostname to this node's /etc/hosts too
# (or better: use a real internal DNS resolver instead of /etc/hosts).
# Example:
#   echo "10.0.2.12  kube-worker1" | sudo tee -a /etc/hosts
#   echo "10.0.2.13  kube-worker2" | sudo tee -a /etc/hosts

# ---------------------------------------------------------------------------
# 2. Base packages
# ---------------------------------------------------------------------------
sudo apt update && sudo apt upgrade -y
sudo apt install -y apt-transport-https ca-certificates curl gpg

# ---------------------------------------------------------------------------
# 3. Time synchronization
# ---------------------------------------------------------------------------
# etcd (used by the control-plane) is extremely sensitive to clock skew.
# More than ~500ms of drift between nodes can cause etcd leader election
# failures and apiserver certificate validation errors. systemd-timesyncd
# ships with Ubuntu 24.04 by default — this just makes sure it's enabled.
sudo systemctl enable --now systemd-timesyncd
timedatectl status

# ---------------------------------------------------------------------------
# 4. Disable swap
# ---------------------------------------------------------------------------
# kubelet will refuse to start (or behave incorrectly) with swap enabled.
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

# ---------------------------------------------------------------------------
# 5. Firewall
# ---------------------------------------------------------------------------
# Lab default: disable UFW entirely so Cilium's VXLAN traffic (UDP 8472)
# and the Kubernetes control-plane ports are never silently blocked.
#
# For a production / multi-tenant setup, replace this with explicit allow
# rules instead of disabling the firewall outright. See README.md for the
# full list of ports Kubernetes + Cilium need open between nodes.
sudo ufw disable || true

# ---------------------------------------------------------------------------
# 6. Kernel modules required by the CNI
# ---------------------------------------------------------------------------
# overlay        - needed by containerd's overlayfs snapshotter
# br_netfilter   - lets iptables/nftables see bridged traffic (pod networking)
# vxlan          - required for Cilium's VXLAN tunnel routing mode
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
vxlan
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe vxlan

# Sanity check — all three should be listed
lsmod | grep -E "overlay|br_netfilter|vxlan"

# ---------------------------------------------------------------------------
# 7. Sysctl settings
# ---------------------------------------------------------------------------
# ip_forward                       - lets the node route packets between pods
# bridge-nf-call-iptables/ip6tables - ensures bridged traffic is visible to
#                                     netfilter, which Cilium's eBPF programs
#                                     and kube-proxy-replacement rely on
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

# ---------------------------------------------------------------------------
# 8. containerd (container runtime)
# ---------------------------------------------------------------------------
sudo apt install -y containerd

# Generate the default config rather than hand-writing one
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Kubernetes requires the systemd cgroup driver, not containerd's default
# of cgroupfs. Without this, kubelet and containerd disagree about cgroup
# management and pods can behave unpredictably under resource pressure.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Pin the sandbox (pause) image version to match what kubelet expects.
# containerd's generated default config sometimes references an older
# pause image than the Kubernetes version you're installing supports —
# this keeps both in sync and avoids ContainerCreating image-pull errors.
sudo sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:${PAUSE_IMAGE_VERSION}\"|" \
  /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

# ---------------------------------------------------------------------------
# 9. kubelet, kubeadm, kubectl
# ---------------------------------------------------------------------------
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl

# Pin these packages so a routine `apt upgrade` can't silently break the
# cluster by jumping to an incompatible Kubernetes minor version.
sudo apt-mark hold kubelet kubeadm kubectl

# ---------------------------------------------------------------------------
# 10. Helm
# ---------------------------------------------------------------------------
# Helm is required later to install Cilium (and optionally Metrics Server,
# the Dashboard, etc.) via their Helm charts. It is NOT installed by any
# Kubernetes or containerd package — must be installed explicitly.
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

helm version

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Common node setup complete on ${THIS_NODE_HOSTNAME} (${THIS_NODE_IP}) ==="
echo "Next step:"
echo "  - On the CONTROL-PLANE node: run 01-init-control-plane.sh"
echo "  - On WORKER nodes: wait for the control-plane's join command, then run 02-join-worker.sh"

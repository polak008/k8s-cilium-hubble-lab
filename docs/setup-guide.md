# Kubernetes Cluster Setup with Cilium & Hubble (kube-proxy replacement)

> Based on live cluster analysis — single-node control-plane, Ubuntu 24.04, Kubernetes v1.34.2, Cilium 1.18.4, kube-proxy fully replaced.
> Document updated June 2026 to reflect actual production cluster state and fix all setup gaps.

## Architecture Summary

| Component | Value |
|---|---|
| OS | Ubuntu 24.04.3 LTS |
| Kernel | 6.8.0-90-generic |
| Kubernetes | v1.34.2 (kubeadm) |
| Container Runtime | containerd 1.7.28 |
| CNI | Cilium 1.18.4 |
| Kube-proxy | **Disabled** (replaced by Cilium) |
| Hubble | Relay + UI enabled |
| Hubble UI access | NodePort 32121 |
| Routing | VXLAN tunnel (encapsulation) |
| Pod CIDR | 10.0.0.0/8 (per-node mask /24) |
| Service CIDR | 10.96.0.0/12 |
| NodePort range | 30000-32767 |
| IPAM | cluster-pool (CRD-backed) |
| Helm | v3 (required — install before Cilium) |
| Metrics Server | v0.7.2 (Helm, kubelet-insecure-tls) |
| Kubernetes Dashboard | v2.7.0 (NodePort 32688) |

---

## Live Cluster NodePort Reference

Confirmed running services from this cluster:

| Service | Namespace | NodePort | Access |
|---|---|---|---|
| Hubble UI | kube-system | 32121 | `http://<node-ip>:32121` |
| Kubernetes Dashboard | kubernetes-dashboard | 32688 | `https://<node-ip>:32688` |
| ArgoCD | argocd | 31961 (HTTPS), 32221 (HTTP) | `https://<node-ip>:31961` |
| Grafana Alloy | alloy-system | 31128 | `http://<node-ip>:31128` |
| NGINX Gateway Fabric | nginx-gateway | 32343 | `http://<node-ip>:32343` |
| Radar | radar | 31656 | `http://<node-ip>:31656` |
| Guestbook (demo) | default | 31519 | `http://<node-ip>:31519` |

---

## 1. Prerequisites — Server Preparation

Run on **every node**.

### 1.1 Set hostname and /etc/hosts

```bash
# Set a unique hostname per node
sudo hostnamectl set-hostname kube-master

# Add entry to /etc/hosts so the hostname resolves locally
echo "10.0.2.11  kube-master" | sudo tee -a /etc/hosts

# For multi-node: add all node IPs/hostnames to /etc/hosts on each node
# echo "10.0.2.12  kube-worker1" | sudo tee -a /etc/hosts
```

> This is required. kubeadm will warn and cluster DNS can misbehave without a resolvable hostname.

### 1.2 Update system and install essentials

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y apt-transport-https ca-certificates curl gpg
```

### 1.3 Verify time synchronization

```bash
# Check systemd-timesyncd is active (ships with Ubuntu 24.04 by default)
timedatectl status

# If not synced, enable it
sudo systemctl enable --now systemd-timesyncd

# Verify
timedatectl show --property=NTPSynchronized
```

> etcd is extremely sensitive to clock skew between nodes. Skew over ~500ms causes etcd leader election failures and apiserver certificate validation errors.

### 1.4 Disable swap

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab
```

Verify: `swapon --show` should return nothing.

### 1.5 Configure firewall (UFW)

Ubuntu 24.04 ships with UFW. You must open the required ports **before** running kubeadm or Cilium VXLAN will be blocked between nodes.

```bash
# Disable UFW entirely (simplest for a lab/VM cluster)
sudo ufw disable

# --- OR --- open only required ports for a production setup:
# API server
sudo ufw allow 6443/tcp
# etcd (only needed on control-plane nodes)
sudo ufw allow 2379:2380/tcp
# kubelet
sudo ufw allow 10250/tcp
# kube-scheduler and kube-controller-manager
sudo ufw allow 10251/tcp
sudo ufw allow 10252/tcp
# NodePort range
sudo ufw allow 30000:32767/tcp
# Cilium VXLAN (required between nodes)
sudo ufw allow 8472/udp
# Cilium health check
sudo ufw allow 4240/tcp

sudo ufw reload
```

> For AWS EC2: also open these same ports in the EC2 Security Group attached to the instances.

### 1.6 Load required kernel modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
vxlan
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe vxlan
```

Verify all three loaded:

```bash
lsmod | grep -E "overlay|br_netfilter|vxlan"
```

### 1.7 Set kernel parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

Verify: `sysctl net.ipv4.ip_forward` should return `net.ipv4.ip_forward = 1`.

### 1.8 Install containerd

```bash
sudo apt install -y containerd

# Generate default config
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Pin the correct pause image for Kubernetes 1.34
sudo sed -i 's|sandbox_image = .*|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml

# Restart and enable
sudo systemctl restart containerd
sudo systemctl enable containerd
```

> The pause image version must match what kubelet expects. Kubernetes 1.34 uses `pause:3.10.1`. The `containerd config default` command may generate an older version — the `sed` above corrects it.

### 1.9 Install Kubernetes components (kubelet, kubeadm, kubectl)

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### 1.10 Install Helm

Helm is **required** before installing Cilium. It is not included in any of the above steps.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# Verify
helm version
```

---

## 2. Initialize the Cluster (control-plane node only)

### 2.1 Determine the control-plane endpoint IP

Use the primary network interface IP. In this cluster it is `10.0.2.11` on interface `enp0s3`.

```bash
ip addr show enp0s3 | grep inet
```

### 2.2 Create kubeadm config with kube-proxy disabled

```bash
cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.0.2.11"
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.2
networking:
  dnsDomain: cluster.local
  podSubnet: 10.0.0.0/8
  serviceSubnet: 10.96.0.0/12
proxy:
  disabled: true
controlPlaneEndpoint: "10.0.2.11:6443"
EOF
```

### 2.3 Run kubeadm init

```bash
sudo kubeadm init --config=kubeadm-config.yaml
```

### 2.4 Set up kubeconfig for your user

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 2.5 Remove control-plane taint (single-node only)

On a single-node cluster, the control-plane taint prevents regular pods (including Cilium) from scheduling. Remove it:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

> Without this, Cilium DaemonSet pods will be stuck in `Pending` and the cluster will not become healthy.

### 2.6 (Multi-node) Join worker nodes

The `kubeadm init` output prints a `kubeadm join` token command valid for **24 hours**. Save it and run on workers:

```bash
sudo kubeadm join 10.0.2.11:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

If the token has expired, regenerate it on the control-plane:

```bash
kubeadm token create --print-join-command
```

---

## 3. Install Cilium with kube-proxy Replacement & Hubble

### 3.1 Install Cilium CLI

```bash
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
rm cilium-linux-amd64.tar.gz
```

### 3.2 Add the Cilium Helm repo

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

### 3.3 Install Cilium with Helm

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1 \
  --set k8sServiceHost=10.0.2.11 \
  --set k8sServicePort=6443 \
  --set cluster.name=kubernetes
```

**Parameter explanation:**

| Parameter | Value | Why |
|---|---|---|
| `kubeProxyReplacement` | `true` | Fully replaces kube-proxy. Cilium handles ClusterIP, NodePort, LoadBalancer, HostPort entirely in eBPF. |
| `routingMode` | `tunnel` | VXLAN encapsulation — works without any special network fabric or routing between nodes. |
| `tunnelProtocol` | `vxlan` | Encapsulates pod traffic in VXLAN. No need for BGP or layer-2 adjacency. |
| `hubble.relay.enabled` | `true` | Deploys Hubble Relay for cluster-wide flow visibility. |
| `hubble.ui.enabled` | `true` | Deploys the Hubble web UI for browsing flows. |
| `operator.replicas` | `1` | Single replica for the Cilium operator (adequate for single-node). |
| `k8sServiceHost` | `10.0.2.11` | API server IP — needed by Cilium agent to connect to apiserver without kube-proxy. |
| `k8sServicePort` | `6443` | API server port. |

> `kube-proxy` is disabled at the kubeadm level (`proxy.disabled: true`), so the kube-proxy DaemonSet is never deployed. Cilium handles all service functions in its place.

### 3.4 Verify Cilium installation

```bash
# Wait for Cilium pods to be ready
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=300s

# Check all pods
kubectl get pods -n kube-system | grep cilium

# Run detailed status
cilium status --verbose
```

Expected output includes:

```
KubeProxyReplacement Details:
  Status:               True
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

### 3.5 Verify CoreDNS is running

CoreDNS depends on Cilium networking. After Cilium is ready, confirm CoreDNS is healthy:

```bash
kubectl get pods -n kube-system | grep coredns
```

Both CoreDNS pods should show `Running`. If they are stuck in `ContainerCreating`, wait for Cilium to fully initialize and retry.

---

## 4. Access Hubble UI

### 4.1 Get the NodePort

```bash
kubectl get svc -n kube-system hubble-ui
```

Output:

```
NAME         TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
hubble-ui    NodePort   10.107.146.40   <none>        80:32121/TCP   191d
```

Access at: `http://<node-ip>:32121`

---

## 5. Install kubectl Autocomplete and Alias (optional but recommended)

```bash
sudo apt install -y bash-completion
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null

# Add alias and completion to ~/.bashrc
cat <<'EOF' >> ~/.bashrc
alias k=kubectl
complete -o default -F __start_kubectl k
EOF

source ~/.bashrc
```

---

## 6. Install Metrics Server

The default Metrics Server manifest does not work on clusters without valid kubelet TLS certificates. Use the Helm chart with `kubelet-insecure-tls`.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\,Hostname,--metric-resolution=15s}'
```

Verify after ~30 seconds:

```bash
kubectl top nodes
kubectl top pods -A
```

---

## 7. Install Kubernetes Dashboard (v2.7.0)

This cluster uses Kubernetes Dashboard v2.7.0 (last of the v2 series). The v3/Helm-based dashboard uses a Kong gateway and is more complex to expose — v2.7.0 is simpler for lab use.

### 7.1 Deploy dashboard

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
```

### 7.2 Expose as NodePort

```bash
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":32688}]}}'
```

### 7.3 Create admin service account and token

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF
```

### 7.4 Get the login token

```bash
kubectl -n kubernetes-dashboard get secret admin-user-token \
  -o jsonpath='{.data.token}' | base64 -d && echo
```

Access at: `https://<node-ip>:32688` (accept the self-signed certificate warning)

---

## 8. Full Cluster Validation

```bash
# Node status
kubectl get nodes -o wide

# All pods healthy
kubectl get pods -A

# Cilium agent connectivity
cilium status

# Hubble flows
cilium hubble observe

# Resource usage
kubectl top nodes
kubectl top pods -A
```

---

## 9. Key Differences from a kube-proxy Setup

| Aspect | kube-proxy | Cilium kube-proxy replacement |
|---|---|---|
| Implementation | iptables/IPVS userspace | eBPF in-kernel |
| Performance | Higher latency, rules grow with services | Constant-time, O(1) |
| NodePort | iptables DNAT | BPF-based, direct from NIC |
| ClusterIP | iptables rules per service | eBPF map lookup |
| kube-proxy pod | Runs as DaemonSet (resource usage) | Not deployed at all |

---

## 10. Current Cluster Configuration Reference

### 10.1 kubeadm config (retrieved live)

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.2
networking:
  dnsDomain: cluster.local
  podSubnet: 10.0.0.0/8
  serviceSubnet: 10.96.0.0/12
proxy:
  disabled: true
controlPlaneEndpoint: "10.0.2.11:6443"
```

### 10.2 Cilium Helm values (retrieved live)

```yaml
cluster:
  name: kubernetes
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
k8sServiceHost: 10.0.2.11
k8sServicePort: 6443
kubeProxyReplacement: true
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
```

### 10.3 Cilium ConfigMap key settings

| Key | Value | Purpose |
|---|---|---|
| `kube-proxy-replacement` | `true` | Full kube-proxy replacement |
| `routing-mode` | `tunnel` | VXLAN overlay networking |
| `tunnel-protocol` | `vxlan` | Encapsulation protocol |
| `ipam` | `cluster-pool` | CRD-backed IP allocation |
| `cluster-pool-ipv4-cidr` | `10.0.0.0/8` | Pod IP pool |
| `cluster-pool-ipv4-mask-size` | `24` | Per-node pod subnet size |
| `bpf-lb-map-max` | `65536` | Max services in BPF maps |
| `enable-hubble` | `true` | Hubble observability |
| `hubble-listen-address` | `:4244` | Hubble gRPC endpoint |
| `node-port-bind-protection` | `true` | Prevent port conflicts |
| `enable-health-check-nodeport` | `true` | Health check for NodePort |

### 10.4 kubelet extra args

```bash
# /var/lib/kubelet/kubeadm-flags.env
KUBELET_KUBEADM_ARGS="--pod-infra-container-image=registry.k8s.io/pause:3.10.1"
```

No additional `KUBELET_EXTRA_ARGS` are configured.

---

## 11. Quick Setup Script (all-in-one)

**Replace `10.0.2.11` and `enp0s3` with your actual node IP and interface before running.**

```bash
#!/bin/bash
set -euxo pipefail

NODE_IP="10.0.2.11"
NODE_IFACE="enp0s3"
NODE_HOSTNAME="kube-master"

# === 1. Hostname ===
sudo hostnamectl set-hostname "$NODE_HOSTNAME"
grep -q "$NODE_IP" /etc/hosts || echo "$NODE_IP  $NODE_HOSTNAME" | sudo tee -a /etc/hosts

# === 2. Prerequisites ===
sudo apt update && sudo apt install -y apt-transport-https ca-certificates curl gpg

# Time sync
sudo systemctl enable --now systemd-timesyncd

# Swap off
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

# Firewall — disable for lab use
sudo ufw disable || true

# === 3. Kernel modules ===
for mod in overlay br_netfilter vxlan; do sudo modprobe $mod; done
printf "overlay\nbr_netfilter\nvxlan\n" | sudo tee /etc/modules-load.d/k8s.conf

# Sysctl
printf "net.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n" \
  | sudo tee /etc/sysctl.d/k8s.conf
sudo sysctl --system

# === 4. containerd ===
sudo apt install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = .*|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# === 5. Kubernetes packages ===
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# === 6. Helm ===
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh && ./get_helm.sh && rm get_helm.sh

# === 7. kubeadm init ===
cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.2
networking:
  dnsDomain: cluster.local
  podSubnet: 10.0.0.0/8
  serviceSubnet: 10.96.0.0/12
proxy:
  disabled: true
controlPlaneEndpoint: "${NODE_IP}:6443"
EOF

sudo kubeadm init --config=kubeadm-config.yaml

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Remove control-plane taint (single-node)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# === 8. Cilium ===
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
rm cilium-linux-amd64.tar.gz

helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1 \
  --set k8sServiceHost="${NODE_IP}" \
  --set k8sServicePort=6443 \
  --set cluster.name=kubernetes

# === 9. Verify ===
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=300s
kubectl get nodes -o wide
kubectl get pods -n kube-system | grep -E "cilium|hubble|coredns"

echo ""
echo "=== Cluster ready ==="
echo "Hubble UI: http://${NODE_IP}:32121"
```

---

## 12. Troubleshooting

### Cilium agent not starting

```bash
kubectl logs -n kube-system -l k8s-app=cilium
```

### Cilium pods stuck in Pending

Most likely cause on a single-node cluster: control-plane taint not removed.

```bash
kubectl describe nodes | grep -A5 Taints
# If you see node-role.kubernetes.io/control-plane:NoSchedule, run:
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### Hubble Relay not connecting

```bash
cilium status | grep Hubble
kubectl logs -n kube-system -l k8s-app=hubble-relay
```

### NodePort not reachable

```bash
# Check Cilium kube-proxy replacement status
cilium status | grep -A10 KubeProxyReplacement

# Check the port is bound
sudo ss -tlnp | grep <nodeport>

# Check UFW is not blocking
sudo ufw status
```

### CoreDNS not starting

CoreDNS requires Cilium to be running first. Wait for Cilium DaemonSet to be fully ready, then CoreDNS should self-heal. If not:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

### Missing kernel features for eBPF

```bash
# Verify BTF is present (required for Cilium eBPF datapath)
ls /sys/kernel/btf/vmlinux
```

If missing, Cilium falls back to legacy `tc` datapath instead of `xdp` — functionality is preserved but performance is reduced.

### kubeadm join token expired (multi-node)

Tokens expire after 24 hours by default. Regenerate on the control-plane:

```bash
kubeadm token create --print-join-command
```

### containerd and Kubernetes pause image mismatch

If pods are stuck in `ContainerCreating` with image pull errors related to `pause`:

```bash
# Verify both config files use the same version
grep sandbox_image /etc/containerd/config.toml
grep pause /var/lib/kubelet/kubeadm-flags.env
# Both should reference registry.k8s.io/pause:3.10.1
```

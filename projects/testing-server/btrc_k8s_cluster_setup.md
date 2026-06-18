# BTRC Kubernetes Cluster — Full Setup Guide (Bare Metal / VM, Ubuntu 24.04)

> Kubernetes v1.36.1 · containerd v2.2.1 · Cilium v1.19.5 (kube-proxy replacement + Hubble) · Helm v3
> 1 control-plane + 2 workers, built from completely fresh Ubuntu 24.04 servers.

## Cluster topology

| Hostname | IP | Role |
|---|---|---|
| btrc-kube-master-01 | 192.168.30.165 | Kubernetes control-plane |
| btrc-kube-worker-01 | 192.168.30.166 | Kubernetes worker |
| btrc-kube-worker-02 | 192.168.30.167 | Kubernetes worker |

All commands below run as a regular user with sudo (`devopsadmin`), never as root directly, except where explicitly noted (`sudo -i`).

---

## Part 0 — Server access and the devopsadmin user

Each server initially has its own per-node user (e.g. `brtc-master-01` on the master). The very first job on every server is creating a shared `devopsadmin` user with passwordless sudo, so the rest of this guide can be run identically everywhere.

### 0.1 Log in as the original user and check the date

```bash
date
```

### 0.2 Create the devopsadmin user

```bash
sudo adduser devopsadmin
```

This prompts for a password and basic info (name, etc.) — fill in or skip as needed.

### 0.3 Grant devopsadmin sudo group membership and passwordless sudo

```bash
sudo usermod -aG sudo devopsadmin
echo "devopsadmin ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/devopsadmin
sudo chmod 440 /etc/sudoers.d/devopsadmin
```

The `chmod 440` is required — `visudo`-managed files in `/etc/sudoers.d/` are rejected by sudo if they're group/world-writable.

### 0.4 Switch to devopsadmin for everything else

```bash
su - devopsadmin
```

From this point on, every command in this guide is run as `devopsadmin` on each respective server.

> Repeat Part 0 on all three servers (master, worker-01, worker-02) before continuing.

---

## Part 1 — Server preparation (run on EVERY node: master + both workers)

### 1.1 Update the system

```bash
sudo apt update -y && sudo apt upgrade -y
```

### 1.2 Set the hostname

Use a unique hostname per node:

```bash
# On the master:
sudo hostnamectl set-hostname btrc-kube-master-01

# On worker 1 instead:
# sudo hostnamectl set-hostname btrc-kube-worker-01

# On worker 2 instead:
# sudo hostnamectl set-hostname btrc-kube-worker-02
```

Confirm the node's own IP:

```bash
hostname -I
```

### 1.3 Add all three nodes to /etc/hosts

Run this identical block on every node so each one can resolve all three by hostname — required for kubeadm and for cluster DNS to behave correctly:

```bash
echo "192.168.30.165  btrc-kube-master-01" | sudo tee -a /etc/hosts
echo "192.168.30.166  btrc-kube-worker-01" | sudo tee -a /etc/hosts
echo "192.168.30.167  btrc-kube-worker-02" | sudo tee -a /etc/hosts
```

### 1.4 Set timezone and confirm NTP sync

```bash
sudo timedatectl set-timezone Asia/Dhaka
date
```

Confirm `systemd-timesyncd` (ships by default on Ubuntu 24.04) is active and synced — etcd is highly sensitive to clock drift between nodes, so this matters on every node, not just the master:

```bash
timedatectl status
sudo systemctl enable --now systemd-timesyncd
timedatectl show --property=NTPSynchronized
```

### 1.5 Install base packages

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg
```

### 1.6 Disable swap

Kubernetes requires swap to be off.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab
swapon --show   # should print nothing
```

### 1.7 Load required kernel modules

`overlay` is needed by containerd's snapshotter, `br_netfilter` lets netfilter see bridged traffic (required for Cilium/kube-proxy-replacement), and `vxlan` is needed for Cilium's tunnel routing mode.

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
vxlan
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe vxlan

lsmod | grep -E "overlay|br_netfilter|vxlan"
```

### 1.8 Set required sysctl parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
sysctl net.ipv4.ip_forward   # confirm it shows = 1
```

### 1.9 Install and configure containerd

```bash
sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

containerd --version
```

Enable the systemd cgroup driver (Kubernetes requires this; containerd defaults to cgroupfs, which causes kubelet/containerd to disagree about cgroup management):

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

Pin the pause/sandbox image version to match what kubelet expects for Kubernetes 1.36:

```bash
grep sandbox_image /etc/containerd/config.toml
sudo sed -i 's|sandbox_image = .*|sandbox_image = "registry.k8s.io/pause:3.10.1"|' /etc/containerd/config.toml
grep sandbox_image /etc/containerd/config.toml
```

Restart and enable containerd so both changes take effect:

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 1.10 Add the Kubernetes 1.36 apt repository

```bash
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
```

Check the exact latest patch available before installing:

```bash
apt-cache madison kubeadm | head -5
```

At the time this cluster was built, that returned `1.36.2-2.1`, `1.36.1-1.1`, and `1.36.0-1.1`. This cluster intentionally pinned to **1.36.1** (the latest version officially listed on the Kubernetes release page at build time):

```bash
sudo apt install -y kubelet='1.36.1-*' kubeadm='1.36.1-*' kubectl='1.36.1-*'
sudo apt-mark hold kubelet kubeadm kubectl
```

`apt-mark hold` prevents a routine `apt upgrade` from silently jumping to an incompatible minor version later.

Confirm versions:

```bash
kubectl version
kubelet --version
kubeadm version
```

> If `apt install` reports a "Pending kernel upgrade" notice (as happened on worker-02 in this build, where the running kernel was `6.8.0-31-generic` but a newer one was available), this is informational only and does not block the Kubernetes install — a reboot can be scheduled later at a convenient time.

### 1.11 kubectl completion and alias (optional, quality of life)

```bash
sudo apt install -y bash-completion
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
source ~/.bashrc
```

> **Repeat all of Part 1 (sections 1.1–1.11) on the master, worker-01, and worker-02 before continuing.** Helm (next section) is only needed on the master.

---

## Part 2 — Install Helm (master only)

Helm is needed to install Cilium via its chart. It is not required on the workers.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

helm version
```

> Note: if you later run the `get-helm-4` script on top of this (as happened in this build), Helm will detect the existing v3 install and offer to upgrade in place to v4 — both work fine for installing Cilium; this guide's commands are compatible with either.

---

## Part 3 — Initialize the control-plane (master only)

Run this only on `btrc-kube-master-01`.

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.30.165 \
  --control-plane-endpoint=192.168.30.165:6443 \
  --kubernetes-version=v1.36.1 \
  --pod-network-cidr=10.0.0.0/8 \
  --service-cidr=10.96.0.0/12 \
  --skip-phases=addon/kube-proxy
```

**What each flag does:**

| Flag | Purpose |
|---|---|
| `--apiserver-advertise-address` | The IP the API server binds and advertises to the rest of the cluster |
| `--control-plane-endpoint` | Stable address other nodes/components use to reach the control-plane |
| `--kubernetes-version` | Pins the exact version kubeadm provisions, matching the installed packages |
| `--pod-network-cidr` | Pod IP range — must match what's later configured in Cilium's IPAM |
| `--service-cidr` | ClusterIP service range |
| `--skip-phases=addon/kube-proxy` | Skips deploying the kube-proxy DaemonSet entirely, since Cilium will replace its functionality with eBPF |

This takes a minute or two. On success it prints two join commands — **save both**, you'll need the worker one shortly:

```
kubeadm join 192.168.30.165:6443 --token <token> \
      --discovery-token-ca-cert-hash sha256:<hash> \
      --control-plane          # for adding more control-plane nodes (not used here)

kubeadm join 192.168.30.165:6443 --token <token> \
      --discovery-token-ca-cert-hash sha256:<hash>   # for worker nodes — this is the one we need
```

### 3.1 Set up kubeconfig for devopsadmin

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 3.2 Confirm the control-plane is up

```bash
kubectl get nodes -o wide
```

At this point the master shows `NotReady` — that's expected, since no CNI is installed yet:

```
NAME                  STATUS     ROLES           AGE   VERSION
btrc-kube-master-01   NotReady   control-plane   42s   v1.36.1
```

---

## Part 4 — Install Cilium with kube-proxy replacement + Hubble (master only)

### 4.1 Install the Cilium CLI

This is a standalone status/troubleshooting tool (`cilium status`, `cilium hubble observe`) — separate from the Cilium agent itself, which is deployed via Helm in the next step.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

### 4.2 Add the Cilium Helm repo

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

### 4.3 Install Cilium

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.ui.service.type=NodePort \
  --set hubble.ui.service.nodePort=32121 \
  --set operator.replicas=1 \
  --set k8sServiceHost=192.168.30.165 \
  --set k8sServicePort=6443 \
  --set cluster.name=kubernetes
```

**What each value does:**

| Value | Purpose |
|---|---|
| `kubeProxyReplacement=true` | Cilium handles ClusterIP/NodePort/LoadBalancer/HostPort entirely in eBPF, replacing kube-proxy |
| `routingMode=tunnel` / `tunnelProtocol=vxlan` | Encapsulates pod traffic in VXLAN — works without BGP or special L2 network setup |
| `hubble.relay.enabled` / `hubble.ui.enabled` | Deploys Hubble Relay (cluster-wide flow aggregation) and the Hubble web UI |
| `hubble.ui.service.type=NodePort` + `nodePort=32121` | Exposes the Hubble UI outside the cluster on a fixed port, instead of the chart's ClusterIP default |
| `operator.replicas=1` | Single replica is fine for this cluster size; increase for HA on larger control-plane counts |
| `k8sServiceHost` / `k8sServicePort` | Tells Cilium how to reach the API server directly, since kube-proxy (which would normally provide this) isn't deployed |

### 4.4 Wait for Cilium to become healthy

```bash
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=300s
```

### 4.5 Confirm the master is now Ready

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

```
NAME                  STATUS   ROLES           AGE     VERSION
btrc-kube-master-01   Ready    control-plane   4m40s   v1.36.1
```

> At this point, with only one node in the cluster, `hubble-relay` and `hubble-ui` may sit in `Pending` if scheduling room is tight. This resolves itself once workers join in the next part — no action needed.

---

## Part 5 — Join the workers

Run Part 1 (server preparation) in full on both `btrc-kube-worker-01` and `btrc-kube-worker-02` before this step, if not already done. Helm is not required on workers.

### 5.1 Run the join command

On **each** worker, using the exact join command printed by `kubeadm init` in Part 3:

```bash
sudo kubeadm join 192.168.30.165:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

> The token is valid for 24 hours from when `kubeadm init` ran. If it has expired by the time you join the second worker, regenerate it from the master:
>
> ```bash
> kubeadm token create --print-join-command
> ```

### 5.2 Verify from the master

Back on `btrc-kube-master-01`:

```bash
kubectl get nodes -o wide
```

Immediately after joining, a worker shows `NotReady` for a few seconds while Cilium's DaemonSet schedules and initializes its agent pod on that node — this is expected and resolves automatically:

```
NAME                  STATUS     ROLES           AGE     VERSION
btrc-kube-master-01   Ready      control-plane   45m     v1.36.1
btrc-kube-worker-01   Ready      <none>          9m40s   v1.36.1
btrc-kube-worker-02   NotReady   <none>          6s      v1.36.1
```

Watch the Cilium pods come up for the new node:

```bash
kubectl get pods -A -o wide
```

You'll see a new `cilium-xxxxx` and `cilium-envoy-xxxxx` pod appear for the joining worker, going through `Init` → `ContainerCreating` → `Running`.

### 5.3 Final confirmation

Re-check after a minute:

```bash
kubectl get nodes -o wide
```

All three nodes should now show `Ready`:

```
NAME                  STATUS   ROLES           AGE   VERSION   INTERNAL-IP
btrc-kube-master-01   Ready    control-plane   46m   v1.36.1   192.168.30.165
btrc-kube-worker-01   Ready    <none>          10m   v1.36.1   192.168.30.166
btrc-kube-worker-02   Ready    <none>          1m    v1.36.1   192.168.30.167
```

```bash
kubectl get pods -A
```

Every pod in `kube-system` should be `Running`, including `hubble-relay` (1/1) and `hubble-ui` (2/2) — these will have flipped from `Pending` to `Running` once there was enough scheduling room across the now-3-node cluster.

```bash
cilium status --verbose
```

Look for:

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

---

## Part 6 — Access the Hubble UI

With `hubble-ui` exposed as NodePort 32121:

```
http://192.168.30.165:32121
```

(Reachable via any node's IP, not just the master, since NodePort services are exposed on every node by default.)

---

## Optional — Persistent, timestamped bash history logging

This cluster's master had a script applied (`logging.sh`, run once as root via `sudo -i`) that forces timestamped, append-mode bash history for every user with a login shell — useful for after-the-fact auditing of exactly what was run and when (which is how the command sequences in this guide were reconstructed).

```bash
sudo -i
vi logging.sh   # paste in the script content below
bash logging.sh
exit
```

Script content:

```bash
#!/bin/bash
# Run this script as root
# Purpose: Force Bash history logging with timestamps and append mode for all users

LOGFILE="/var/log/bash-history-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

HIST_CFG="# Force bash history logging with timestamps and append mode"

read -r -d '' HIST_VARS <<'EOF'
export HISTTIMEFORMAT="%d %b %Y %T "
export HISTSIZE=10000
export HISTFILESIZE=20000

if [[ -n "$PROMPT_COMMAND" && "$PROMPT_COMMAND" != *"history -a"* ]]; then
  export PROMPT_COMMAND="$PROMPT_COMMAND; history -a; history -n"
else
  export PROMPT_COMMAND="history -a; history -n"
fi

shopt -s histappend
shopt -s cmdhist
EOF

echo "Setting up bash history configuration..."

add_config_if_missing() {
  local file=$1
  if [ -f "$file" ]; then
    if ! grep -qF "$HIST_CFG" "$file"; then
      echo -e "\n$HIST_CFG\n$HIST_VARS" >> "$file"
      echo "Added history configuration to $file"
    else
      echo "History configuration already present in $file"
    fi
  fi
}

ensure_bash_profile_sources_bashrc() {
  local home_dir=$1
  local user_name=$2
  local profile_file

  if [ -f "$home_dir/.bash_profile" ]; then
    profile_file="$home_dir/.bash_profile"
  elif [ -f "$home_dir/.profile" ]; then
    profile_file="$home_dir/.profile"
  else
    profile_file="$home_dir/.bash_profile"
    touch "$profile_file"
    chown "$user_name:$user_name" "$profile_file"
    echo "Created $profile_file"
  fi

  if ! grep -q ".bashrc" "$profile_file"; then
    echo -e "\n# Source .bashrc if it exists\nif [ -f ~/.bashrc ]; then\n  . ~/.bashrc\nfi" >> "$profile_file"
    echo "Ensured $profile_file sources .bashrc"
  else
    echo "$profile_file already sources .bashrc"
  fi
}

add_config_if_missing /etc/profile
add_config_if_missing /etc/bash.bashrc

PROFILE_D_FILE="/etc/profile.d/force-history.sh"
if [ ! -f "$PROFILE_D_FILE" ]; then
  echo -e "#!/bin/bash\n$HIST_CFG\n$HIST_VARS" > "$PROFILE_D_FILE"
  chmod +x "$PROFILE_D_FILE"
  echo "Created $PROFILE_D_FILE"
else
  echo "$PROFILE_D_FILE already exists"
fi

echo "Updating all bash users..."

getent passwd | while IFS=: read -r user _ uid _ _ home shell; do
  if [[ $uid -ge 1000 && -d "$home" && "$shell" == */bash ]]; then
    USER_BASHRC="$home/.bashrc"

    if [ ! -f "$USER_BASHRC" ]; then
      touch "$USER_BASHRC"
      chown "$user:$user" "$USER_BASHRC"
      echo "Created $USER_BASHRC"
    fi

    add_config_if_missing "$USER_BASHRC"
    ensure_bash_profile_sources_bashrc "$home" "$user"
  fi
done

echo "Bash history setup complete. Please log out and log back in or run: source ~/.bashrc"
```

> Apply this on whichever nodes you want detailed, timestamped audit history for. It only needs to be run once per node, as root.

---

## Troubleshooting reference

**Cilium pods stuck Pending on a single-node cluster** — remove the control-plane taint (only do this if you intend the control-plane to also run regular workloads):

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

This cluster did not need this step, since workers joined quickly enough to provide scheduling room.

**Worker shows NotReady right after joining** — normal; wait ~30–60 seconds for Cilium's DaemonSet to schedule and start its agent pod on the new node, then re-check `kubectl get nodes`.

**kubeadm join token expired (>24h since init)** — regenerate on the master:

```bash
kubeadm token create --print-join-command
```

**containerd/kubelet pause image mismatch** — confirm both reference the same version:

```bash
grep sandbox_image /etc/containerd/config.toml
grep pause /var/lib/kubelet/kubeadm-flags.env
```

**"Pending kernel upgrade" notice during apt install** — informational only; does not block the Kubernetes install. Schedule a reboot for a convenient maintenance window.

**Hubble UI / Hubble Relay stuck Pending** — usually resolves once enough nodes have joined the cluster to provide scheduling room. If it persists after all nodes are Ready:

```bash
kubectl describe pod -n kube-system -l k8s-app=hubble-ui
```

---

Add Label

```bash
kubectl label node btrc-kube-worker-01 node-role.kubernetes.io/worker=worker

kubectl label node btrc-kube-worker-02 node-role.kubernetes.io/worker=worker
```

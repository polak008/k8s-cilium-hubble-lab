# k8s-cilium-hubble-lab

A reproducible, single-node Kubernetes lab cluster running:

- **Kubernetes v1.34.2** (kubeadm)
- **Cilium 1.18.4** as CNI with **full kube-proxy replacement** (eBPF, VXLAN overlay)
- **Hubble** (Relay + UI) for network observability
- Optional add-ons: Metrics Server, Kubernetes Dashboard

Built on Ubuntu 24.04 LTS. Tested as a single-node control-plane VM, but the
kubeadm config and scripts can be extended to multi-node by joining workers
(see [docs/setup-guide.md](docs/setup-guide.md#26-multi-node-join-worker-nodes)).

---

## Architecture

| Component | Value |
|---|---|
| OS | Ubuntu 24.04.3 LTS |
| Kernel | 6.8.0-90-generic |
| Kubernetes | v1.34.2 (kubeadm) |
| Container Runtime | containerd 1.7.28 |
| CNI | Cilium 1.18.4 |
| Kube-proxy | **Disabled** (replaced by Cilium eBPF) |
| Hubble | Relay + UI enabled (NodePort 32121) |
| Routing | VXLAN tunnel encapsulation |
| Pod CIDR | `10.0.0.0/8` (per-node /24) |
| Service CIDR | `10.96.0.0/12` |
| NodePort range | `30000-32767` |
| IPAM | cluster-pool (CRD-backed) |

---

## Repository Structure

```
k8s-cilium-hubble-lab/
├── README.md
├── LICENSE
├── docs/
│   ├── setup-guide.md        # Full step-by-step setup guide (start here)
│   └── troubleshooting.md     # Common failure modes and fixes
├── manifests/
│   ├── kubeadm-config.yaml    # kubeadm InitConfiguration + ClusterConfiguration
│   ├── namespaces/            # (optional) namespace manifests
│   ├── monitoring/
│   │   └── dashboards/        # Grafana dashboard JSON exports
│   └── gitops/                # (optional) ArgoCD app manifests
├── values/
│   ├── cilium-values.yaml          # Helm values for Cilium
│   ├── metrics-server-values.yaml  # Helm values for Metrics Server
│   ├── loki-values.yaml             # Helm values for Loki (all-in-one)
│   ├── alloy-values.yaml            # Helm values for Grafana Alloy (log shipper)
│   └── prometheus-values.yaml       # Helm values for kube-prometheus-stack
└── scripts/
    ├── 00-common-setup.sh          # Run on EVERY node (control-plane + workers)
    ├── 01-init-control-plane.sh    # Control-plane only: kubeadm init
    ├── 02-join-worker.sh           # Worker only: kubeadm join (multi-node)
    ├── 03-install-cilium.sh        # Install Cilium CLI + Helm chart
    ├── 04-install-metrics-server.sh
    ├── 05-install-dashboard.sh
    ├── 06-validate-cluster.sh      # Health check across the cluster
    ├── 07-install-loki-alloy.sh    # Logging: Loki + Alloy (log collector)
    └── 08-install-prometheus.sh    # Metrics: kube-prometheus-stack
```

Every script has a detailed comment header explaining what it does, why,
and any prerequisites — read those before running, especially if you're
adapting this for your own IPs/hostnames.

---

## Quick Start — Single Node

> ⚠️ Edit the variables at the top of `00-common-setup.sh` and
> `01-init-control-plane.sh` (node IP, hostname) before running — they
> default to this lab's values (`10.0.2.11` / `kube-master`).

```bash
git clone https://github.com/<your-username>/k8s-cilium-hubble-lab.git
cd k8s-cilium-hubble-lab
chmod +x scripts/*.sh

# 1. Common OS/runtime prep — same script used on every node
./scripts/00-common-setup.sh

# 2. Control-plane only: kubeadm init + remove single-node taint
./scripts/01-init-control-plane.sh

# 3. Install Cilium (kube-proxy replacement) + Hubble
./scripts/03-install-cilium.sh

# 4. (Optional) Metrics Server
./scripts/04-install-metrics-server.sh

# 5. (Optional) Kubernetes Dashboard
./scripts/05-install-dashboard.sh

# 6. Validate everything is healthy
./scripts/06-validate-cluster.sh
```

## Quick Start — Multi-Node

Run on **every** node (control-plane and all workers):

```bash
./scripts/00-common-setup.sh   # edit NODE_IP/HOSTNAME per node first
```

Then on the **control-plane only**:

```bash
./scripts/01-init-control-plane.sh
# Set SINGLE_NODE_CLUSTER="false" inside this script for a real multi-node setup
# This prints a `kubeadm join ...` command at the end — copy it
```

On **each worker**, paste the join command into `02-join-worker.sh` and run it:

```bash
./scripts/02-join-worker.sh
```

Back on the **control-plane**, continue with Cilium and the rest:

```bash
kubectl get nodes -o wide   # confirm all workers show up
./scripts/03-install-cilium.sh
./scripts/04-install-metrics-server.sh   # optional
./scripts/05-install-dashboard.sh        # optional
./scripts/06-validate-cluster.sh
```

---

## Observability Stack (Logging + Metrics)

This lab also includes a working logging and metrics pipeline, captured
after several rounds of trial and error (see comments in the values files
for what didn't work and why).

```bash
# Logging: Loki (storage) + Grafana Alloy (per-node log collector)
./scripts/07-install-loki-alloy.sh

# Metrics: kube-prometheus-stack (Prometheus + Operator + node-exporter)
./scripts/08-install-prometheus.sh
```

**Before running**, edit the endpoint URLs in `values/alloy-values.yaml`
(`loki.write` endpoint) and `values/prometheus-values.yaml`
(`remoteWrite` endpoint) to match your own Loki/remote-metrics
destination. This lab originally pointed both at a separate
observability host (`192.168.56.116`) — adjust to wherever your Loki
and remote-write receiver actually live, or remove `remoteWrite` from
the Prometheus values if you only want to query Prometheus directly
in-cluster.

### Why these specific configs

**Loki** runs in `target: all-in-one` mode with local filesystem storage.
The chart's default "scalable" target expects object storage and
separate read/write/backend components — overkill for a single-node lab,
and the actual source of most early failures.

**Alloy** uses `discovery.kubernetes` → `discovery.relabel` →
`loki.source.kubernetes` → `loki.write`. Several alternative component
chains (`loki.process`, `loki.source.file`, `loki.source.podlogs`) were
tried and abandoned — `loki.source.kubernetes` tails pod logs via the
Kubernetes API directly, which is simpler than requiring filesystem
access to container log files on each node.

**Prometheus** (via kube-prometheus-stack) requires
`prometheusOperator.enabled: true` set explicitly — leaving it at the
chart default caused the Prometheus StatefulSet to never reconcile in
testing. Grafana and Alertmanager are disabled since this lab visualizes
everything through an external Grafana instance instead.

### Access points

| Component | How to reach it |
|---|---|
| Alloy (metrics/status) | `http://<node-ip>:31128` |
| Loki | Query via Grafana, or directly: `curl http://<loki-host>:3100/api/prom/label` |
| Prometheus UI | Not exposed by default — see comment in `08-install-prometheus.sh` for the NodePort command |

For the full explanation of every step — including **why** each setting is
used — see [docs/setup-guide.md](docs/setup-guide.md).

---

## Access Points

| Service | Default NodePort | URL |
|---|---|---|
| Hubble UI | 32121 | `http://<node-ip>:32121` |
| Kubernetes Dashboard | 32688 | `https://<node-ip>:32688` |
| Grafana Alloy | 31128 | `http://<node-ip>:31128` |

Get the Dashboard login token:

```bash
kubectl -n kubernetes-dashboard get secret admin-user-token \
  -o jsonpath='{.data.token}' | base64 -d && echo
```

---

## Verifying kube-proxy Replacement

```bash
cilium status --verbose | grep -A10 KubeProxyReplacement
```

Expected:

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

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for fixes to common
issues including:

- Cilium pods stuck in `Pending` (control-plane taint)
- CoreDNS not starting
- NodePort unreachable (UFW / firewall)
- containerd pause image mismatches
- Expired kubeadm join tokens
- Loki "Cannot run scalable target" errors
- Alloy pods running but logs not reaching Loki
- Prometheus StatefulSet never becoming Ready

---

## License

[MIT](LICENSE)

# Read-Only ServiceAccount Guide

A Kubernetes ServiceAccount with **read-only** access to all resources across the entire cluster — can `get/list/watch` everything, but cannot `create/update/delete/patch` anything.

---

## What was created

| Resource | Name | Purpose |
|----------|------|---------|
| `ServiceAccount` | `readonly-sa` (namespace `default`) | The identity |
| `ClusterRole` | `readonly-clusterrole` | Permissions: `get/list/watch` on all resources + all API groups + non-resource URLs |
| `ClusterRoleBinding` | `readonly-sa-binding` | Binds the SA to the ClusterRole cluster-wide |

---

## YAML (`readonly-sa.yaml`)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: readonly-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: readonly-clusterrole
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: readonly-sa-binding
subjects:
  - kind: ServiceAccount
    name: readonly-sa
    namespace: default
roleRef:
  kind: ClusterRole
  name: readonly-clusterrole
  apiGroup: rbac.authorization.k8s.io
```

---

## Deploy

```bash
kubectl apply -f readonly-sa.yaml
```

---

## Generate a kubeconfig for the SA

```bash
# Create the kubeconfig file
kubectl config --kubeconfig=readonly-kubeconfig \
  set-cluster btrc \
  --server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') \
  --insecure-skip-tls-verify=true

kubectl config --kubeconfig=readonly-kubeconfig \
  set-credentials readonly \
  --token=$(kubectl create token readonly-sa -n default)

kubectl config --kubeconfig=readonly-kubeconfig \
  set-context btrc --cluster=btrc --user=readonly

kubectl config --kubeconfig=readonly-kubeconfig \
  use-context btrc
```

This produces a single file `readonly-kubeconfig` that can be copied to any machine.

---

## Usage

### On the master node

```bash
kubectl --kubeconfig=readonly-kubeconfig get pods -A
kubectl --kubeconfig=readonly-kubeconfig get nodes -o wide
kubectl --kubeconfig=readonly-kubeconfig get svc --all-namespaces
kubectl --kubeconfig=readonly-kubeconfig get events -A --sort-by='.lastTimestamp'
```

### On a remote machine

Copy the kubeconfig file and use it:

```bash
scp devopsadmin@192.168.30.165:~/gateway-api-btrc/service-account/readonly-kubeconfig .

kubectl --kubeconfig=readonly-kubeconfig get pods -A
```

Or merge it into your local `~/.kube/config`:

```bash
export KUBECONFIG=readonly-kubeconfig:~/.kube/config
kubectl config view --flatten > merged-config && mv merged-config ~/.kube/config
kubectl config use-context btrc
```

---

## Verify it works

### Allowed (read operations)

```bash
kubectl --kubeconfig=readonly-kubeconfig get pods -A
kubectl --kubeconfig=readonly-kubeconfig get nodes
kubectl --kubeconfig=readonly-kubeconfig get secrets -A
kubectl --kubeconfig=readonly-kubeconfig get crd
kubectl --kubeconfig=readonly-kubeconfig top pods -A
kubectl --kubeconfig=readonly-kubeconfig api-resources
kubectl --kubeconfig=readonly-kubeconfig describe pod -n btrc-test-ns auth-server-...
kubectl --kubeconfig=readonly-kubeconfig logs -n btrc-test-ns deployment/gateway-server
```

### Forbidden (write operations)

```bash
kubectl --kubeconfig=readonly-kubeconfig delete pod -n btrc-test-ns anything
# → Error from server (Forbidden)

kubectl --kubeconfig=readonly-kubeconfig scale deployment -n btrc-test-ns auth-server --replicas=2
# → Error from server (Forbidden)

kubectl --kubeconfig=readonly-kubeconfig apply -f anything.yaml
# → Error from server (Forbidden)

kubectl --kubeconfig=readonly-kubeconfig cordon node-1
# → Error from server (Forbidden)
```

---

## What the ClusterRole covers

| Category | Included |
|----------|----------|
| Core resources (pods, services, nodes, namespaces, secrets, configmaps, etc.) | ✅ all verbs: get/list/watch |
| All API groups (apps, networking, batch, rbac, autoscaling, storage, etc.) | ✅ all verbs: get/list/watch |
| Custom resources (CRDs, CRs) | ✅ all verbs: get/list/watch |
| Non-resource URLs (/api, /healthz, /version, /metrics, etc.) | ✅ all verbs: get/list/watch |
| Subresources (pods/log, pods/exec, pods/status, etc.) | ✅ read-only subresources accessible via `resources: ["*"]` |
| create / update / delete / patch | ❌ explicitly excluded |

---

## Security note

This SA has `get/list/watch` access to **everything**, including:
- `secrets` — can read all secrets in all namespaces
- `cluster-admin` credentials (if stored as secrets)
- ServiceAccount tokens

This is intentional — "same as admin but read-only" means full visibility. If you need to restrict secret access, remove `secrets` from the rules.

---

## Token expiry

`kubectl create token` generates a time-bound token (default 1 hour). For a long-lived token, create a Secret for the SA:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: readonly-sa-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: readonly-sa
type: kubernetes.io/service-account-token
EOF

# Extract the long-lived token
kubectl get secret readonly-sa-token -n default -o jsonpath='{.data.token}' | base64 -d
```

Then regenerate the kubeconfig with that token instead.

---

## Clean up

```bash
kubectl delete -f readonly-sa.yaml
rm readonly-kubeconfig
```

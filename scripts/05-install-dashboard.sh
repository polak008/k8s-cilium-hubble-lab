#!/bin/bash
# ============================================================================
# 05-install-dashboard.sh
#
# PURPOSE
#   Installs the Kubernetes Dashboard (v2.7.0) and exposes it via NodePort,
#   then creates a cluster-admin service account so you can log in.
#
# RUN THIS ON
#   The control-plane node (or anywhere with kubectl access).
#
# WHY v2.7.0 INSTEAD OF THE LATEST (v3 / Helm-based) DASHBOARD
#   The v3 Dashboard ships with a Kong API gateway in front of it, which
#   adds extra moving parts (TLS secrets, gateway routing) that are
#   unnecessary complexity for a lab cluster. v2.7.0 is a single manifest,
#   trivially exposed via NodePort, and was the version validated against
#   this cluster. If you need v3's features, adapt this script to use
#   `helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard`
#   instead.
#
# PREREQUISITE
#   - Cilium is installed and healthy
#   - (Recommended) Metrics Server installed, so the Dashboard's CPU/memory
#     graphs have data to display
#
# SECURITY NOTE
#   This script grants the `admin-user` service account the cluster-admin
#   ClusterRole — full control over the entire cluster. This is fine for a
#   personal lab. For shared or production clusters, scope this down to a
#   namespaced Role with only the permissions actually needed.
#
# USAGE
#   chmod +x 05-install-dashboard.sh
#   ./05-install-dashboard.sh
# ============================================================================
set -euxo pipefail

DASHBOARD_NODEPORT="32688"

# ---------------------------------------------------------------------------
# 1. Deploy the Dashboard
# ---------------------------------------------------------------------------
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# ---------------------------------------------------------------------------
# 2. Wait for it to come up
# ---------------------------------------------------------------------------
kubectl wait --for=condition=available --timeout=180s \
  deployment/kubernetes-dashboard -n kubernetes-dashboard

# ---------------------------------------------------------------------------
# 3. Expose via NodePort
# ---------------------------------------------------------------------------
# The default manifest creates a ClusterIP service, which is only reachable
# from inside the cluster. Patching it to NodePort makes it reachable at
# https://<any-node-ip>:32688 from outside the cluster too.
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard \
  -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"nodePort\":${DASHBOARD_NODEPORT}}]}}"

# ---------------------------------------------------------------------------
# 4. Create an admin login (ServiceAccount + ClusterRoleBinding + token)
# ---------------------------------------------------------------------------
# The Dashboard's login screen accepts a bearer token tied to a
# ServiceAccount. We create one with cluster-admin so it can see/manage
# everything in the cluster.
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

# ---------------------------------------------------------------------------
# 5. Print the login token
# ---------------------------------------------------------------------------
echo ""
echo "=== Dashboard ready at https://<node-ip>:${DASHBOARD_NODEPORT} ==="
echo "(Your browser will warn about the self-signed certificate — this is expected for a lab cluster.)"
echo ""
echo "Login token:"
kubectl -n kubernetes-dashboard get secret admin-user-token \
  -o jsonpath='{.data.token}' | base64 -d && echo

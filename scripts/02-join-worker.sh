#!/bin/bash
# ============================================================================
# 02-join-worker.sh
#
# PURPOSE
#   Joins a worker node to the cluster. WORKER NODES ONLY — never run this
#   on the control-plane.
#
# PREREQUISITE
#   00-common-setup.sh must have already completed successfully on this
#   worker node.
#
# USAGE
#   The control-plane's 01-init-control-plane.sh script prints a
#   `kubeadm join ...` command at the end of its output. Copy that exact
#   command and run it here, OR paste it into the JOIN_COMMAND variable
#   below and run this script.
#
#   If the original token has expired (tokens are valid for 24 hours by
#   default), regenerate one on the control-plane with:
#     kubeadm token create --print-join-command
# ============================================================================
set -euxo pipefail

# ---------------------------------------------------------------------------
# EDIT THIS — paste the full join command from the control-plane's output
# ---------------------------------------------------------------------------
JOIN_COMMAND='sudo kubeadm join 10.0.2.11:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>'

# ---------------------------------------------------------------------------
# Run it
# ---------------------------------------------------------------------------
eval "$JOIN_COMMAND"

echo ""
echo "=== Worker joined. Verify from the control-plane with: ==="
echo "  kubectl get nodes -o wide"

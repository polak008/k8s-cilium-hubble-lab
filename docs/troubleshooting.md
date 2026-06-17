# Troubleshooting

## Cilium agent not starting

```bash
kubectl logs -n kube-system -l k8s-app=cilium
```

## Cilium pods stuck in Pending

Most likely cause on a single-node cluster: control-plane taint not removed.

```bash
kubectl describe nodes | grep -A5 Taints
# If you see node-role.kubernetes.io/control-plane:NoSchedule, run:
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Hubble Relay not connecting

```bash
cilium status | grep Hubble
kubectl logs -n kube-system -l k8s-app=hubble-relay
```

## NodePort not reachable

```bash
# Check Cilium kube-proxy replacement status
cilium status | grep -A10 KubeProxyReplacement

# Check the port is bound
sudo ss -tlnp | grep <nodeport>

# Check UFW is not blocking
sudo ufw status
```

## CoreDNS not starting

CoreDNS requires Cilium to be running first. Wait for the Cilium DaemonSet to
be fully ready, then CoreDNS should self-heal. If not:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

## Missing kernel features for eBPF

```bash
# Verify BTF is present (required for Cilium eBPF datapath)
ls /sys/kernel/btf/vmlinux
```

If missing, Cilium falls back to the legacy `tc` datapath instead of `xdp` —
functionality is preserved but performance is reduced.

## kubeadm join token expired (multi-node)

Tokens expire after 24 hours by default. Regenerate on the control-plane:

```bash
kubeadm token create --print-join-command
```

## containerd / kubelet pause image mismatch

If pods are stuck in `ContainerCreating` with image pull errors related to `pause`:

```bash
# Verify both config files use the same version
grep sandbox_image /etc/containerd/config.toml
grep pause /var/lib/kubelet/kubeadm-flags.env
# Both should reference registry.k8s.io/pause:3.10.1
```

## Loki: "Cannot run scalable target" error

This means the chart is using its default scalable target, which expects
object storage and separate read/write/backend pods. Use
`values/loki-values.yaml` (`target: all-in-one`, `storage.type:
filesystem`) instead — see comments in that file.

## Alloy pod running but no logs reaching Loki

Check Alloy's own logs for delivery errors first:

```bash
kubectl logs -n alloy-system -l app.kubernetes.io/name=alloy --tail=50
```

Common causes:
- The `loki.write` endpoint URL in `values/alloy-values.yaml` doesn't
  match where Loki is actually reachable from inside the cluster (in
  particular, an external IP that's unreachable from pod network).
- Using `loki.source.file` instead of `loki.source.kubernetes` — the
  former needs direct filesystem access to container logs and is more
  fragile in containerized environments. Use `loki.source.kubernetes`.

Confirm Loki itself is receiving data:

```bash
curl http://<loki-host>:3100/api/prom/label
```

## Prometheus StatefulSet never becomes Ready

Confirm `prometheusOperator.enabled: true` is explicitly set in your
values file — leaving it at the chart default has caused this exact
symptom in testing. See `values/prometheus-values.yaml`.

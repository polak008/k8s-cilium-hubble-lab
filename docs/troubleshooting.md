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

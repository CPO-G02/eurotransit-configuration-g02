# Chaos Dashboard experiment readiness

Date: 2026-07-16

This document records the repository and live-cluster readiness review for
running EuroTransit resilience experiments from the Chaos Mesh Dashboard.

No experiment was executed during this review.

After this readiness review, the Inventory `PodChaos` pod-kill recovery path was
executed once from the Chaos Dashboard. The execution evidence is recorded in
`docs/resilience/inventory-pod-kill-chaos-report.md`.

## Validation summary

All experiment manifests under `platform/chaos-mesh/experiments` now validate
against the installed Chaos Mesh CRDs with server-side dry-run:

```bash
for f in platform/chaos-mesh/experiments/*.yaml; do
  kubectl apply --dry-run=server -f "$f"
done
```

Validated resources:

```text
podchaos.chaos-mesh.org/cnpg-inventory-primary-pod-kill created (server dry run)
podchaos.chaos-mesh.org/inventory-pod-kill created (server dry run)
networkchaos.chaos-mesh.org/kafka-network-partition created (server dry run)
networkchaos.chaos-mesh.org/orders-inventory-network-failure created (server dry run)
networkchaos.chaos-mesh.org/orders-payments-network-latency created (server dry run)
networkchaos.chaos-mesh.org/payments-gateway-network-latency created (server dry run)
```

The previous suspended `Schedule` form is not compatible with the currently
installed Chaos Mesh CRD because `spec.suspend` is rejected by strict decoding.
The repository therefore uses manual one-shot `NetworkChaos` and `PodChaos`
objects. They must be imported or applied only when the team is ready to start a
run.

## Current platform state

Chaos Mesh:

```text
chaos-controller-manager   1/1 Running
chaos-dashboard            1/1 Running
chaos-daemon               DESIRED=0 READY=0
```

No nodes currently have `sleep=true`, so `chaos-daemon` is idle.

Monitoring:

```text
kube-prometheus-stack-grafana                1/1
kube-prometheus-stack-kube-state-metrics     1/1
kube-prometheus-stack-operator               1/1
prometheus-kube-prometheus-stack-prometheus   0/0
alertmanager-kube-prometheus-stack-alertmanager 0/0
```

Prometheus must be scaled to `1` before collecting PromQL/Grafana evidence.
Alertmanager is optional unless alert firing is part of the evidence.

## Workload placement

Live selector checks on 2026-07-16:

```text
orders                 aks-cloudlab02-33508055-vms27
payment-gateway-sim    aks-cloudlab02-33508055-vms27
payments               aks-cloudlab02-33508055-vms28
inventory              aks-cloudlab02-33508055-vms28
inventory-db primary   aks-cloudlab02-33508055-vms28
kafka broker 0         aks-cloudlab02-33508055-vms29
kafka broker 1         aks-cloudlab02-33508055-vms27
kafka broker 2         aks-cloudlab02-33508055-vms28
```

## Dashboard execution model

The Dashboard can import these one-shot YAML objects. Creating/importing a
`NetworkChaos` or `PodChaos` object starts the fault immediately, so do not
create the object until:

- baseline metrics are captured;
- the required `sleep=true` node labels are applied;
- `chaos-daemon` is Ready on every required node;
- k6/load generation is ready;
- rollback commands are prepared.

## Daemon scheduling strategy

The live `chaos-daemon` DaemonSet has:

```yaml
nodeSelector:
  sleep: "true"
```

Use `sleep=true` as a temporary validation-window gate:

1. Label only the nodes required by the specific experiment.
2. Wait for `chaos-daemon` to become Ready on those nodes.
3. Run one experiment.
4. Delete the chaos object.
5. Remove the `sleep` labels.

Commands:

```bash
kubectl label node <node> sleep=true
kubectl -n chaos-mesh rollout status daemonset/chaos-daemon --timeout=120s
kubectl -n chaos-mesh get daemonset chaos-daemon
kubectl -n chaos-mesh get pods -o wide

kubectl label node <node> sleep-
kubectl -n chaos-mesh get daemonset chaos-daemon
```

Important: `kube-prometheus-stack-prometheus-node-exporter` currently also uses
`sleep=true`, so labeling a node starts both `chaos-daemon` and node-exporter on
that node. Keep the label window short.

## Experiment readiness matrix

| Experiment | Manifest | Status | Required `sleep=true` nodes | Notes |
| --- | --- | --- | --- | --- |
| Payments -> gateway latency | `payments-gateway-network-latency.yaml` | Ready after Prometheus is running | `vms28`, `vms27` | Source Payments on `vms28`, target gateway simulator on `vms27`. |
| Orders -> Payments latency | `orders-payments-network-latency.yaml` | Ready after Prometheus is running | `vms27`, `vms28` | Source Orders on `vms27`, target Payments on `vms28`. |
| Inventory pod kill | `inventory-pod-kill.yaml` | Infrastructure recovery PASS; full business invariant proof still needs load and database checks | `vms28` | Target Inventory pod is on `vms28`. See `inventory-pod-kill-chaos-report.md`. |
| CNPG Inventory primary pod kill | `cnpg-primary-pod-kill.yaml` | Ready after Prometheus is running | `vms28` | Live Inventory primary currently runs in namespace `eurotransit` on `vms28`. |
| Kafka network partition | `kafka-network-partition.yaml` | Heavy; run late | `vms27`, `vms28`, `vms29` | Kafka brokers and selected app pods span all three nodes. |
| Orders -> Inventory partition | `orders-inventory-network-failure.yaml` | Ready after verifying deployed Orders timeout implementation | `vms27`, `vms28` | Use only with controlled load; partition drops packets and depends on Orders timeout enforcement. |
| Node/PDB disruption | `node-disruption-runbook.md` | Blocked for live proof with current replicas | none | Current critical-service PDBs have `ALLOWED DISRUPTIONS=0` with one replica. |

## Current blockers

- Prometheus is still scaled to `0/0`; Grafana will not have queryable evidence
  until Prometheus is running.
- Experiments requiring `vms27` currently need a small amount of requested-memory
  headroom before the `chaos-daemon` pod can schedule there. A previous targeted
  label attempt produced `Insufficient memory` for the `vms27` daemon pod.
- The Kafka partition requires daemons on all three nodes and should be delayed
  until lighter experiments are complete.
- The node/PDB disruption proof is blocked while Orders, Inventory, and Payments
  have one replica and PDB `minAvailable: 1`.

## Per-experiment checklist

Before:

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl get pods -n eurotransit -o wide
kubectl get pdb -A
kubectl get hpa -A
kubectl get networkchaos,podchaos,schedule -A
kubectl -n chaos-mesh get pods,daemonset
```

Enable Prometheus evidence:

```bash
kubectl -n monitoring scale statefulset prometheus-kube-prometheus-stack-prometheus --replicas=1
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=180s
```

Enable daemons only for the selected experiment:

```bash
kubectl label node <required-node> sleep=true
kubectl -n chaos-mesh rollout status daemonset/chaos-daemon --timeout=120s
```

After:

```bash
kubectl -n chaos-mesh delete networkchaos --all
kubectl -n chaos-mesh delete podchaos --all
kubectl get networkchaos,podchaos,schedule -A
kubectl label node <required-node> sleep-
kubectl -n chaos-mesh get daemonset chaos-daemon
kubectl -n eurotransit get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName
```

Required authentication:

- k6 order/load scripts require a valid Orders-audience bearer token.
- Do not store tokens in Git.

Required monitoring:

- Grafana dashboard: Kubernetes / Compute Resources / Namespace (Pods).
- Grafana dashboard: Kubernetes / Compute Resources / Workload.
- Grafana dashboard: Kubernetes / Compute Resources / Node.
- PromQL for Resilience4j state/calls, HTTP status rate, latency histogram, and
  pod restarts.

Final cleanup:

```bash
kubectl get nodes -l sleep=true
kubectl get networkchaos,podchaos,schedule -A
kubectl -n chaos-mesh get daemonset chaos-daemon
```

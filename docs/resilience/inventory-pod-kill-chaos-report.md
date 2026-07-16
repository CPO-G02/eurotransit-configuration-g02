# Inventory Pod Kill Chaos Report

Date: 2026-07-16

Status: PASS, cleanup still required

## Objective

Validate Experiment 2 from `docs/chaos-experiment-hypotheses.md`: killing one
Inventory pod during the validation window must not leave Inventory unavailable.
The service should recover through the Kubernetes Deployment controller, and the
replacement pod should become Ready without manual application changes.

## Hypothesis

The Chaos Mesh `PodChaos` `pod-kill` fault deletes one Inventory pod. Kubernetes
creates a replacement pod for the Inventory Deployment. Inventory returns to
`Ready` state, and the experiment completes without causing a persistent service
failure.

The business-level hypothesis for the full experiment remains: under active
reservation load, Inventory's transaction and idempotency handling prevent
oversell or duplicate reservations when a pod dies mid-reservation.

## Environment

- Cluster: AKS `Lab02cluster`
- Application namespace: `eurotransit`
- Chaos namespace: `chaos-mesh`
- Target service: Inventory
- Target selector:

```yaml
app.kubernetes.io/name: inventory
app.kubernetes.io/instance: eurotransit
```

- Target node observed during the run:
  `aks-cloudlab02-33508055-vms28`
- Required Chaos Mesh daemon scope for this run:
  `sleep=true` only on the Inventory node

## Fault Injected

Chaos Mesh resource:
`platform/chaos-mesh/experiments/inventory-pod-kill.yaml`

Fault type:

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
spec:
  action: pod-kill
  mode: one
```

This is a one-shot pod kill. No `duration` is required for this action because
the pod is deleted once and then recreated by the Deployment controller.

## Execution Steps

1. Confirm Inventory pod placement:

```bash
kubectl -n eurotransit get pods -l app.kubernetes.io/name=inventory -o wide
```

2. Enable Chaos Mesh daemon only on the Inventory node:

```bash
kubectl label node aks-cloudlab02-33508055-vms28 sleep=true
kubectl -n chaos-mesh get daemonset chaos-daemon
kubectl -n chaos-mesh get pods -o wide
```

3. Watch Inventory pod lifecycle:

```bash
kubectl -n eurotransit get pods -w
```

4. Import and start `inventory-pod-kill.yaml` from the Chaos Dashboard.

5. Verify the Dashboard reports the experiment as `Completed`.

6. Verify the replacement Inventory pod becomes `Ready`.

## Expected Behaviour

- Chaos Dashboard shows `inventory-pod-kill` completed.
- The selected Inventory pod transitions to `Terminating`.
- Kubernetes creates a replacement Inventory pod.
- The replacement pod transitions through `Pending`, `ContainerCreating`,
  `Running`, and then `Ready`.
- Inventory returns to one available pod.
- No manual application deployment change is required.
- After evidence collection, the `PodChaos` object is deleted and the
  `sleep=true` node label is removed.

## Observed Behaviour

Chaos Dashboard showed the pod fault as completed:

```text
inventory-pod-kill Completed
Namespace: chaos-mesh
UUID: c3851260-11e6-471f-9b3b-35405ba68271
Created at: 2026-07-16 20:10:36 PM
Scope namespace: eurotransit
Kind: PodChaos
Action: pod-kill
Run duration display: Run continuously
```

Dashboard scope and selector evidence:

```text
Namespace Selectors:
  eurotransit
Label Selectors:
  app.kubernetes.io/instance: eurotransit
  app.kubernetes.io/name: inventory
```

Dashboard event timeline:

```text
inventory-pod-kill   Finalizer has been inited
inventory-pod-kill   Successfully update finalizer of resource
inventory-pod-kill   Successfully update desiredPhase of resource
inventory-pod-kill   Successfully apply chaos for eurotransit/eurotransit-inventory-84cfcc48cb-vb86h
inventory-pod-kill   Successfully update records of resource
```

Dashboard definition summary:

```yaml
kind: PodChaos
apiVersion: chaos-mesh.org/v1alpha1
metadata:
  namespace: chaos-mesh
  name: inventory-pod-kill
  labels:
    app.kubernetes.io/name: chaos-experiment
    app.kubernetes.io/part-of: eurotransit
    eurotransit.io/experiment: inventory-pod-kill
  annotations:
    eurotransit.io/auto-execute: "false"
    eurotransit.io/status: manual
spec:
  selector:
    namespaces:
      - eurotransit
    labelSelectors:
      app.kubernetes.io/instance: eurotransit
      app.kubernetes.io/name: inventory
  mode: one
  action: pod-kill
```

The pod watch captured the expected lifecycle:

```text
eurotransit-inventory-84cfcc48cb-vb86h   1/1   Running             0   168m
eurotransit-inventory-84cfcc48cb-vb86h   1/1   Terminating         0   168m
eurotransit-inventory-84cfcc48cb-vb86h   1/1   Terminating         0   168m
eurotransit-inventory-84cfcc48cb-nvx2m   0/1   Pending             0   0s
eurotransit-inventory-84cfcc48cb-nvx2m   0/1   Pending             0   0s
eurotransit-inventory-84cfcc48cb-nvx2m   0/1   ContainerCreating   0   0s
eurotransit-inventory-84cfcc48cb-nvx2m   0/1   Running             0   2s
eurotransit-inventory-84cfcc48cb-nvx2m   0/1   Running             0   25s
eurotransit-inventory-84cfcc48cb-nvx2m   1/1   Running             0   25s
```

Post-run read-only check confirmed the replacement Inventory pod was Ready:

```text
NAME                                     READY   STATUS    RESTARTS   AGE     NODE
eurotransit-inventory-84cfcc48cb-nvx2m   1/1     Running   0          6m32s   aks-cloudlab02-33508055-vms28
```

Post-run read-only check also showed that cleanup had not yet been completed:

```text
NAMESPACE    NAME                                         AGE
chaos-mesh   podchaos.chaos-mesh.org/inventory-pod-kill   6m32s
```

```text
NAME                            STATUS   ROLES    AGE   VERSION
aks-cloudlab02-33508055-vms28   Ready    <none>   33h   v1.33.7
```

The node still matched `sleep=true`, and `chaos-daemon` was still scheduled on
that single node:

```text
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
chaos-daemon   1         1         1       1            1           sleep=true
```

## Evidence

- Chaos Dashboard: `inventory-pod-kill` completed.
- Chaos Dashboard metadata: UUID
  `c3851260-11e6-471f-9b3b-35405ba68271`, created at
  `2026-07-16 20:10:36 PM`.
- Chaos Dashboard events: finalizer initialized, desired phase updated, chaos
  applied to `eurotransit/eurotransit-inventory-84cfcc48cb-vb86h`, records
  updated.
- Kubernetes pod lifecycle: old Inventory pod moved from `Running` to
  `Terminating`.
- Kubernetes scheduler created replacement pod
  `eurotransit-inventory-84cfcc48cb-nvx2m`.
- Replacement pod progressed through `Pending`, `ContainerCreating`, `Running`,
  and `Ready`.
- Replacement pod was observed as `1/1 Running` on
  `aks-cloudlab02-33508055-vms28`.
- Chaos Mesh daemon was scoped to one node through the temporary `sleep=true`
  label.

## Result

PASS.

The infrastructure-level recovery path worked: Chaos Mesh killed the Inventory
pod, the Dashboard marked the fault completed, Kubernetes created a replacement
pod, and Inventory returned to `Ready`.

This report does not claim the full business invariant proof unless the run was
paired with reservation load and database checks for oversell and duplicate
idempotency records. Those checks should be attached to this report when they
are executed.

## Rollback / Cleanup Steps

Delete the completed `PodChaos` object:

```bash
kubectl -n chaos-mesh delete podchaos inventory-pod-kill
kubectl get podchaos,networkchaos,schedule -A
```

Remove the temporary node label:

```bash
kubectl label node aks-cloudlab02-33508055-vms28 sleep-
kubectl get nodes -l sleep=true
kubectl -n chaos-mesh get daemonset chaos-daemon
```

Expected cleanup state:

- no `inventory-pod-kill` `PodChaos` object remains;
- no node remains labeled `sleep=true` unless another experiment is being
  prepared;
- `chaos-daemon` scales back to `DESIRED=0` when no nodes match the selector.

## Lessons Learned / Notes

- `pod-kill` is a one-shot action, so an empty Dashboard `Duration` field is
  expected and does not indicate a YAML problem.
- `Grace period: 0` means immediate pod deletion. That is appropriate for this
  failure-mode test because it validates abrupt Inventory loss.
- Labeling only the Inventory node kept Chaos Mesh daemon scope minimal for this
  experiment.
- Cleanup is part of the experiment. Leaving `PodChaos` objects or `sleep=true`
  node labels behind can confuse later runs and keep Chaos Mesh daemon resources
  active.
- To close the full DoD item for Experiment 2, repeat or extend the run under
  approved reservation load and capture database evidence that there is no
  oversell and no duplicate reservation for the same idempotency key.

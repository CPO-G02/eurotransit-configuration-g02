# Experiment 5: CloudNativePG Primary Failover — Chaos Report

Date: 2026-07-16

Status: PASS

## 1. Objective

Validate that killing the CloudNativePG primary pod of the `inventory-db`
cluster triggers automatic failover. The CloudNativePG operator must promote
the surviving standby to primary, recreate the missing instance as a replica,
and return the cluster to a healthy two-instance state — all without manual
PostgreSQL promotion or manual pod creation.

## 2. Hypothesis

Deleting the `inventory-db` primary pod causes CloudNativePG to:

- detect the primary failure through its reconciliation loop;
- promote the surviving standby to primary;
- update `Cluster.status.currentPrimary` to the promoted pod;
- switch the `inventory-db-rw` service endpoint to the new primary;
- recreate the killed instance as a replica;
- return the cluster to `readyInstances=2` and `phase="Cluster in healthy state"`.

Services may see transient database connection errors during failover, but
recover automatically without manual pod restarts or committed data loss.

## 3. Environment

- Cluster: AKS `Lab02cluster`
- Application namespace: `eurotransit`
- Chaos namespace: `chaos-mesh`
- CNPG operator: `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0` in namespace
  `cnpg-system`
- Target cluster: `inventory-db` (`spec.instances: 2`, image
  `ghcr.io/cloudnative-pg/postgresql:17`)
- Chaos Mesh manifest:
  `platform/chaos-mesh/experiments/cnpg-primary-pod-kill.yaml`
- Fault type: `PodChaos`, `action: pod-kill`, `mode: one`, `gracePeriod: 1`
- Selector:

```yaml
labelSelectors:
  cnpg.io/cluster: inventory-db
  cnpg.io/instanceRole: primary
```

## 4. Experiment Execution

### 4.1. Failed Attempt — Operator Scaled to Zero

During the initial attempt, the Chaos Mesh `PodChaos` experiment killed the
primary pod (`inventory-db-1`). The following symptoms were observed:

- Only `inventory-db-2` remained running.
- `Cluster.status.currentPrimary` still reported `inventory-db-1` (stale).
- The surviving pod was not promoted to primary.
- No replacement replica was created.
- The cluster did not recover.

Root cause investigation determined that the CloudNativePG operator deployment
(`cnpg-cloudnative-pg`) was scaled to `replicas: 0`. Without the operator
running, no reconciliation loop executed, and no failover was possible. This is
consistent with the CNPG architecture: the operator is the sole component that
performs primary election and instance lifecycle management. Standby instances
cannot self-promote.

### 4.2. Operator Restoration

The operator was restored:

```bash
kubectl -n cnpg-system scale deployment cnpg-cloudnative-pg --replicas=1
```

```text
deployment.apps/cnpg-cloudnative-pg scaled
```

The operator started and immediately detected the stale cluster state. Operator
logs confirmed the failover sequence:

```text
"msg":"There is a switchover or a failover in progress, waiting for the operation to complete"
"currentPrimary":"inventory-db-1","targetPrimary":"inventory-db-2"
```

```text
"msg":"Old primary pod not found in managed instances, skipping label demotion"
"oldPrimary":"inventory-db-1"
```

```text
"msg":"Cluster has become healthy"
```

The operator autonomously promoted `inventory-db-2` to primary and recreated
`inventory-db-1` as a replica. No manual intervention was required.

### 4.3. Successful Experiment

After the cluster was restored to a healthy state (2/2 Ready), the Chaos Mesh
experiment was repeated with the corrected manifest. Pre-flight checks
confirmed:

- CNPG operator: `readyReplicas=1`.
- `inventory-db` had 2 Running pods.
- `inventory-db-2` was the current primary (promoted during the recovery).
- Cluster phase: `"Cluster in healthy state"`.

The `PodChaos` experiment killed `inventory-db-2` (the current primary).

CloudNativePG automatically:

- promoted `inventory-db-1` to primary;
- recreated `inventory-db-2` as a replica;
- updated `Cluster.status.currentPrimary` to `inventory-db-1`;
- returned the cluster to `readyInstances=2` and
  `phase="Cluster in healthy state"`.

No manual PostgreSQL promotion or manual replica creation was required.

## 5. Observations

### 5.1. Observed Facts

| Observation | Value |
| --- | --- |
| Pod killed | `inventory-db-2` |
| Pod promoted to primary | `inventory-db-1` |
| Pod recreated as replica | `inventory-db-2` |
| `status.currentPrimary` after failover | `inventory-db-1` |
| `status.readyInstances` after recovery | `2` |
| `status.phase` after recovery | `Cluster in healthy state` |
| Manual promotion required | No |
| Manual replica creation required | No |

### 5.2. Label Evidence

CNPG v1.30.0 was confirmed to populate both the canonical `cnpg.io/instanceRole`
label and the deprecated `role` label on every pod:

| Pod | `cnpg.io/instanceRole` | `role` (deprecated) |
| --- | --- | --- |
| `inventory-db-1` (primary) | `primary` | `primary` |
| `inventory-db-2` (replica) | `replica` | `replica` |

The experiment manifest uses `cnpg.io/instanceRole: primary` as the selector.
The deprecated `role` label is still present in v1.30.0 for backward
compatibility but will be removed in a future operator version.

### 5.3. Failed Attempt Root Cause

The initial failed attempt was caused by the CNPG operator deployment being
scaled to `replicas: 0`. This fully explains all observed failure symptoms:

| Symptom | Explanation |
| --- | --- |
| Replica not promoted | The operator's reconciliation loop performs primary election; without the operator, no election occurs |
| No replacement instance created | The operator manages the pod lifecycle to maintain `spec.instances`; without the operator, no new pod is created |
| `status.currentPrimary` not updated | The operator writes the `status` subresource; without the operator, status remains stale |

No other root cause was identified or needed. Once the operator was restored,
automatic failover completed without any additional changes.

## 6. Results

**PASS.**

The CloudNativePG automated failover mechanism worked as designed:

1. The operator detected the primary pod failure.
2. The surviving standby was promoted to primary.
3. The killed instance was recreated as a replica.
4. The cluster returned to full health with 2 Ready instances.
5. No manual intervention was required for promotion or replica creation.

## 7. Validation

Each validation check and its result:

### 7.1. Primary pod promoted

```bash
kubectl get pods -n eurotransit \
  -l cnpg.io/cluster=inventory-db,cnpg.io/instanceRole=primary -o name
```

```text
pod/inventory-db-1
```

Confirmed: exactly one primary, different from the killed pod (`inventory-db-2`).

### 7.2. Cluster status currentPrimary updated

```bash
kubectl get cluster inventory-db -n eurotransit \
  -o jsonpath='{.status.currentPrimary}'
```

```text
inventory-db-1
```

Confirmed: `currentPrimary` matches the promoted pod.

### 7.3. Replica recreated

```bash
kubectl get pods -n eurotransit \
  -l cnpg.io/cluster=inventory-db,cnpg.io/instanceRole=replica -o name
```

```text
pod/inventory-db-2
```

Confirmed: exactly one replica. The killed pod was recreated automatically by
the CNPG operator.

### 7.4. Ready instance count

```bash
kubectl get cluster inventory-db -n eurotransit \
  -o jsonpath='{.status.readyInstances}'
```

```text
2
```

Confirmed: the cluster returned to 2 Ready instances.

### 7.5. Cluster phase

```bash
kubectl get cluster inventory-db -n eurotransit \
  -o jsonpath='{.status.phase}'
```

```text
Cluster in healthy state
```

Confirmed: the cluster completed reconciliation and is healthy.

### 7.6. Inventory-db pod state

```bash
kubectl get pods -n eurotransit -l cnpg.io/cluster=inventory-db -o wide
```

```text
NAME             READY   STATUS    RESTARTS
inventory-db-1   1/1     Running   0
inventory-db-2   1/1     Running   0
```

Confirmed: both pods are 1/1 Running with zero restarts.

### 7.7. RW service endpoint

```bash
kubectl get endpoints inventory-db-rw -n eurotransit
```

Confirmed: the `inventory-db-rw` endpoint points to the new primary pod IP
(`inventory-db-1`).

## 8. Conclusion

Experiment 5 validates that the CloudNativePG automated failover mechanism
correctly handles primary pod failure for the `inventory-db` cluster.

The initial failed attempt revealed a critical pre-condition: the CNPG operator
must be running. Without the operator, failover cannot occur because CNPG does
not support autonomous standby self-promotion. This finding led to the addition
of a pre-flight check (operator `readyReplicas >= 1`) in the experiment
manifest.

Once the operator was running, the failover completed automatically: the
surviving standby was promoted, the missing instance was recreated as a replica,
and the cluster returned to full health. No manual PostgreSQL commands, no
manual label changes, and no manual pod creation were required.

### Manifest changes applied during this experiment

The experiment manifest
(`platform/chaos-mesh/experiments/cnpg-primary-pod-kill.yaml`) was updated:

1. **Selector**: `role: primary` replaced with `cnpg.io/instanceRole: primary`
   (canonical CNPG label since v1.18; the deprecated `role` label will be
   removed in a future operator version).
2. **`gracePeriod`**: set to `1` per CNPG documentation, which recommends
   against `--grace-period=0` for failover testing.
3. **Pre-flight checks**: added operator readiness check, pod count check,
   primary identification, and cluster health check.
4. **Post-fault validation**: extended from informal recovery confirmation to
   an eight-step checklist covering promotion, status update, service endpoint,
   replica recreation, ready instance count, liveness churn, and cluster phase.

### Remaining work

- This report covers infrastructure-level failover validation. Full business
  invariant proof (no committed data loss, no duplicate reservations, no
  oversell) requires repeating the experiment under active checkout load with
  database-level evidence. That evidence should be attached to this report when
  collected.
- Investigate why the CNPG operator was scaled to zero and whether any
  controller, GitOps reconciler, or resource constraint is responsible, to
  prevent recurrence.

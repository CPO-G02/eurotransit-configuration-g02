# node-disruption-pdb-validation

## Objective
Validate the resilience of critical path services (Orders, Inventory, Payments) under node disruption, specifically confirming that PodDisruptionBudgets prevent voluntary eviction from violating the configured minimum availability limits.

## Hypothesis
If an AKS worker node is cordoned and drained while the workload generator is running, the PodDisruptionBudgets for the critical-path services will block the eviction of replicas if it violates the configured minimum available limit (`minAvailable: 1`), ensuring continuous availability of checkout traffic.

## Environment
* **Platform**: Kubernetes (Azure AKS)
* **Nodes**:
  * `aks-cloudlab02-33508055-vms27` (Ready)
  * `aks-cloudlab02-33508055-vms28` (Ready, cordoned/drained during test)
  * `aks-cloudlab02-33508055-vms29` (Ready)
* **Target Services**:
  * `eurotransit-orders` (PDB: `eurotransit-orders`, minAvailable: 1)
  * `eurotransit-inventory` (PDB: `eurotransit-inventory`, minAvailable: 1)
  * `eurotransit-payments` (PDB: `eurotransit-payments`, minAvailable: 1)

## Experiment Configuration
* **Name**: `node-disruption-pdb-validation`
* **Trigger Mechanism**: Manual `kubectl cordon` and `kubectl drain` node operations.
* **Cordoned/Drained Node**: `aks-cloudlab02-33508055-vms28`

## Execution
1. Verified the target services (`orders`, `inventory`, `payments`) were scaled to 2 replicas each, ensuring `ALLOWED DISRUPTIONS` = 1.
2. Initiated the continuous checkout load generator (`load.py`) at a rate of 1 request per second.
3. Cordoned `aks-cloudlab02-33508055-vms28` using `kubectl cordon` to prevent new scheduling.
4. Triggered the node drain command: `kubectl drain aks-cloudlab02-33508055-vms28 --ignore-daemonsets --delete-emptydir-data --timeout=10m`.
5. Monitored the pod rescheduling, PDB allowed disruptions, and eviction logs.
6. Cancelled the blocked drain command once the PDB eviction block was verified.
7. Uncordoned `aks-cloudlab02-33508055-vms28`.
8. Reverted replica configurations of services and database clusters to their GitOps-approved values.
9. Stopped the load generator.

## Evidence
* **Kubectl Drain Event Logs**: The drain command outputted the following logs showing PDB blocks:
  * `Cannot evict pod as it would violate the pod's disruption budget.` for `eurotransit-inventory-84cfcc48cb-sgzl7` (Inventory PDB).
  * `Cannot evict pod as it would violate the pod's disruption budget.` for CNPG database primary pods `orders-db-1` and `inventory-db-1`.
* **Pod scheduling status**:
  * `eurotransit-inventory-84cfcc48cb-xxjmh` (the evicted replica rescheduled to another node) remained in `Pending` state due to `0/3 nodes are available: 1 Insufficient cpu, 1 node(s) were unschedulable, 2 Insufficient memory.` scheduler events.
  * The second replica `eurotransit-inventory-84cfcc48cb-sgzl7` remained in `Running` state on the cordoned node `aks-cloudlab02-33508055-vms28`.
* **Load generator logs**:
  * The load generator recorded successful order creation (HTTP `Status: 202`) throughout the node drain attempt, processing 38 sequential orders without interruption.
* **Orders application logs**:
  * The logs recorded a transient `inventory-client` circuit breaker state transition to `OPEN` (with `CircuitBreaker 'inventory-client' is OPEN and does not permit further calls` log errors) during the eviction of the first inventory pod.

## Observations
* Network/Node chaos reached expected state with `aks-cloudlab02-33508055-vms28` cordoned.
* The experiment remained active for the duration of the manual testing window.
* All components recovered successfully after the node was uncordoned and deployments scaled back.
* Orders continued processing checkout requests, successfully returning HTTP 202 status codes.
* One replica of `eurotransit-inventory` remained running on `aks-cloudlab02-33508055-vms28` and was protected from eviction.
* The `kubectl drain` command blocked and continually retried eviction of the remaining inventory pod and database primaries.
* CNPG cluster primary pods were blocked from eviction by their respective PDB budgets (`orders-db-primary`, `inventory-db-primary`).

## Analysis
The experiment successfully demonstrated the expected PodDisruptionBudget protection mechanism. By keeping at least one ready replica of the inventory service running on the cordoned node while the newly created replica was stuck scheduling, the disruption budget protected the system from a complete service outage.

## Result
PASS

## Lessons Learned
This experiment demonstrates that although PodDisruptionBudgets protect service availability during node maintenance operations (such as drains), their success depends on cluster capacity. If the cluster lacks spare resources to host evicted replicas on other nodes, the drain command will hang indefinitely. Future work should verify that cluster capacity planning accounts for the additional resources required during node maintenance evictions.

## Evidence Summary
| Evidence | Result |
| :--- | :--- |
| Load Generator Status | HTTP 202 (uninterrupted) |
| PodDisruptionBudget Eviction Block | Verified (`Cannot evict pod...`) |
| Inventory Service Replica Status | 1 pod kept ready on drained node |
| orders-db-1 Eviction | Blocked by `orders-db-primary` PDB |
| inventory-db-1 Eviction | Blocked by `inventory-db-primary` PDB |
| kubectl drain output status | Blocked / Hung on PDB violations |

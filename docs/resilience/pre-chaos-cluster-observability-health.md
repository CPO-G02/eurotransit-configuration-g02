# Pre-chaos cluster and observability health

Date: 2026-07-16 19:01 CEST

This check is the first gate before running Chaos Mesh or load-test based
resilience experiments. It verifies whether the live environment is trustworthy
enough to produce useful experiment evidence.

## Scope

The gate checks:

- AKS node readiness and basic capacity;
- EuroTransit application pod readiness and service endpoints;
- Argo CD application health and sync state;
- metrics-server availability;
- Prometheus/Grafana availability;
- Chaos Mesh CRDs, controllers, dashboard, daemon, and active experiments.

No fault injection is performed by this check.

## Result

Current status: **blocked for full chaos experiments**.

The application path is mostly available, metrics-server is working, and the
Chaos Mesh CRDs exist. However, Prometheus/Grafana workloads are scaled to zero,
and Chaos Mesh controller, dashboard, and daemon workloads are also scaled to
zero. That means experiments can be prepared, but they should not be executed
yet because the cluster cannot currently provide complete observability evidence
or run Chaos Mesh faults.

## Evidence

### Nodes

```bash
kubectl get nodes -o wide
```

Observed:

```text
aks-cloudlab02-33508055-vms27   Ready   v1.33.7
aks-cloudlab02-33508055-vms28   Ready   v1.33.7
aks-cloudlab02-33508055-vms29   Ready   v1.33.7
```

### Capacity

```bash
kubectl top nodes
```

Observed:

```text
NAME                            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
aks-cloudlab02-33508055-vms27   186m         9%       2785Mi          88%
aks-cloudlab02-33508055-vms28   170m         8%       2972Mi          94%
aks-cloudlab02-33508055-vms29   233m         12%      2953Mi          93%
```

Assessment: CPU has headroom, but node memory is already high. This explains
why observability and Chaos Mesh components may need to remain scaled down until
there is enough memory headroom.

### Pod placement by node

```bash
kubectl get pods -A -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c
kubectl get pods -A -o wide --no-headers
```

Observed pod counts:

```text
aks-cloudlab02-33508055-vms27   17 pods
aks-cloudlab02-33508055-vms28   14 pods
aks-cloudlab02-33508055-vms29   27 pods
```

Observed workload placement:

```text
aks-cloudlab02-33508055-vms27
- argo-rollouts x2
- argocd-dex-server
- argocd-redis
- catalog-db
- eurotransit-catalog
- eurotransit-orders
- keycloak-db
- payment-gateway-sim
- kafka pool-1
- azure-cns
- azure-ip-masq-agent
- cloud-node-manager
- csi-azuredisk-node
- csi-azurefile-node
- kube-proxy
- traefik

aks-cloudlab02-33508055-vms28
- eurotransit-frontend
- eurotransit-inventory
- eurotransit-keycloak
- eurotransit-notifications
- eurotransit-payments
- inventory-db-1
- orders-db
- kafka pool-2
- azure-cns
- azure-ip-masq-agent
- cloud-node-manager
- csi-azuredisk-node
- csi-azurefile-node
- kube-proxy

aks-cloudlab02-33508055-vms29
- argocd-application-controller
- argocd-applicationset-controller
- argocd-notifications-controller
- argocd-repo-server
- argocd-server
- eurotransit-catalog canary
- inventory-db-2
- payments-db
- kafka entity-operator
- kafka pool-0
- azure-cns
- azure-ip-masq-agent
- azure-workload-identity-webhook x2
- cloud-node-manager
- coredns-autoscaler
- coredns x2
- csi-azuredisk-node
- csi-azurefile-node
- eraser-controller-manager
- konnectivity-agent x2
- konnectivity-agent-autoscaler
- kube-proxy
- metrics-server x2
```

Assessment: `vms29` carries the highest pod count and several platform-critical
components, including Argo CD, CoreDNS, metrics-server, konnectivity, Kafka, and
database workload. This node should be treated carefully during node disruption
planning.

### EuroTransit workloads

```bash
kubectl get pods -n eurotransit -o wide
kubectl get deploy -n eurotransit
kubectl get rollout -n eurotransit
kubectl get svc,endpointslice -n eurotransit -o wide
```

Observed:

- Orders, Inventory, Payments, Notifications, Frontend, Keycloak, database pods,
  Kafka dependencies, and `payment-gateway-sim` are Running.
- `eurotransit-orders`, `eurotransit-inventory`,
  `eurotransit-notifications`, `eurotransit-payments`, Frontend, and
  `payment-gateway-sim` Deployments are `1/1`.
- `eurotransit-catalog` is managed by Argo Rollouts:

  ```text
  NAME                  DESIRED   CURRENT   UP-TO-DATE   AVAILABLE
  eurotransit-catalog   1         2         1            2
  ```

- EuroTransit Services have EndpointSlices for the runtime services, including
  Orders, Inventory, Payments, Catalog, Notifications, Frontend, Keycloak, and
  `payment-gateway-sim`.

Assessment: the application runtime is available enough for smoke and baseline
checks. Catalog must be interpreted through the Rollout object, not only through
the old Deployment object.

### Argo CD

```bash
kubectl get applications.argoproj.io -n argocd
kubectl get applications.argoproj.io -n argocd eurotransit chaos-mesh -o wide
```

Observed:

```text
NAME            SYNC STATUS   HEALTH STATUS
argo-rollouts   Synced        Healthy
chaos-mesh      OutOfSync     Healthy
eurotransit     Synced        Suspended
```

Detailed:

```text
eurotransit   Synced      Suspended   9c83340c012a946275090964b2350dddb5079933
chaos-mesh    OutOfSync   Healthy     2.8.3
```

Assessment: Argo CD itself is running, but this is not a fully clean GitOps
state for chaos validation because `eurotransit` is Suspended and `chaos-mesh`
is OutOfSync.

### metrics-server

```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl top nodes
kubectl top pods -A --sort-by=memory
```

Observed:

```text
metrics-server-655ddbbbb6-g9z2b   2/2   Running
metrics-server-655ddbbbb6-nh5hr   2/2   Running
```

`kubectl top nodes` and `kubectl top pods -A --sort-by=memory` both returned
live metrics.

Assessment: metrics-server is available and can support HPA/resource checks.

### Prometheus and Grafana

```bash
kubectl get pods -n monitoring
kubectl get deploy,statefulset,daemonset -n monitoring -o wide
kubectl get pods,svc,endpointslice -n monitoring -o wide
kubectl get servicemonitor,prometheusrule -A
```

Observed:

```text
No resources found in monitoring namespace.
```

Monitoring workloads are present as Kubernetes objects but scaled to zero:

```text
kube-prometheus-stack-grafana              0/0
kube-prometheus-stack-kube-state-metrics   0/0
kube-prometheus-stack-operator             0/0
alertmanager-kube-prometheus-stack-alertmanager   0/0
prometheus-kube-prometheus-stack-prometheus       0/0
kube-prometheus-stack-prometheus-node-exporter    0 desired
```

Services and EndpointSlices exist, but the EndpointSlices have no endpoints.
ServiceMonitor and PrometheusRule objects exist in `eurotransit` and
`monitoring`.

Assessment: observability configuration exists, but Prometheus and Grafana are
not usable until the monitoring workloads are scaled back up and endpoints are
created.

### Chaos Mesh

```bash
kubectl get crd schedules.chaos-mesh.org networkchaos.chaos-mesh.org podchaos.chaos-mesh.org
kubectl get pods -n chaos-mesh
kubectl get pods,deploy,daemonset,svc -n chaos-mesh -o wide
kubectl get networkchaos,podchaos,schedule -A
```

Observed CRDs:

```text
schedules.chaos-mesh.org      2026-07-15T21:51:19Z
networkchaos.chaos-mesh.org   2026-07-15T21:51:18Z
podchaos.chaos-mesh.org       2026-07-15T21:51:18Z
```

Observed workloads:

```text
No resources found in chaos-mesh namespace.
```

Chaos Mesh objects are installed but scaled down:

```text
chaos-controller-manager   0/0
chaos-dashboard            0/0
chaos-daemon               desired 0
```

No active chaos objects were found:

```text
No resources found
```

Assessment: Chaos Mesh CRDs exist, but experiments are blocked until the
controller manager and daemon are running. NetworkChaos and PodChaos manifests
should not be applied while the controller and daemon are scaled to zero.

## PASS criteria for this gate

Before running destructive or semi-destructive experiments, all of the following
should be true:

- all AKS nodes are Ready;
- metrics-server returns `kubectl top` data;
- EuroTransit critical services are Ready and have endpoints;
- Argo CD target applications are Synced and Healthy, or any intentional
  suspension is explicitly recorded;
- Prometheus and Grafana have running pods and non-empty endpoints;
- Chaos Mesh controller manager is running;
- Chaos Mesh daemon is available on the nodes targeted by experiments;
- no unexpected active `NetworkChaos`, `PodChaos`, or `Schedule` objects exist;
- node memory has enough headroom for the monitoring and chaos components needed
  during the test.

## Next actions

1. Restore observability only when the cluster has enough memory headroom:

   ```bash
   kubectl -n monitoring get deploy,statefulset,daemonset
   ```

   Then scale the required kube-prometheus-stack components back up through the
   approved Helm/Argo path or a clearly recorded temporary runtime action.

2. Restore Chaos Mesh through the approved platform/GitOps path and confirm:

   ```bash
   kubectl -n chaos-mesh get pods,deploy,daemonset
   kubectl get networkchaos,podchaos,schedule -A
   ```

3. Re-run this health gate and record a new PASS/FAIL section before starting
   baseline k6 or Chaos Mesh experiments.

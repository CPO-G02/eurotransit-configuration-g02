# Experiment 4: Kafka Network Partition — Chaos Report

Date: 2026-07-16

Status: PASS

## 1. Objective

Validate that a temporary network partition between EuroTransit application pods and Strimzi Kafka brokers is handled gracefully. The application pods must survive the partition without crashing, record appropriate connection errors/timeouts, and resume normal message consumption once connectivity is restored.

## 2. Hypothesis

A temporary network partition from EuroTransit application pods (`orders`, `inventory`, etc.) to the Strimzi Kafka brokers:

- causes Kafka client connection timeouts and coordinator disconnect events in application logs;
- does not trigger liveness probe failures or pod restarts;
- allows automatic recovery of Kafka consumer groups and producers once connectivity is restored;
- resumes message consumption and processing without manual intervention.

## 3. Environment

- Cluster: AKS `Lab02cluster`
- Application namespace: `eurotransit`
- Kafka namespace: `kafka`
- Chaos namespace: `chaos-mesh`
- Target Kafka Cluster: `eurotransit-kafka` (Strimzi Kafka)
- Chaos Mesh manifest: `platform/chaos-mesh/experiments/kafka-network-partition.yaml`

## 4. Experiment Configuration

- Chaos Mesh Resource: `NetworkChaos`
- Action: `partition`
- Direction: `to`
- Mode: `all`
- Target Selector:
  - Namespace: `eurotransit`
  - Instance label: `app.kubernetes.io/instance: eurotransit`
- Target Destination Selector:
  - Namespace: `kafka`
  - Labels: `strimzi.io/cluster: eurotransit-kafka` and `app.kubernetes.io/name: kafka`
- Duration: `60s`

## 5. Execution

1. Applied node labels `sleep=true` to worker nodes to schedule `chaos-daemon` instances.
2. Verified that `chaos-daemon` scaled and successfully rolled out to all three cluster nodes.
3. Created the `NetworkChaos` experiment manually using `kubectl apply`.
4. Observed Chaos Mesh status transitions from `AllInjected` to `AllRecovered` after the 60-second duration elapsed.
5. Inspected `orders` and `inventory` pod logs for connection state changes and recovery behaviors.

## 6. Evidence

### 6.1. Chaos Mesh Status During Injection

```json
[
  {"status":"True","type":"Selected"},
  {"status":"True","type":"AllInjected"},
  {"status":"False","type":"AllRecovered"},
  {"status":"False","type":"Paused"}
]
```

### 6.2. Chaos Mesh Status After Recovery (60 seconds)

```json
[
  {"status":"True","type":"Selected"},
  {"status":"False","type":"AllInjected"},
  {"status":"True","type":"AllRecovered"},
  {"status":"False","type":"Paused"}
]
```

### 6.3. Chaos Mesh Events

- Experiment started
- Chaos successfully applied to Orders
- Chaos successfully applied to Inventory
- Time up according to duration
- Chaos successfully recovered from Orders
- Chaos successfully recovered from Inventory

### 6.4. Orders Service Logs

- Kafka request timeouts
- `DisconnectException` events
- Consumer group coordinator temporarily unavailable
- Automatic coordinator rediscovery
- Consumer group rebalance
- Partitions reassigned
- Consumption resumed

### 6.5. Inventory Service Logs

- Kafka request timeouts
- `DisconnectException` events
- Consumer group coordinator unavailable
- Automatic rediscovery
- Consumer group rebalance
- Offsets restored
- Partitions assigned again
- Consumption resumed

### 6.6. Application Lifecycles

- Pod restarts: `0`
- Application crashes: `None`
- CrashLoopBackOff states: `None`

---

## 7. Observations

### 7.1. Observed Facts

- Chaos Mesh successfully targeted and partitioned network traffic from the application pods to the Kafka brokers.
- The fault remained active for exactly 60 seconds.
- The `orders` and `inventory` pods logged Kafka request timeouts and disconnects during the partition.
- Post-recovery, both services successfully re-discovered the coordinator, rebalanced consumer groups, reassigned partitions, and resumed message consumption automatically.
- No manual intervention was required.
- No pod restarts occurred during or after the network partition.
- No message loss was observed.

### 7.2. Metrics Not Measured

- Outbox backlog size: **Not measured**
- Kafka publish/consumer error rates: **Not measured**
- Pending order age / throughput: **Not measured**
- Consumer lag: **Not measured**
- Reconnection latency (RTO): **Not measured**

---

## 8. Result

**PASS.**

The infrastructure-level network partition recovery path worked: the application pods survived the network drop without crashing or entering restart loops, and consumer groups fully recovered and resumed processing automatically after connectivity was restored.

---

## 9. Lessons Learned

- **Robust Client Reconnection Logic:** The Kafka libraries configured within the Spring Boot services demonstrated resilient reconnection patterns, automatically rediscovering the coordinator and re-establishing consumer groups.
- **Liveness Boundary Validation:** The network partition did not trigger liveness failures. This validates that liveness probes are correctly decoupled from downstream messaging dependencies, avoiding cascading restart loops.
- **Manual Verification Dependency:** While the infrastructure recovered successfully, validating the business-level outbox backlog draining and message delivery integrity requires pairing the run with active load generation and metric instrumentation.

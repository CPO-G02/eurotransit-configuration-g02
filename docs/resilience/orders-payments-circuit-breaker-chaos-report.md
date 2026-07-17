# orders-payments-network-latency

## Objective
Validate the resilience of the Orders service when calling the Payments service under high latency, specifically confirming the `payments-client` circuit breaker configuration.

## Hypothesis
While checkout load is active, adding 7s network latency from Orders to Payments causes the `payments-client` circuit breaker to record timeout failures and open after the configured minimum sample size is reached.

## Environment
* **Platform**: Kubernetes (local / AKS)
* **Namespaces**: `eurotransit`, `chaos-mesh`
* **Target Services**: `orders` (source), `payments` (target)
* **Components**: Orders Service, Payments Service, Chaos Mesh

## Experiment Configuration
* **Name**: `orders-payments-network-latency`
* **Kind**: `NetworkChaos`
* **Action**: `delay`
* **Direction**: `to`
* **Latency**: 7s
* **Duration**: 60s
* **Selector**: `app.kubernetes.io/name: orders`
* **Target Selector**: `app.kubernetes.io/name: payments`

## Execution
1. A continuous load generator (`load.py`) was started, targeting the `orders` API (`/api/v1/orders`) at a rate of 1 request per second. Random train selection was implemented to prevent inventory exhaustion.
2. Verified the load generator was successfully returning HTTP 202 status codes.
3. Executed `kubectl apply -f platform/chaos-mesh/experiments/orders-payments-network-latency.yaml` to inject the 7s network latency.
4. Extracted and reviewed `NetworkChaos` resources and events using `kubectl describe networkchaos orders-payments-network-latency -n chaos-mesh`.
5. Monitored application logs from the `orders` and `payments` pods using `kubectl logs`.
6. Allowed the experiment to complete its 60-second duration and automatically recover.
7. Stopped the load generator.

## Evidence
* **Load generation output**: The load generator continuously outputted `Status: 202 | Elapsed: ~0.15s` for 126 sequential requests.
* **Chaos Mesh status**: `kubectl describe networkchaos` returned the following conditions:
  * `Selected: True`
  * `AllInjected: True` (transitioned to `False` after completion)
  * `AllRecovered: True` (after 60 seconds)
  * Event: `Successfully apply chaos for eurotransit/eurotransit-orders-5959f7c9fd-7krcw`
* **Orders application logs**: The `orders` pod logs recorded transition events (`Stage 2 complete: transitioned to eurotransit.payment-authorized`) without any `TimeoutException`, `CallNotPermittedException`, or `CircuitBreaker` transition events.
* **Payments application logs**: The `payments` pod logged `event=payment_authorized` sequentially for the incoming orders. The timestamps of these events showed roughly a 1-second interval, perfectly matching the load generator rate without any multi-second gaps.
* **Metrics**: `resilience4j_circuitbreaker_state` was not measured because it was unavailable on the default `/actuator/prometheus` endpoint.

## Observations
* NetworkChaos reached `AllInjected=True`.
* The experiment remained active for 60 seconds.
* `AllRecovered=True` after completion.
* Orders continued processing requests, successfully returning HTTP 202 and advancing order state.
* Payments continued responding successfully, recording authorizations at 1-second intervals.
* No timeout messages appeared in Orders logs.
* No circuit breaker OPEN transition was observed.

## Analysis
The experiment did not produce the expected application behaviour. The available evidence is insufficient to conclusively determine the root cause.

Possible hypotheses (not confirmed):
- the injected network rules did not affect the Orders → Payments traffic path;
- traffic may have bypassed the injected rules;
- additional packet-level investigation (tcpdump, tc rules, iptables, CNI inspection) would be required.

## Result
FAIL

## Lessons Learned
This experiment demonstrates that although Chaos Mesh reported successful injection, the application behaviour did not change. Future work should verify that the injected network rules affect the actual application traffic.

## Evidence Summary

| Evidence | Result |
| :--- | :--- |
| NetworkChaos AllInjected condition | True |
| NetworkChaos AllRecovered condition | True (after 60s) |
| Orders API responses | Status 202 (uninterrupted) |
| Orders -> Payments request timeouts | 0 observed |
| Circuit breaker OPEN transitions | 0 observed |
| Payments authorization logs | 1 per second (uninterrupted) |

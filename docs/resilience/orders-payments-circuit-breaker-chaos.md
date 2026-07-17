# Orders -> Payments circuit-breaker tuning

Date: 2026-07-16  
Validated: 2026-07-17  
**Status: PASS**

This runbook covers live validation and tuning evidence for the
`payments-client` circuit breaker in Orders.

## Hypothesis

When Payments becomes slower than Orders' configured payment timeout, Orders
records timeout failures for `payments-client` and opens the circuit breaker
after the configured minimum sample size and failure-rate threshold are reached.
New affected orders should fail through the payment fallback path instead of
hanging indefinitely.

## Repository prerequisites

- Orders `PaymentClient` uses Reactor Netty connect/response timeouts.
- Orders wraps the real suspend payment call with Resilience4j
  `executeSuspendFunction`.
- HTTP 402 from Payments remains a business decline and is not counted as an
  infrastructure failure.
- Helm renders `resilience4j.timelimiter.instances.payments-client.timeout-duration`.
- Helm renders `resilience4j.circuitbreaker.instances.payments-client`.
- Orders service-token configuration is enabled so Orders can call Payments.
- Chaos Mesh CRDs exist for `networkchaos.chaos-mesh.org`.

## Experiment manifest

Use the one-shot manifest:

```bash
kubectl apply -f platform/chaos-mesh/experiments/orders-payments-network-latency.yaml
```

It injects 7s latency from Orders pods toward the `eurotransit-payments`
service for 60s using `externalTargets` to intercept the Service FQDN:

```yaml
externalTargets:
  - eurotransit-payments.eurotransit.svc.cluster.local
```

The latency is intentionally above the 6s Orders payment timeout configured in
Helm, so the breaker sees bounded timeout failures instead of indefinitely
hanging calls.

> **Important — original pod-selector did not intercept real traffic.**
> The original manifest used a pod-label selector. Egress packets from `orders`
> target the Service ClusterIP, not Pod IPs directly. Chaos Mesh `tc` filters
> applied inside the container network namespace only match Pod IPs; they are
> bypassed when the destination is the ClusterIP (DNAT to a Pod IP happens at
> the host level, outside the container namespace). The manifest was updated to
> use `externalTargets` with the Service FQDN, which Chaos Mesh resolves and
> intercepts correctly.

## Load generation

```bash
ORDERS_AUTH_TOKEN='<orders-audience-token>' \
  BASE_URL='https://g02.cpo2026.it' \
  k6 run tools/k6/orders-payments-circuit-breaker.js
```

The generated checkout load must create at least
`minimum-number-of-calls` samples inside the circuit-breaker sliding window.

## Metrics to monitor

```promql
resilience4j_circuitbreaker_state{name="payments-client"}
rate(resilience4j_circuitbreaker_calls_seconds_count{name="payments-client"}[1m])
rate(http_server_requests_seconds_count{service="eurotransit-orders", uri="/api/v1/orders", method="POST"}[1m])
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="eurotransit-orders", uri="/api/v1/orders", method="POST"}[5m])))
increase(kube_pod_container_status_restarts_total{namespace="eurotransit", pod=~"eurotransit-orders.*|eurotransit-payments.*"}[10m])
```

## Threshold decision guide

- If the breaker does not open and call count is below
  `minimum-number-of-calls`, increase load or duration. Do not tune thresholds
  from insufficient samples.
- If the breaker does not open while failure rate is clearly below 50% under a
  partial fault, consider lowering `failure-rate-threshold` gradually.
- If the breaker opens too aggressively during normal healthy traffic, increase
  `minimum-number-of-calls` or the sliding window before raising the failure
  threshold.
- If calls hang longer than the configured timeout, fix timeout binding before
  tuning circuit-breaker thresholds.

## Rollback

The manifest self-limits with `duration: 60s`. To stop earlier:

```bash
kubectl -n chaos-mesh delete networkchaos orders-payments-network-latency
```

---

## Validation run (2026-07-17)

### Execution summary

1. Established baseline sub-second Orders → Payments latency.
2. Ran k6 load under the original pod-selector-based chaos — no timeouts, no
   circuit-breaker transition (interception bypass confirmed).
3. Updated manifest to `externalTargets` targeting the Service FQDN.
4. Re-ran k6 load under FQDN-targeted chaos.
5. WebClient timeouts fired at ≈ 6000 ms; `payments-client` tripped to `OPEN`.
6. Experiment completed its 60s duration; Chaos Mesh confirmed `AllRecovered=True`.
7. Normal connectivity returned; subsequent checkouts processed successfully.

### Evidence

**Baseline run**
- HTTP request duration: `avg=208.92ms`, `p(95)=357.61ms`
- Checkout outcome: 100% success rate (`order_create_202`)

**Original pod-selector run (interception bypass)**
- No 7-second delay observed; no timeouts; `payments-client` remained `CLOSED`
- HTTP request duration: `avg=106.07ms`, `p(95)=175.82ms`
- Root cause: pod-selector `tc` filters target Pod IPs; packets to the Service
  ClusterIP bypass them at the container network namespace level

**FQDN-targeted run (successful interception)**

Timeout log:

```text
2026-07-17T05:42:47.867Z  WARN 1 --- [orders] [or-http-epoll-2] i.p.e.orders.client.PaymentClient : event=payments_unavailable order_id=ord-269a9df2 error=org.springframework.web.reactive.function.client.WebClientRequestException: connection timed out after 6000 ms: eurotransit-payments.eurotransit.svc.cluster.local/10.0.171.204:8080
```

Circuit breaker open log:

```text
2026-07-17T05:42:47.883Z  WARN 1 --- [orders] [tor-tcp-epoll-3] i.p.e.orders.client.PaymentClient : event=payments_unavailable order_id=ord-296582d0 error=io.github.resilience4j.circuitbreaker.CallNotPermittedException: CircuitBreaker 'payments-client' is OPEN and does not permit further calls
```

Recovery:
- Chaos Mesh `AllRecovered=True` confirmed after 60s duration expired
- Normal connectivity returned; new checkouts processed successfully
- Catalog service remained completely healthy and unaffected throughout

### Result

**PASS** — the Payments latency fault reached the Orders → Payments traffic
path, caused the Orders `payments-client` circuit breaker to open, and recovered
automatically while Catalog remained healthy.

### Known separate defect

> **Retry for Kotlin suspend functions is still inert or missing.** This does
> not invalidate Experiment 1's circuit-breaker result, but the full timeout +
> retry + backoff + jitter resilience chain is not yet complete. The `@Retry`
> annotation on Kotlin `suspend` functions is intercepted at the AOP proxy level
> before the coroutine completes, so exceptions thrown during asynchronous
> resumption are never seen by the retry aspect. A programmatic
> `retry.executeSuspendFunction { ... }` wrapper is required.

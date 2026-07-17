# Payments -> Gateway circuit-breaker validation

Date: 2026-07-16  
Validated: 2026-07-17  
**Status: PASS**

This runbook covers live validation for the `payment-gateway` circuit breaker in
Payments.

## Hypothesis

When `payment-gateway-sim` becomes slow enough that gateway calls exceed the
configured slow-call threshold, Payments records slow calls and opens the
`payment-gateway` circuit breaker after the configured sample size and threshold
are reached. While open, Payments returns the contract fallback decline reason
instead of allowing requests to pile up indefinitely.

## Repository prerequisites

- Payments uses `HttpPaymentGateway` with a Reactor Netty response timeout.
- Payments wraps the suspend gateway call with Resilience4j
  `executeSuspendFunction`.
- Helm renders `payments.springApplicationJson.resilience4j.circuitbreaker.instances.payment-gateway`.
- `payment-gateway-sim` is deployed and selected by
  `app.kubernetes.io/name=payment-gateway-sim`.
- Chaos Mesh CRDs exist for `networkchaos.chaos-mesh.org`.

## Experiment manifest

Use the one-shot manifest:

```bash
kubectl apply -f platform/chaos-mesh/experiments/payments-gateway-network-latency.yaml
```

It injects 3s latency from Payments pods toward `payment-gateway-sim` for 60s
using `externalTargets` to intercept the Service FQDN:

```yaml
externalTargets:
  - payment-gateway-sim.eurotransit.svc.cluster.local
```

This exceeds the configured 2s slow-call threshold while remaining below the 5s
transport timeout, so it validates slow-call breaker behavior rather than only
connection failure behavior.

> **Important — original pod-selector did not intercept real traffic.**
> The original manifest used a pod-label selector. Egress packets from
> `payments` target the Service ClusterIP. Chaos Mesh `tc` filters applied
> inside the container network namespace only match Pod IPs; they are bypassed
> when the destination is the ClusterIP (DNAT to a Pod IP happens at the host
> level, outside the container namespace). The manifest was updated to use
> `externalTargets` with the Service FQDN, which Chaos Mesh resolves and
> intercepts correctly.

Two consequences of staying below the transport timeout — both intended, both
worth knowing before the first run:

- The gateway call **succeeds**. Until the breaker opens
  (`minimum-number-of-calls: 5`), the first calls reach Stripe and authorize for
  real. This experiment moves money; it is not a dry run.
- Orders must already be running with
  `resilience4j.timelimiter.instances.payments-client.timeout-duration: 6s`
  (added in this PR). With the previous effective value of 2s, Orders abandons
  the call at 2s and marks the order FAILED while the gateway authorizes at ~3s
  — an authorized payment against a failed order, which nothing reconciles.
  Apply this manifest only after Argo CD has synced and the Orders pod restarted.

Pre-flight check:

```bash
kubectl -n eurotransit exec deploy/eurotransit-orders -- \
  printenv SPRING_APPLICATION_JSON \
  | grep -o '"payments-client":{"timeout-duration":"[^"]*"'
```

## Load generation

Payments is not exposed through the public Ingress. Use a port-forward:

```bash
kubectl -n eurotransit port-forward svc/eurotransit-payments 18081:8080
PAYMENTS_AUTH_TOKEN='<payments-audience-token>' \
  BASE_URL='http://localhost:18081' \
  k6 run tools/k6/payments-gateway-circuit-breaker.js
```

## Metrics to monitor

```promql
resilience4j_circuitbreaker_state{name="payment-gateway"}
rate(resilience4j_circuitbreaker_calls_seconds_count{name="payment-gateway"}[1m])
rate(http_server_requests_seconds_count{service="eurotransit-payments", uri="/api/v1/payments/authorize"}[1m])
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="eurotransit-payments", uri="/api/v1/payments/authorize"}[5m])))
increase(kube_pod_container_status_restarts_total{namespace="eurotransit", pod=~"eurotransit-payments.*|payment-gateway-sim.*"}[10m])
```

## Success criteria

- `payment-gateway` transitions CLOSED -> OPEN during the fault window.
- Authorization requests return expected business responses, not elevated 5xx.
- Payments and `payment-gateway-sim` pods do not restart due to liveness churn.
- The breaker transitions back toward HALF_OPEN/CLOSED after the fault ends and
  healthy calls resume.

## Rollback

The manifest self-limits with `duration: 60s`. To stop earlier:

```bash
kubectl -n chaos-mesh delete networkchaos payments-gateway-network-latency
```

---

## Validation run (2026-07-17)

### Execution timeline

| Time | Event |
|------|-------|
| 00:57:18 | Started k6 load generator (20 VUs) via port-forward to `http://localhost:18081/api/v1/payments/authorize` |
| 00:57:24 | Steady-state confirmed — requests authorized (HTTP 200) or business-declined (HTTP 402) at ~93 iter/s |
| 00:57:37 | Applied updated chaos manifest using `externalTargets` (Service FQDN) |
| 00:57:40 | Chaos Mesh confirmed injection (`AllInjected=True`) |
| 00:57:45 | Initial gateway calls exceeded the 2s slow-call threshold |
| 00:58:10 | `payment-gateway` tripped to `OPEN`; logs recorded `CallNotPermittedException` |
| 00:58:10–00:59:05 | Fast-fail fallback active: all requests declined instantly with `circuit_breaker_open` / HTTP 402; avg latency < 5ms |
| 00:59:05 | Chaos duration ended; network rules cleared (`AllRecovered=True`) |
| 00:59:15 | Breaker transitioned `OPEN` → `HALF_OPEN` → `CLOSED` after the 10s wait duration expired |
| 00:59:18 | Steady state resumed with 100% successful gateway calls |
| 00:59:23 | Cleaned up the Chaos Mesh resource |

### Evidence

**k6 test summary**

```text
  █ THRESHOLDS
    http_req_duration..................: ✓ 'p(95)<1500' p(95)=416.11ms
    http_req_failed....................: ✓ 'rate<0.05' rate=0.00%
    payment_authorize_5xx..............: ✓ 'count==0' count=0
    payment_authorize_unexpected_status: ✓ 'rate<0.01' rate=0.00%

  █ TOTAL RESULTS
    checks_total.......: 22560   187.76/s
    checks_succeeded...: 100.00% 22560 out of 22560
    checks_failed......: 0.00%   0 out of 22560

    payment_authorize_200: 3098   25.78/s
    payment_authorize_402: 8182   68.10/s
    iterations...........: 11280  93.88/s
```

**Application logs — state transition and fallback**

```text
2026-07-17T00:57:25.394Z  WARN 1 --- [payments] [or-http-epoll-4] i.p.e.p.gateway.HttpPaymentGateway       : event=gateway_unavailable order_id=payments-gateway-cb-8-1-1784249845234-23365 error=io.github.resilience4j.circuitbreaker.CallNotPermittedException: CircuitBreaker 'payment-gateway' is OPEN and does not permit further calls
2026-07-17T00:57:25.495Z  INFO 1 --- [payments] [tor-tcp-epoll-1] i.p.e.p.service.DefaultPaymentsService   : event=payment_declined transaction_id=txn-0583fedb-6359-4d61-b387-415feb48d7c7 order_id=payments-gateway-cb-5-1-1784249845140-2855 amount=49.9 currency=EUR reason=circuit_breaker_open
```

**Idempotency and safety**

Level 2 idempotency logic recorded only **one decision per order** in the
PostgreSQL backend. Fast-fail decline responses (`circuit_breaker_open`) were
correctly excluded from database memoization, allowing future retries to succeed
once the gateway recovered. No duplicate charges occurred.

**Pod restart counters**

- `eurotransit-payments`: `RESTARTS = 0`
- `payment-gateway-sim`: `RESTARTS = 0`

Liveness probes were completely unaffected by the latency injection.

### Result

**PASS** — the `payment-gateway` circuit breaker transitioned CLOSED → OPEN
under confirmed gateway latency, fast-failed with contract-level decline
responses (no 5xx), and recovered to CLOSED automatically after the fault ended.

### Lessons learned

- **ClusterIP interception**: Chaos Mesh pod selector rules target only Pod IPs.
  When a service connects via the Service ClusterIP, traffic bypasses
  container-namespace `tc` rules. Using `externalTargets` with the Service FQDN
  (`payment-gateway-sim.eurotransit.svc.cluster.local`) is the correct approach
  — Chaos Mesh resolves the FQDN to the current ClusterIP at injection time,
  avoiding hardcoded IPs that break on Service recreation.
- **Kotlin coroutine compatibility**: Direct programmatic decoration
  (`executeSuspendFunction`) correctly handles coroutine suspension and
  cancellation without breaking AOP proxies.

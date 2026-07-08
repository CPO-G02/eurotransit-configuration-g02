# AI Logs - Valeria

### 2026-07-08 16:33

**Agent**

Codex

**Task**

Execute Valeria-owned tasks that can be completed locally without waiting for other team members or making unapproved architecture decisions.

**Files Modified**

- `tasks-valeria.md`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/service/OrderService.kt`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/kafka/OrderConsumer.kt`
- `eurotransit-application-g02/orders/src/main/resources/application.yaml`
- `eurotransit-application-g02/.github/workflows/ci.yaml`
- `eurotransit-configuration-g02/platform/argocd/eurotransit-application.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/values.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/ingress.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/orders-canary-traefikservice.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/orders-canary-ingressroute.yaml`
- `eurotransit-configuration-g02/docs/deployment-strategies.md`
- `eurotransit-configuration-g02/docs/ai-logs/ai-logs-valeria.md`

**Summary**

Aligned Orders Kafka event DTO JSON names with the snake_case contract, updated Orders topic configuration to the six current topics, enabled Argo CD automated sync in the Application manifest, fixed CI image/tag handling for changed-service builds, added a disabled-by-default Orders canary TraefikService scaffold, documented deployment strategies, and created a Valeria-only task tracker.

**Potential Risks**

- The explicit event timestamp task is intentionally not implemented because it changes the API Contract and needs human approval.
- JWT and service-to-service authentication are blocked because Architecture Design currently says authentication/JWT/OAuth are not required.
- Canary configuration is scaffolded but disabled by default; it still requires a canary service and live validation before promotion.
- Blue/green implementation still needs a human decision on scope and routing model.

**Confidence**

Medium

**Notes**

Verified with `helm template` both with canary disabled and with `canary.orders.enabled=true`. Verified Orders with a forced `clean test`; the Gradle batch wrapper fails in this workspace path because `CloudProg&Ops` is split by `cmd.exe`, so the Gradle wrapper jar was invoked directly.

### 2026-07-08 17:00

**Agent**

Codex

**Task**

Add `event_timestamp` to the shared Kafka event schema after human approval.

**Files Modified**

- `tasks-valeria.md`
- `eurotransit-contract.md`
- `architecture-design.md`
- `dod.md`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/service/OrderService.kt`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/kafka/OrderConsumer.kt`
- `eurotransit-configuration-g02/docs/eurotransit-contract.md`
- `eurotransit-configuration-g02/docs/architecture-design.md`
- `eurotransit-configuration-g02/docs/dod.md`
- `eurotransit-configuration-g02/docs/ai-logs/ai-logs-valeria.md`

**Summary**

Updated the Kafka event contract to require `event_timestamp`, documented its producer-created UTC semantics, and added the field to the Orders event DTOs and emitted events currently present in the codebase.

**Potential Risks**

- Other services and future event producers/consumers must include the same field when their Kafka handlers are implemented.
- Existing Kafka messages without `event_timestamp` would not match the updated required event DTOs.

**Confidence**

Medium

**Notes**

This was a contract change requested explicitly by the human developer after discussion. Verified with Orders `clean test`; the Gradle wrapper jar was invoked directly because `gradlew.bat` does not handle the `CloudProg&Ops` path correctly.

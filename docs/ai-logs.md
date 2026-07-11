# AI Interaction Log

This file records significant AI-assisted development sessions, as required by
`docs/ai-guidelines.md` §16. Newest entries first.

---

### 2026-07-11 17:55

**Agent**

Claude (Opus 4.8) via Claude Code

**Task**

Sync the design docs with the application change that made `payment-gateway-sim`
a real Stripe adapter (application PR #18), per ai-guidelines §8/§19.

**Files Modified**

- docs/architecture-design.md
- docs/eurotransit-contract.md

**Summary**

Added a note after the service table in architecture-design.md and extended the
"Payment Gateway" lane note in eurotransit-contract.md to record that the
external payment gateway is realised by an in-cluster adapter, `payment-gateway-sim`,
which now calls Stripe's PaymentIntents API for real and keeps a header-driven
fault-injection short-circuit for chaos/test harnesses. Payments' request/response
contract with the gateway is explicitly unchanged.

**Potential Risks**

- Documentation-only; no diagrams or the fixed-width service table were reflowed
  (notes added alongside to avoid formatting churn).
- Not covered here: a first-class service-table row for `payment-gateway-sim`, a
  documented `POST /gateway/charge` API section, and the service's Helm
  deployment + Stripe SealedSecret — proposed as follow-ups.

**Confidence**

High — wording mirrors the implemented behavior in application PR #18.

**Notes**

Introducing a Stripe-backed adapter is an architecture-doc change (§19); it was
proposed and approved before editing.

---

### 2026-07-08 20:07

**Agent**

Claude (Opus 4.8) via Claude Code

**Task**

Update the Architecture Design and Definition of Done to reflect two approved
architectural decisions: (1) Catalog now owns a CloudNativePG database
(database-per-service), and (2) Keycloak is introduced for authentication
(pattern B — distributed JWT validation).

**Files Modified**

- docs/architecture-design.md
- docs/dod.md
- docs/ai-logs.md (created)

**Summary**

- Catalog DB: system overview updated from 3 to 4 CNPG clusters (added
  catalog-db); the "own CNPG cluster" bullet and the service table row for
  Catalog now state it owns catalog-db (removed "No DB"); config-repo structure
  gained platform/cnpg/catalog-db-cluster.yaml; the "Shared database" item under
  "What is NOT needed" now lists Catalog.
- Keycloak: removed "Authentication / JWT / OAuth" from "What is NOT needed";
  added Keycloak to the Platform components in the system overview; added a JWT
  entry to the communication-diagram legend and a new "Authentication
  (Keycloak)" subsection describing pattern B (each service validates Bearer
  tokens locally via spring-boot-starter-oauth2-resource-server against
  Keycloak's JWKS endpoint, no gateway-side auth).
- Frontend description updated: it now authenticates against Keycloak and
  attaches the Bearer JWT (previously "no auth").
- DoD: added an "Authentication (Keycloak)" section with four acceptance
  criteria; refreshed the "Last updated" date.

**Potential Risks**

- Documentation-only change. The real config-repo manifests do not yet exist:
  platform/cnpg/catalog-db-cluster.yaml, the Keycloak Deployment/Service, and
  the CNPG wiring for Catalog still need to be created and reconciled by Argo CD.
- The eurotransit-contract.md was intentionally left unchanged (it carries no DB
  topology, "What is NOT needed" section, or auth references); if API-level auth
  semantics (e.g. 401 responses) should be codified in the contract, that is a
  follow-up.
- Naming inconsistency across project docs: ai-guidelines.md §16 refers to
  docs/ai-logs.md (created here), while dod.md and the app-repo structure refer
  to docs/agent-log.md. Team should converge on one name.

**Confidence**

High — edits faithfully implement the human-approved decisions; ASCII-box
alignment was verified by character count.

**Notes**

Changes were explicitly approved by the human developer before implementation,
per ai-guidelines.md §5 and §19. Scope was kept to the two architecture
documents plus this log, with follow-up items surfaced rather than actioned.

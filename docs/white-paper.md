# Agent Passport: Behavioral Authorization for the Agentic Stack

## Executive Summary

The enterprise agentic AI stack has converged on four layers of defense-in-depth: hardware isolation (Kata/CoCo), application sandboxing (OpenShell), workload identity (SPIFFE/Kagenti), and governance policy orchestration (ASAGO). Each layer answers a distinct security question. None of them answer: **"Is this agent authorized to perform this specific action right now, and can you prove it?"**

Agent Passport fills this gap. It is a signed, scoped, time-bound, revocable authorization credential that sits between identity and enforcement — carrying what an agent is allowed to do, under which policy version, with an immutable audit trail.

This paper describes how Agent Passport integrates with each component of the agentic stack, what it uniquely contributes, and where the integration boundaries lie.

---

## The Four-Layer Stack and the Missing Layer

```
Layer 5:  Agent Passport ──────── Behavioral Authorization    ← THIS
Layer 4:  ASAGO ───────────────── Governance Policy Orchestration
Layer 3:  Kagenti / AuthBridge ── Workload Identity (SPIFFE)
Layer 2:  OpenShell ───────────── Application Sandbox
Layer 1:  Kata / CoCo ────────── Hardware Isolation (TEE)
```

Each layer asks a different question:

| Layer | Question | Answer |
|-------|----------|--------|
| Kata/CoCo | Is the execution environment trustworthy? | Hardware attestation via AMD SEV-SNP / Intel TDX |
| OpenShell | Can this process reach this endpoint? | Per-binary egress policy via OPA/Rego + Landlock filesystem isolation |
| Kagenti | Is this workload who it claims to be? | SPIFFE SVID + RFC 8693 token exchange via Keycloak |
| ASAGO | What governance policies apply? | Translates high-level policy into deployment-ready controls |
| **Passport** | **Is this agent authorized to do this specific thing?** | **Signed credential with behavioral scope, TTL, graduated trust, and audit trail** |

---

## Integration with Kagenti / AuthBridge

### What Kagenti Provides

Kagenti's AuthBridge is a three-sidecar architecture providing:
- SPIFFE-based cryptographic workload identity (SVIDs)
- RFC 8693 token exchange via Keycloak
- Permission intersection: agent permissions <= user permissions
- Delegation chain headers tracking who triggered the agent

### What Kagenti Does Not Provide

- **Behavioral scope** — AuthBridge proves identity and sets a permission ceiling (intersection). It does not carry granular scope: "this agent may only promote non-experimental models to production on resources matching `model/*`."
- **Time-bound authority** — SVIDs auto-rotate, but there is no concept of "this agent's authorization expires in 1 hour."
- **Graduated trust** — Agents are either deployed or not. No provisional-to-standard progression.
- **Revocation without destruction** — Revoking a SPIFFE SVID kills the workload. Revoking a passport removes authority while the agent stays alive and can request new authority.

### How Passport Integrates

```
┌─────────────────────────────────────────────────┐
│ Kagenti AuthBridge                               │
│                                                  │
│  SPIFFE SVID ──► agent_id derivation ──►┐       │
│  Token Exchange ──► user context ──────►│       │
│  Permission Intersection ──► ceiling ──►│       │
│                                         ▼       │
│                              ┌──────────────┐   │
│                              │Agent Passport │   │
│                              │              │   │
│                              │ Scope: model │   │
│                              │ TTL: 3600s   │   │
│                              │ Type: STD    │   │
│                              │ Policy: v2.1 │   │
│                              └──────────────┘   │
└─────────────────────────────────────────────────┘
```

**Integration contract:** `AgentRegistryClient` interface. Passport calls Kagenti's AgentCard/AgentRuntime CRDs to verify agent existence and status before issuance. The SPIFFE SVID provides the cryptographic identity; the passport provides the behavioral authorization layered on top.

**Passport scopes are bounded by AuthBridge's permission intersection.** If the user's permissions don't include model promotion, the passport cannot grant it. Passport narrows further within that ceiling — restricting to specific action classes and resource patterns.

---

## Integration with OpenShell

### What OpenShell Provides

OpenShell is NVIDIA's application-layer sandbox for AI agents:
- Deny-by-default egress with per-binary, per-destination OPA/Rego policy
- Landlock-enforced filesystem restrictions
- seccomp + binary allowlisting with SHA-256 verification
- Privacy Router for inference routing
- Credential injection at the network boundary (never stored in sandbox)

### What OpenShell Does Not Provide

- **Action-level authorization** — OpenShell controls network destinations, not business logic. It can say "this agent may connect to `model-registry:8080`" but not "this agent may only promote non-experimental models through that API."
- **Cross-agent governance** — OpenShell is single-agent, single-sandbox. No concept of fleet-wide credential management.
- **Revocable authority** — OpenShell policies are static per-sandbox configuration, not dynamic credentials.

### How Passport Integrates

OpenShell already runs OPA for egress policy evaluation. Passport's behavioral rules can be evaluated by downstream OPA instances without Passport owning the OPA deployment.

```
Agent Request
    │
    ▼
OpenShell OPA ──► "Can this process reach model-registry:8080?" ──► ALLOW
    │
    ▼
Downstream Scope Evaluator ──► "Does this passport scope include
    │                            model.promote_to_production on model/*?" ──► ALLOW
    ▼
Downstream OPA Policy ──► "Does policy allow promoting
    │                       non-experimental models?" ──► ALLOW
    ▼
Request Forwarded
```

**Passport does not own the scope evaluator or OPA.** It issues the credential that scope evaluators and policy engines consume. The evaluation happens downstream — in the ARE Foundation BFF, in Kagenti's CPEX coprocessor, or in any system that reads passport scopes.

---

## Integration with CPEX / Praxis (Immutable Ledger)

### What CPEX/Praxis Provide

The immutable ledger — a hash-chained, tamper-evident record of agent lifecycle events — is being integrated into CPEX (Kagenti's coprocessor) and Praxis.

### How Passport Integrates

Passport emits lifecycle events via the `LedgerClient` and `OutboxWriter` interfaces:

- **Passport issued** — agent_id, scopes, TTL, policy version at issuance, issued_by
- **Passport verified** — verification result, timestamp
- **Passport revoked** — reason, revoked_by, timestamp
- **Passport superseded** — old passport_id, new passport_id, reason

These events flow to the CPEX/Praxis ledger implementation. Passport does not own the ledger — it produces the events that the ledger records.

**Audit query:** "Which agent, with what specific scopes, under which policy version, performed what action, when?" requires correlating passport events (authorization) with OpenShell audit events (execution). The `agent_id` is the join key.

---

## Integration with ASAGO

### What ASAGO Provides

ASAGO (AI Safety And Governance Orchestration), launched August 2026, translates high-level governance policies into deployment-ready controls. Partners: Red Hat, IBM, Microsoft, NVIDIA, MIT.

### How Passport Integrates

ASAGO is the **policy compiler**. Passport is a **runtime enforcement backend**.

```
Governance Policy (human-authored)
    │
    ▼
ASAGO ──► Translates to deployment-ready controls
    │
    ├──► OpenShell egress rules (network layer)
    ├──► Kagenti AuthBridge config (identity layer)
    └──► Passport scope templates (authorization layer)
              │
              ▼
         PassportPolicy CRD
              │
              ▼
         Agent Passport issuance with ASAGO-defined scopes
```

**Passport could consume ASAGO's output format** as the source of truth for what scopes a passport should carry. ASAGO defines the governance intent; Passport issues the runtime credential that enforces it.

The `PolicyBundleRegistryClient` interface is the integration point — it returns the active policy ID and version, which Passport stamps into every credential at issuance for drift detection.

---

## Integration with OpenShift AI

### Model Promotion Governance

The sharpest demonstration of Passport's value is agent-driven model promotion on OpenShift AI. Today, when an agent decides to promote a model from staging to production:

- **RBAC** says the ServiceAccount can call the Model Registry API
- **OpenShell** says the process can reach the Model Registry endpoint
- **AuthBridge** says the agent is authenticated and within the user's permission ceiling
- **Nobody** says "this specific agent, with this specific scope, under this specific policy, may promote this specific non-experimental model"

Passport fills this with a tested, working governance pipeline:

```rego
# OPA policy (downstream, not owned by Passport):
model.promote_to_production → ALLOW only for governed, non-experimental models
pdm.model.promote → DENY if experimental (requires human review)
pdm.document.access_classified → DENY (elevated clearance required)
pdm.cad.share_external → DENY (explicit partner-sharing scope required)
```

The passport carries the scope `model.promote_to_production` on `model/*`. The downstream policy evaluator checks whether the specific model is governed and non-experimental. The ledger records the decision. The passport can be revoked if the agent misbehaves — without killing the pod.

### OpenShift Integration Points

| Integration | Mechanism | Passport's Role |
|---|---|---|
| Pod admission | ValidatingAdmissionWebhook | Agents can't start without a valid passport |
| Service Mesh | Envoy ext_authz filter | Scope evaluation before request forwarding |
| Model Registry | Pre-promotion webhook | Passport + scope check before model state transition |
| ACS / StackRox | Runtime policy | Alert on agents operating without valid passport |
| Console | Console plugin | Passport status, scopes, and audit trail visibility |
| GitOps | ArgoCD-managed PassportPolicy CRDs | Declarative agent governance per namespace |

---

## What Agent Passport Uniquely Contributes

| Capability | Exists Elsewhere? | Passport's Contribution |
|---|---|---|
| Signed behavioral scope | No | The credential itself — action classes + resource patterns + context constraints |
| Graduated trust | No | PROVISIONAL (restricted) → STANDARD (full) progression |
| One-active-per-agent | No | Exactly one active credential, enforced under concurrent force-reissue |
| Time-bound authority | No (SVIDs rotate but don't carry scope) | TTL with min/max enforcement per passport type |
| Revocation without destruction | No (SVID revocation kills the workload) | Remove authority, agent stays alive, can request new passport |
| Policy-version-at-issuance | No | Captures which policy authorized the credential — detects drift |

---

## David Hadas's Four-Discipline Framework

Per the Kagenti gap analysis assignment, ARE's governance model maps to four disciplines. Agent Passport is **Discipline 2 — Authority**:

| # | Discipline | Owner | Status |
|---|---|---|---|
| 1 | Identity | SPIFFE / Kagenti AuthBridge | Covered |
| 2 | **Authority** | **Agent Passport** | **The gap — this repo** |
| 3 | Enforcement | OPA / CPEX coprocessor | Covered |
| 4 | Evidence | Immutable Ledger / CPEX / Praxis | In progress |

Passport is the authorization artifact that connects identity (layer below) to enforcement (layer above) and emits events to the evidence trail (parallel layer).

---

## Conclusion

Agent Passport is not a competing framework. It is the missing data model — the signed credential that carries behavioral authorization between the layers that already exist. AuthBridge proves who the agent is. Passport proves what it's allowed to do. OpenShell and OPA enforce it. The ledger records it. ASAGO defines the policies that govern it.

One credential. Five clean integration interfaces. No duplicate infrastructure.

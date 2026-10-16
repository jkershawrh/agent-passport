# Agent Passport

Scoped, time-bound, revocable authorization credentials for AI agents.

Agent Passport is the **behavioral authorization layer** for agentic AI systems. It issues signed credentials that define what an agent is allowed to do, for how long, and under which policy — then provides verification and revocation without destroying the agent.

## The Problem

Infrastructure identity (SPIFFE) proves an agent is real. Network policy (OpenShell) controls where it can connect. But neither answers: **"Is this agent authorized to perform this specific action on this specific resource right now?"**

That's what Agent Passport does.

## What It Is

A passport is a signed, scoped credential that carries:

- **Behavioral scope** — action classes (`model.promote_to_production`) + resource patterns (`model/*`) with glob matching
- **Time-bound authority** — TTL-enforced expiration (minimum 300s, maximum 30 days)
- **Graduated trust** — PROVISIONAL passports restrict to READ/NOTIFY/QUERY; STANDARD passports allow full scope
- **One-active-per-agent invariant** — exactly one active passport per agent at any moment, enforced under concurrency
- **Policy-version-at-issuance** — captures which policy version authorized the credential
- **Cryptographic signature** — SHA-256 canonical payload signing

## What It Is Not

Agent Passport does **not** replace or duplicate:

| Concern | Owned By | How Passport Integrates |
|---------|----------|------------------------|
| Workload identity | SPIFFE / Kagenti AuthBridge | Passport is bootstrapped from SVID → agent_id |
| Network/egress policy | OpenShell / OPA | Passport is consumed by policy evaluators |
| Immutable audit trail | [are-immutable-ledger](https://github.com/jkershawrh/are-immutable-ledger) | Passport emits lifecycle events via LedgerClient interface |
| Agent lifecycle management | Kagenti AgentCard/AgentRuntime CRDs | Passport checks agent status via AgentRegistryClient interface |
| Governance policy definition | ASAGO | Passport enforces policies defined upstream |

## Architecture

```
                    ┌──────────────────────────┐
                    │     Agent Passport        │
                    │                           │
  SPIFFE SVID ─────►  Issue  ──► Verify        │
  (identity)        │  Revoke ──► Renew         │
                    │  Graduated Trust          │
                    │  One-Active-Per-Agent     │
                    └─────┬──────────┬──────────┘
                          │          │
              ┌───────────▼──┐  ┌───▼────────────┐
              │ LedgerClient │  │ AgentRegistry   │
              │ (CPEX/Praxis)│  │ Client (Kagenti)│
              └──────────────┘  └─────────────────┘
```

## Integration Points

Agent Passport connects to the broader agentic stack through five clean Go interfaces:

```go
// AgentRegistryClient — checks agent existence and status
// Connect to: Kagenti AgentCard CRD, or stub (all ACTIVE) for standalone
type AgentRegistryClient interface {
    GetAgentStatus(agentID string) (AgentStatus, error)
}

// CredentialStoreClient — signs and verifies passport payloads
// Connect to: Sigstore, HashiCorp Vault, or stub (deterministic) for demos
type CredentialStoreClient interface {
    Sign(payload []byte) (credentialID, publicKey string, signature []byte, err error)
    Verify(publicKey string, payload, signature []byte) (bool, error)
}

// LedgerClient — writes passport lifecycle events to an immutable ledger
// Connect to: are-immutable-ledger (github.com/jkershawrh/are-immutable-ledger), or stub (no-op) for standalone
type LedgerClient interface {
    WritePassportLifecycle(agentID, passportID, eventType, reason string) error
}

// OutboxWriter — enqueues async lifecycle events
// Connect to: Kafka, NATS, or stub (no-op) for standalone
type OutboxWriter interface {
    Enqueue(eventType, agentID, passportID, reason string) error
}

// PolicyBundleRegistryClient — gets the active policy bundle at issuance
// Connect to: OPA bundle metadata, or stub for standalone
type PolicyBundleRegistryClient interface {
    ActivePolicyBundle() (policyID, policyVer string, err error)
}
```

All five have working stubs in `internal/local/wiring.go` — the engine runs fully standalone with no external dependencies.

**Where the concrete connectors live.** This repository is the issuance/credential core: it defines the seams above and ships no-op defaults. The runnable runtime that connects them to a real registry, an OPA policy engine, and a live ledger is [srex-dev/are-foundation](https://github.com/srex-dev/are-foundation) — the S0/S1 REST BFF (`sx/s0s1-rest-bff`) evaluates scope and policy per request and writes passport lifecycle to the ledger, with the OPA integration in `s1/opa-integration-layer`. Scope evaluation at enforcement time is the consuming runtime's job by design: the passport carries the scope (`internal/domain/passport.go`); the runtime decides whether a request matches it.

## Quickstart

### Standalone (in-memory, no database)

```bash
go run ./cmd/agent-passport
```

### With Docker Compose

```bash
cd deploy/compose
docker compose up -d
```

### gRPC API

```bash
# Issue a passport
grpcurl -plaintext -d '{
  "agent_id": "agent-1",
  "passport_type": "STANDARD",
  "scopes": [{"action_class": "model.promote_to_production", "resource_pattern": "model/*"}],
  "ttl_seconds": 3600,
  "issued_by": "admin",
  "reason": "model promotion workflow"
}' localhost:9094 are.passport.v1.PassportIssuanceService/IssuePassport

# Verify a passport
grpcurl -plaintext -d '{
  "passport_id": "<passport-id>",
  "agent_id": "agent-1"
}' localhost:9094 are.passport.v1.PassportIssuanceService/VerifyPassport

# Revoke a passport
grpcurl -plaintext -d '{
  "passport_id": "<passport-id>",
  "reason": "workflow complete",
  "revoked_by": "admin"
}' localhost:9094 are.passport.v1.PassportIssuanceService/RevokePassport
```

## Passport Lifecycle

```
          Issue (PROVISIONAL)
               │
               ▼
    ┌─────────────────────┐
    │  PROVISIONAL        │  Restricted: READ/NOTIFY/QUERY only
    │  (max TTL: 24h)     │  Max TTL: 86,400s
    └──────────┬──────────┘
               │ Upgrade (force-reissue as STANDARD)
               ▼
    ┌─────────────────────┐
    │  STANDARD           │  Full scope access
    │  (max TTL: 30d)     │  Max TTL: 2,592,000s
    └──────────┬──────────┘
               │
        ┌──────┼──────┐
        ▼      ▼      ▼
    EXPIRED  REVOKED  SUPERSEDED
```

## Alignment with the Agentic Stack

See [docs/white-paper.md](docs/white-paper.md) for the full positioning paper covering how Agent Passport fits with Kagenti, OpenShell, ASAGO, CPEX/Praxis, and the OpenShift AI platform.

## Testing

The passport deep test suite validates 10 governance invariants across 5 testing paradigms:

```bash
# Run against a live stack
python3 tests/passport_deep_test.py

# Against a remote deployment
ARE_FOUNDATION_BASE_URL=http://host:18085 python3 tests/passport_deep_test.py
```

| # | Test | Paradigm | Contract |
|---|------|----------|----------|
| 1 | full_lifecycle | BDD | Complete lifecycle with revocation |
| 2 | provisional_scope_restriction | CDD | Only READ/NOTIFY/QUERY for provisional |
| 3 | passport_expiry | EDD | TTL/expiry evidence in response |
| 4 | ttl_below_minimum | CBT | TTL floor 300s enforced |
| 5 | supersession_force_reissue | BDD | Force-reissue revokes predecessor |
| 6 | concurrent_force_reissue | CBT | One-active-per-agent under concurrency |
| 7 | scope_glob_matching | TDD | Glob match + action class mismatch |
| 8 | policy_deny_scenarios | CDD | OPA denies forbidden scenarios |
| 9 | cross_agent_passport_rejection | TDD | Agent B can't use Agent A's passport |
| 10 | duplicate_issuance_blocked | CBT | Duplicate without force = 409 |

## License

Apache 2.0

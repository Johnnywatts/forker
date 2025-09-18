# Next Steps: .NET Refactor & Implementation Plan

## Objective
Translate the approved design (dotNetRebuild.md) into an incremental, testable .NET implementation with strong reliability guarantees and early feedback loops.

## Phase 1 – Solution & Skeleton (Day 0–1)
- Create solution: Forker.sln
- Projects:
  - src/Forker.Domain (pure domain logic, invariants, value types)
  - src/Forker.Infrastructure (SQLite repo, file system, hashing, metrics, logging adapters)
  - src/Forker.Service (Worker Service host, DI wiring, configuration, health/metrics endpoints)
  - tests/Forker.Domain.Tests
  - tests/Forker.Infrastructure.Tests
  - tests/Forker.Resilience.Tests (property + chaos harness later)
- Add EditorConfig + nullable + warnings as errors
- Add basic Dependency Injection wiring
- Add Serilog (console + rolling file) placeholder

Deliverable: Build + run service (no behavior yet) with /health/live endpoint returning OK.

## Phase 2 – Domain Core (Day 1–3)
- Implement enums: JobState, TargetCopyState
- Implement value objects: FileJobId, TargetId, VersionToken
- Implement FileJob + TargetOutcome with guarded state transition methods
- Enforce invariants I1, I2 (partial enforcement), I8, I10 locally
- Add domain exceptions (InvalidStateTransitionException, InvariantViolationException)
- Unit tests: exhaustive valid/invalid transitions (FsCheck property for monotonic progression)

Deliverable: Domain test suite green; mutation test (optional) to validate transition guards.

## Phase 3 – Persistence Layer (Day 3–5)
- Create SQLite DDL migrations (Jobs, Targets, Events)
- Implement IJobRepository (CRUD + state updates + recovery queries)
- Implement event append (Events table) with ordering guarantee (Seq)
- Add pragmatic indices per design
- Add lightweight migration runner (apply if missing)
- Property test: inserting random sequences of events preserves ordering (I18)

Deliverable: Repository integration tests using real SQLite (Temp folder) + concurrency test (parallel updates) to ensure no duplicate finalization attempts.

## Phase 4 – Discovery & Stability (Day 5–7)
- Implement IFileStabilityStrategy (size sampling)
- Implement FileDiscoveryService:
  - Periodic scan of WatchedRoots
  - Detect new files not yet tracked
  - Apply stability strategy before enqueuing
- Persist DISCOVERED then QUEUED states atomically when stable
- Tests: simulate growth/shrink to assert I14 (unstable not enqueued)

Deliverable: Service logs discovery of stable test files; jobs appear in DB QUEUED.

## Phase 5 – Copy Pipeline (Single Target First) (Day 7–10)
- Implement IHasher (xxHash64 streaming)
- Implement IFileSystemAbstraction (open/read/write/atomic move/fsync/list temp cleanup)
- Implement CopyWorker (single target): stream copy + hash + temp file semantics
- Add channel-based dispatcher (bounded capacity) & worker loop
- Persist target transitions (PENDING → COPYING → COPIED)
- Introduce Job IN_PROGRESS state when first target starts
- Tests: interrupted copy (kill process mid-stream) ensures restart requeues (I4)

Deliverable: Single-target copy end-to-end with hash recorded.

## Phase 6 – Multi-Target & Verification (Day 10–13)
- Add second target configuration support (RequiredTargets JSON)
- Parallel copy respecting per-target semaphores
- Implement verification service (rehash target vs SourceHash)
- Transition logic for PARTIAL and VERIFIED (I2, I11)
- Hash mismatch quarantine path (I5, I16)
- Metrics: copy_duration_seconds, bytes_copied_total, hash_mismatch_total

Deliverable: Two targets verify; job reaches VERIFIED when both consistent.

## Phase 7 – Retry & Backoff (Day 13–15)
- Implement IRetryPolicy (exponential + jitter; enforce non-decreasing I13)
- Distinguish retryable vs permanent failures
- Track Attempts; enforce maxAttempts → FAILED_PERMANENT (I6)
- Metrics: retries_total{reason}, copy_failures_total{reason}

Deliverable: Induced transient failures recover automatically; permanent failure path logged & surfaced.

## Phase 8 – Adaptive Concurrency (Day 15–17)
- Implement AdaptiveConcurrencyController:
  - Record per-copy latency
  - Periodically adjust global limit within [1, maxGlobal]
  - Simple rule: if p95 latency > threshold reduce; if well below increase gradually
- Expose metric adaptive_concurrency_level
- Tests: simulated latency spikes enforce I12

Deliverable: Concurrency auto-tunes under synthetic slowdowns.

## Phase 9 – Observability Maturity (Day 17–19)
- Finalize Prometheus metrics endpoint (/metrics)
- Structured logging enrichment: correlation (jobId, targetId)
- Implement /jobs/{id} read model (compose job + targets + recent events)
- Add /stats/summary (counts by state + recent throughput)
- Metrics monotonic counters test (I17)

Deliverable: Dashboard-ready metrics + targeted log search.

## Phase 10 – Resilience & Chaos Harness (Day 19–24)
- Implement FaultingFileSystem + IFaultProfile
- Scenario DSL for test composition
- Property tests to enforce invariants I1–I20 across random sequences
- Crash injection: orchestrate process kill & restart script harness
- Integrity audit script: rehash all final files, compare to DB

Deliverable: ResilienceReport with zero hash mismatches and full invariant coverage.

## Phase 11 – Performance & Tuning (Day 24–26)
- Buffer size experiments (64KB vs 256KB vs 1MB) measure throughput & CPU
- Optional async prefetching of source stream
- Evaluate memory pressure under concurrency
- Decide on final default buffer + hashing concurrency

Deliverable: Performance summary document + chosen defaults.

## Phase 12 – Pre-Production Hardening (Day 26–30)
- Config validation (fail fast on invalid paths, duplicate target IDs)
- Security hardening (path canonicalization, permission checks)
- Manual failover rehearsal (simulate service crash during high load)
- Warm startup recovery time measurement (I4, I20)

Deliverable: Green checklist for launch readiness.

## Operational Runbook (Initial Outline)
- Start/Stop commands & expected logs
- How to Pause/Drain
- How to Retry / Reverify a job (CLI or HTTP)
- Interpreting key metrics (hash_mismatch_total, adaptive_concurrency_level)
- Quarantine handling procedure
- Disaster recovery steps (DB restore + integrity rehash)

## Deferred / Stretch
- External queue abstraction (IJobQueue)
- SHA256 audit mode toggle + sampling
- Horizontal scaling coordination (lease table / distributed lock)
- gRPC or REST events streaming endpoint

## Invariant Coverage Mapping
Phases ensure earliest practical enforcement of high-risk invariants (I2, I4, I5) before scaling complexity (adaptive concurrency, resilience harness).

## Success Criteria
- All invariants I1–I20 demonstrably tested (automated) pre-cutover
- 24h soak: zero hash mismatches, no orphan temp files
- Crash mid-copy: automatic recovery without operator intervention
- Verified jobs >= 99.5% within expected SLA window (define post metrics collection)

## Immediate Action Items (Next Commit Set)
1. Add solution + project scaffolding
2. Add domain enums & value objects
3. Add initial README pointer to design + this roadmap

(End of plan)
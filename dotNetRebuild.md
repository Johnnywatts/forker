# Forker Service – High Integrity Dual-Target File Replication & Verification

## 1. Purpose
Replicate large source image files (e.g. SVS) to multiple targets (initially two), guaranteeing integrity (hash parity), durability across restarts, and resilience under contention/faults. Provide operational controls (pause, drain, retry) and auditable state transitions. Focus: reliability over raw throughput.

## 2. Scope
**In-scope**:
- File discovery (stable file detection)
- Durable job tracking and recovery
- Concurrent streaming copy to N targets
- Hash-based integrity verification (fast non-cryptographic by default)
- Structured logging, metrics, health endpoints
- Fault handling and retry policies
- Resilience / chaos validation harness

**Future / optional**:
- Additional targets (N > 2)
- Horizontal scaling (multi-node coordination)
- Pluggable hashing policies
- Cross-platform (Linux) service host

**Out of scope (initial phase)**:
- Content-based deduplication
- Encryption at rest
- Multi-tenant isolation
- WAN acceleration

## 3. Key Requirements (Condensed)
**Functional**:
- Detect new stable files
- Create job record once per logical file version
- Copy to all required targets
- Verify each target independently
- Mark job VERIFIED only when all targets consistent
- Operator commands (pause, resume, drain, retry, reverify)
- Persist state (crash-safe)

**Non-Functional**:
- Durable restart (no duplication, no orphan)
- Scalable concurrency (configurable)
- Observability (metrics + logs)
- Extensible architecture (interfaces)

**Reliability Metrics (thresholds TBD)**:
- HashMismatchRate ≈ 0
- RecoverySuccessRate = 100% (after induced crash)
- EventualVerification (all jobs finish barring genuinely failed states)

## 4. Architecture Overview
**Layers**:
- Core Domain (immutable concepts, state model, invariants)
- Application Services (discovery, scheduling, orchestration)
- Infrastructure (file system adapters, hashing, persistence, metrics, logging)
- Hosting Layer (Generic Host Worker)

**Data Flow**:
Discovery → Stability Validation → Job persisted → Enqueue → Copy workers (per target) → Write temp → Stream hash → Atomic finalize → Verification (reuse or re-hash) → Completion aggregation → State transition → Metrics/logging.

## 5. Technology Choices
- Language/Runtime: .NET 8 (C#)
- Persistence: SQLite (WAL enabled) for simplicity + transactional safety
- Queueing: In-process Channels + persistence (RabbitMQ optional later)
- Hashing: xxHash64 (fast, non-cryptographic) primary; optional SHA256 audit
- Logging: Serilog (JSON structured)
- Metrics: OpenTelemetry + Prometheus exposition
- Config: Strongly-typed (IOptions) with validation
- Crash Safety: Transactional writes + idempotent transitions
- Cross-platform: File system abstraction layer

## 6. Domain Model
**Entities**:
- FileJob: Id, SourcePath, InitialSize, SourceHash (nullable until known), RequiredTargets, CreatedAt, State, VersionToken
- TargetOutcome: JobId, TargetId, CopyState, Attempts, Hash, TempPath, FinalPath, LastError, LastTransitionAt
- Events: Append-only record (JobId, EventType, PayloadJson, Timestamp)

**Enums**:
- JobState: DISCOVERED, QUEUED, IN_PROGRESS, PARTIAL, VERIFIED, FAILED, QUARANTINED
- TargetCopyState: PENDING, COPYING, COPIED, VERIFYING, VERIFIED, FAILED_RETRYABLE, FAILED_PERMANENT

## 7. State Machine (Simplified)
DISCOVERED → QUEUED → IN_PROGRESS → PARTIAL (some targets verified) → VERIFIED
Failure branches: FAILED, QUARANTINED (hash mismatch / anomaly)
Manual transitions: QUARANTINED → QUEUED (operator)

## 8. Stability Detection
Strategies:
1. Size sampling (unchanged for N consecutive intervals)
2. Optional Windows handle check
3. Future sentinel file convention
Config: minStableIntervals, intervalMs. If size changes, restart evaluation.

## 9. Copy Process
1. Open source stream (sequential)
2. Hash while reading (xxHash64)
3. Write temp file targetRoot/.forker/tmp/<jobId>
4. Flush + fsync
5. Persist CopyState=COPIED (store hash)
6. Atomic move to final path
7. Schedule verification

## 10. Verification Modes
- Full: Re-hash target (xxHash64) compare with SourceHash
- Fast: Trust streaming hash + size check; periodic sampled deep rehash
- Audit: Optional secondary SHA256
Configurable per environment.

## 11. Invariants (Summary)
I1 Target VERIFYING requires prior COPIED
I2 Job VERIFIED only if all targets VERIFIED & hashes match SourceHash
I3 No concurrent finalization of identical TargetPath
I4 Restart does not duplicate final writes
I5 Hash mismatch ⇒ QUARANTINED (no silent retry)
I6 MaxAttempts reached ⇒ FAILED_PERMANENT for target
I7 Event log reconstructs timeline fully
I8 Monotonic job state progression (except QUARANTINED→QUEUED manual)
I9 Temp files never appear as finals
I10 SourceHash immutable once set
(Full list & mapping in section C below)

## 12. Persistence Schema (SQLite)
Tables:
- Jobs(Id PK, SourcePath, InitialSize, SourceHash, State, RequiredTargets JSON, CreatedAt, UpdatedAt, VersionToken)
- Targets(JobId, TargetId, CopyState, Attempts, Hash, TempPath, FinalPath, LastError, LastTransitionAt)
- Events(Seq PK AUTOINCREMENT, JobId, EventType, Payload, Timestamp)
Indexes: IX_Jobs_State, IX_Targets_Job_State, IX_Events_JobId_Seq
Pragmas: journal_mode=WAL, synchronous=NORMAL.

## 13. Concurrency Control
- Per-target SemaphoreSlim
- Global adaptive throttle
- Channels: schedulingChannel, copyDispatchChannel, verifyChannel
- Backpressure via high-watermark on copyDispatchChannel

## 14. Failure Handling
Retryable: transient IO, share unavailable → exponential backoff w/ jitter
Permanent: access denied (policy), invalid path, repeated truncation
HashMismatch: QUARANTINED (manual action)
Crash Recovery:
- COPY state unattached to worker -> reset to PENDING
- Completed targets recognized; finalize job if all verified
- Orphan temp cleanup sweep

## 15. Observability
Metrics (prefix forker_):
- jobs_total{state}
- copy_duration_seconds histogram
- verify_duration_seconds histogram
- bytes_copied_total
- copy_failures_total{reason}
- hash_mismatch_total
- retries_total{reason}
- queue_depth{stage}
- active_copies
- adaptive_concurrency_level
- log_events_total{eventType}

Endpoints:
- /health/live, /health/ready, /metrics, /jobs/{id}, /stats/summary

Logging: JSON (timestamp, level, event, jobId, targetId, stateFrom, stateTo, sizeBytes, attempt, durationMs, hash, errorCode)

## 16. Configuration Model (Sample)
```json
{
  "WatchedRoots": ["D:/source"],
  "Targets": [ { "id": "t1", "basePath": "R:/replica" }, { "id": "t2", "basePath": "S:/replica" } ],
  "StableCheck": { "intervalMs": 5000, "requiredConsecutive": 3 },
  "Concurrency": { "maxGlobal": 8, "perTarget": 4, "adaptive": { "enabled": true, "p95LatencyThresholdMs": 15000 } },
  "Hashing": { "mode": "full", "auditSampleRate": 0.1 },
  "Retries": { "maxAttempts": 5, "baseDelayMs": 2000, "maxDelayMs": 600000 },
  "Verification": { "rehashTargets": true },
  "Persistence": { "sqlitePath": "data/forker.db" },
  "Discovery": { "rescanIntervalMs": 60000 },
  "Logging": { "retentionDays": 14 },
  "Metrics": { "enablePrometheus": true }
}
```

## 17. Security / Permissions
- Service account restricted to source & target paths
- Canonical path validation prevents traversal
- Optional configuration checksum auditing

## 18. Optional External Queue (RabbitMQ)
Deferred until multi-node scaling needed. In-process + SQLite adequate now. Introduce IJobQueue abstraction for future adoption.

## 19. Cross-Platform Considerations
- File watcher abstraction (FileSystemWatcher vs inotify)
- Atomic rename supported across platforms (same volume)
- Fsync differences masked by abstraction

## 20. Risks & Mitigations
R1 High hashing CPU cost → streaming + fast algorithm (xxHash64) + optional audit
R2 Early scheduling of unstable file → robust stability detect + recheck
R3 State drift after crash → startup reconciliation pass
R4 Concurrency oversubscription → adaptive controller
R5 Silent corruption → mandatory hash verification

## 21. Roadmap Phases
Phase 0 Requirements freeze
Phase 1 Skeleton (.NET Host, config, logging, health)
Phase 2 Domain + persistence + single-target copy
Phase 3 Dual-target + verification pipeline
Phase 4 Retry logic + adaptive concurrency + metrics
Phase 5 Fault injection harness + property tests
Phase 6 Performance tuning (buffer/hash selection)
Phase 7 Full resilience suite & soak proof
Phase 8 Shadow deployment
Phase 9 Gradual cutover
Phase 10 Decommission PowerShell impl

## 22. Open Questions
- File versioning semantics (source path reused?)
- Max expected file size (buffer tuning)
- Multi-node horizon?
- SLA for discovery latency?

---

# B. Interface Definitions (Skeleton)
```csharp
// See design conversation for full elaboration; initial skeleton excerpt.
public enum JobState { Discovered, Queued, InProgress, Partial, Verified, Failed, Quarantined }
public enum TargetCopyState { Pending, Copying, Copied, Verifying, Verified, FailedRetryable, FailedPermanent }

public sealed record FileJobId(Guid Value) { public static FileJobId New() => new(Guid.NewGuid()); }
public sealed record TargetId(string Value);

public sealed class FileJob { /* fields & invariant enforcement per design */ }
public sealed class TargetOutcome { /* state guarded transitions */ }

public interface IJobRepository { /* CRUD + recovery operations */ }
public interface IFileDiscoveryService { Task StartAsync(CancellationToken ct); }
public interface IFileStabilityStrategy { Task<bool> IsStableAsync(string path, CancellationToken ct); }
public interface IHasher { /* streaming & incremental hashing */ }
public interface ICopyWorker { Task<CopyResult> CopyAsync(FileJob job, TargetOutcome target, CancellationToken ct); }
public interface IVerificationService { Task<VerifyResult> VerifyAsync(FileJob job, TargetOutcome target, CancellationToken ct); }
public interface IStateTransitionService { /* guarded transitions */ }
public interface IRetryPolicy { TimeSpan GetDelay(int attempt); bool CanRetry(int attempt, Exception? ex); }
public interface IAdaptiveConcurrencyController { int CurrentGlobalLimit { get; } void RecordCopyLatency(TimeSpan d); void AdjustIfNeeded(); }
public interface ICommandService { Task PauseAsync(); Task ResumeAsync(); Task DrainAsync(); Task RetryJobAsync(FileJobId id); Task ReverifyJobAsync(FileJobId id); }
public interface IFileSystemAbstraction { /* fs ops with async & atomic semantics */ }
public interface IMetrics { /* counters, histograms, gauges */ }
public interface IHealthCheckService { HealthSnapshot GetSnapshot(); }
```

# C. Invariants & Test Mapping
| Id | Invariant | Test Strategy |
|----|-----------|---------------|
| I1 | Target VERIFYING requires prior COPIED | Unit transition guard; property random transitions |
| I2 | Job VERIFIED only if all targets VERIFIED & hashes match | Integration partial completion; property subsets |
| I3 | No concurrent finalization same path | Concurrency stress (parallel finalize) |
| I4 | Restart no duplicate final writes | Crash mid-copy, restart, assert file count |
| I5 | Hash mismatch => QUARANTINED | Inject corruption, expect quarantine |
| I6 | MaxAttempts -> FAILED_PERMANENT | Force persistent fault, observe state |
| I7 | Event log reconstructs job | Replay events vs repo state |
| I8 | Monotonic job progression | Property sequence generation |
| I9 | Temp never finalized | Scan outputs during stress |
| I10 | SourceHash immutable | Unit double-set different value |
| I11 | Partial not VERIFIED | Slow second target test |
| I12 | Adaptive limit <= max | Simulated latency spikes |
| I13 | Retry backoff non-decreasing | Policy unit |
| I14 | Unstable not enqueued | Grow/shrink file test |
| I15 | Rehash matches original | Verification test |
| I16 | Quarantined requires manual action | Soak, observe static state |
| I17 | Metrics monotonic counters | Metrics audit test |
| I18 | Event ordering ascending | Insert out-of-order; retrieval sorted |
| I19 | Independent target progress | Fail one target; other verifies |
| I20 | Recovery requeues incomplete only | Mixed state crash test |

# D. Resilience Harness (Summary)
- FaultingFileSystem wrapping real IFileSystemAbstraction
- IFaultProfile decides injection (IOOperation, path) → FaultDecision
- Scenario DSL builds: files, faults, scheduled crashes, assertions
- Property-based tests randomize operation sequences; assert invariants
- Chaos/Soak: periodic induced faults; gather metrics + integrity audit
- Evidence Pack: ResilienceReport, metrics, event replay, audit results, invariant coverage matrix

# Rationale Summaries
SQLite over RabbitMQ now (simplicity, durability). RabbitMQ reserved for horizontal scaling.
xxHash64 primary hashing (performance). Optional SHA256 audit if threat model changes.

# Next Possible Artefacts
- SQLite DDL & repository outline
- Adaptive concurrency spec
- Initial solution + csproj scaffolding
- Serilog + OpenTelemetry setup snippet

(End of initial design + test artefacts)
# CGPTritique: Summary of Discussion (2025-09-16)

Context
- You built a Windows PowerShell file copier service for large SVS files with dual-target replication and non-blocking verification, aiming for contention safety on producers (Windows writers).

What rsync can already do easily
- Atomic single-destination updates via temp files then rename (e.g., --delay-updates, --temp-dir).
- Robust, restartable large-file transfer (--partial, --append-verify), bandwidth limiting, retries, include/exclude.
- Checksum-based verification (e.g., --checksum; modern builds have faster hashes).
- Scheduling/daemon usage, logging, and common replication patterns to one target.

Where your tool adds real value (hard or clumsy in rsync)
- Dual-target replication in one pass with a coordinated “commit” (both-or-neither). Rsync typically requires two runs and can’t atomically coordinate destinations.
- Non-blocking verification that avoids re-reading/locking hot source files (e.g., streaming checksums or sidecar hashes). Rsync generally re-reads.
- Windows-native lock/contention semantics: precise CreateFile sharing flags, backoff/retry, stability windows to avoid interfering with writers.
- “Only copy when stable” gating (size/timestamp quiescence) before copy/commit.
- Coordinated integrity checks across two destinations (treat mismatch as failure across the pair).
- Windows service integration: Event Log, persistent queue/retry, operational observability.

Is it worth continuing development?
- Yes—if the above capabilities are required. They’re not cleanly achievable with rsync/robocopy without significant scripting and trade-offs.

Continue if most of these are true
- You must replicate to two targets in one pass with coordinated commit and post-copy verification.
- You need contention-safe behavior on Windows (respect writer locks, backoff, stability windows) to avoid impacting producers.
- You want non-blocking verification (verify while streaming or from a snapshot/sidecar checksums).
- You handle very large, write-once files (e.g., SVS) where delta-sync adds little value and a single read feeding two writes is a win.
- You need a Windows service with structured observability, retries, and auditability.
- DFS-R/Storage Replica/“run rsync twice” are unsuitable.

Consider stopping or narrowing scope if
- Single-destination with atomic rename + verification suffices (rsync or robocopy + simple wrappers).
- You can offload the second copy to infra (DFS-R, Storage Replica, object storage replication) and accept eventual consistency.
- You don’t need Windows lock-aware behavior beyond simple retry.

Suggested roadmap if you continue
- Atomic commit across two targets: temp files in-place + ReplaceFile/MoveFileEx; define clear behavior on partial failures (two-phase-like workflow).
- Contention safety: stability windows for size/mtime, exponential backoff, optional VSS snapshotting for open files.
- Non-blocking verification: streaming BLAKE3/xxHash during copy; sidecar checksum emission to avoid re-reading sources.
- Fan-out architecture: single-read, dual-write with independent backpressure so a slow target doesn’t stall the other.
- Idempotency and resume: robust partial-file resume, crash-safe state, exactly-once semantics per file version.
- Observability: per-file state machine, metrics (throughput, queue depth, retries), structured logs, and alerts.
- Document limits: SMB/remote rename atomicity, cross-volume behavior, and recovery expectations.

Simpler alternatives if you don’t continue
- robocopy for robust copy/retry and near-atomic updates (no checksums, no dual-target commit):
  Example: robocopy "C:\src" "\\dst\share" file.svs /MT:8 /Z /R:5 /W:5 /COPY:DAT /DCOPY:DAT /NFL /NDL
- rsync on Windows (cwRsync/Cygwin) for checksum-verifiable copy (no dual-target, limited Windows-native lock semantics):
  Example: rsync -av --partial --append-verify --delay-updates /cygdrive/c/src/ //dst/share/

Bottom line
- If dual-target, contention-safe, Windows-native semantics with verifiable all-or-nothing delivery are must-haves, your tool fills a real gap—keep going and double down on atomic commit, verification, and recovery. If those are merely nice-to-haves, lean on rsync/robocopy/DFS-R to save engineering effort.
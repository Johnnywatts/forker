# Security Implications and Recommendations for .NET (NHS Deployment)

This document captures the full, original recommendations for running the Forker file utility as a .NET Windows Service in an NHS environment. Themes: least privilege, FIPS-aligned crypto, safe filesystem semantics, minimal network exposure, and supply-chain hygiene.

Short answer
Building this in .NET on Windows is a solid choice for NHS environments, but you must apply a few security-conscious adjustments to the design and hosting model.

Key implications and recommendations
1) Account, identity, and access
- Avoid LocalSystem unless absolutely necessary. Prefer a dedicated service account (ideally a gMSA or a virtual service account) with explicit least-privilege ACLs on source/target paths and temp directories.
- If accessing network shares, use Kerberos, disable/avoid NTLM, and configure SMB signing/encryption (SMB 3.1.1). Use UNC paths instead of drive letters.
- Ensure the share/NTFS ACLs include only the service identity (or the machine$ account, if running as LocalSystem with the computer account on the network).
- If the service needs to call downstream services on behalf of users or itself, use constrained delegation with Kerberos only; otherwise keep delegation disabled.

2) Cryptography and integrity
- Replace non-cryptographic hashes (xxHash64) with SHA-256 as the default for integrity of clinical data; keep xxHash only as a performance optimization for non-security checks with clearly documented risk.
- Confirm FIPS mode requirements. If Windows FIPS is enabled, use only FIPS-approved algorithms/providers (e.g., SHA-256 via CNG/IncrementalHash). Validate behavior on a FIPS-enabled test host.
- If tamper-evidence is required across untrusted channels, prefer HMAC-SHA-256 with a managed key or digital signatures, not bare hashes.

3) Runtime and patching strategy
- Use .NET LTS (e.g., .NET 8 LTS). Choose between:
  - Framework-dependent deployment (OS/runtime patched via Windows Update — simpler patching), or
  - Self-contained deployment (pins runtime, but you must redeploy for security patches).
- Define a monthly patch cadence with an emergency out-of-band process.

4) Service and OS hardening
- Run as a Windows Service with a Service SID and the minimum RequiredPrivileges in the service configuration; deny interactive logon.
- Use AppLocker or Windows Defender Application Control (WDAC) to allowlist the signed binaries.
- Store binaries and configs in directories with restricted ACLs; code-sign the binaries.
- Create a dedicated temp path with tight ACLs; do not use global temp.

5) Configuration and secrets
- Treat all configuration as sensitive. Use environment-scoped files with strict ACLs; if secrets are required, store them in DPAPI (ProtectedData) or a vault. Never embed secrets in code or logs.
- Validate all paths, canonicalize them, and refuse to follow reparse points/symlinks to prevent traversal or share-escape attacks.

6) Logging, telemetry, and endpoints
- Minimize PII/PHI in logs. Do not log full filenames if they can contain patient identifiers; consider hashing or tokenizing identifiers in logs.
- Rotate and protect logs; encrypt at rest if required by local policy and limit retention appropriately.
- Bind health/metrics endpoints to localhost by default; if remote access is needed, enforce authentication (Windows Auth via Http.sys or mTLS) and firewall rules. Require TLS 1.2+ and disable weak ciphers.

7) Supply-chain security
- Pin NuGet dependencies, enable package signature verification and lock files, and prefer first-party/actively maintained libraries.
- Generate an SBOM (CycloneDX or SPDX) and enable vulnerability scanning (Dependabot and GitHub Advanced Security).
- Lock down CI/CD credentials; sign releases; consider reproducible builds to improve provenance.

8) Code-level safeguards
- Stay in managed code; avoid unsafe/PInvoke unless absolutely necessary and then review thoroughly.
- Disable dynamic loading of untrusted assemblies; do not support drop-in plug-in folders.
- Use System.Text.Json with strict options (no broad polymorphic deserialization); validate and sanitize inputs.
- Implement strict error handling that does not leak sensitive paths, environment details, or host information externally.

9) Filesystem safety
- Use atomic moves only within the same volume; explicitly reject cross-volume finalize operations to avoid partial exposure.
- Open files with flags that prevent following reparse points; verify the final path using GetFinalPathNameByHandle semantics via a safe abstraction.
- Clean up temp files on startup using allowlists to avoid deleting outside the dedicated temp root.

10) Network constraints
- Default to no outbound egress. If metrics/export is needed, route through approved collectors. Document ports and destinations; enforce firewall rules.

Design deltas to apply to the current plan
- Default hashing to SHA-256; keep xxHash only as optional performance telemetry. Add a config flag: Hashing.mode = "sha256".
- Ensure verification always re-hashes the target with SHA-256 before marking VERIFIED.
- Bind /metrics and /health endpoints to localhost; add optional Windows Authentication (Http.sys) or mTLS if remote access is required.
- Add path canonicalization and a strict "do not follow reparse points" policy to the filesystem abstraction.
- Create a dedicated, ACL-restricted temp directory for staging and refuse to operate if ACLs are broader than expected.
- Add log redaction policies and a "PII-safe logging" guard.
- Prefer framework-dependent deployment on an LTS runtime unless you have a robust redeployment pipeline for self-contained patching.
- Plan for code signing, WDAC/AppLocker allowlisting, and SBOM generation in the build.

Open points to confirm
- Which exact account will run the service: LocalSystem, virtual account, or gMSA? This affects network share access design.
- Will the utility traverse network shares (UNC) or only local volumes? If network, confirm SMB policies and Kerberos-only auth.
- Is Windows FIPS mode required/enabled in your environment?
- Any requirement to expose health/metrics beyond localhost, and which authentication method is acceptable (Kerberos vs mTLS)?
- Any organizational mandates on log encryption at rest or specific retention windows.

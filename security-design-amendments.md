# Security Design Amendments (.NET) for NHS Deployment

Purpose
This document amends the design to meet NHS-style security expectations when implementing the Forker service in .NET on Windows. It emphasizes least privilege, FIPS-aligned crypto, safe filesystem semantics, minimal network exposure, and supply-chain hygiene.

Summary of key decisions
- Host as a Windows Service under a dedicated least-privilege account (prefer gMSA or virtual service account over LocalSystem).
- Default to SHA-256 for integrity; xxHash only as optional performance telemetry.
- Bind all HTTP endpoints to localhost by default; require Windows Auth or mTLS if remote access is needed.
- Do not follow reparse points/symlinks; canonicalize and confine file operations to allowlisted roots.
- Use framework-dependent deployment on .NET LTS unless you have a robust image redeploy pipeline.
- Code-sign binaries; allowlist with WDAC/AppLocker.
- Pin and scan dependencies; produce an SBOM; enable vulnerability alerts.

1) Identity, accounts, and access
- Service identity
  - Use a dedicated domain service account; prefer a group Managed Service Account (gMSA) if the service must access SMB shares using Kerberos.
  - Avoid LocalSystem unless necessary. Deny interactive logon. Constrain rights to only required local/SMB paths.
- NTFS/SMB ACLs
  - Limit read on source roots, write on target roots, and full control on the dedicated temp directory only for the service identity.
  - For SMB: enforce Kerberos (disable NTLM), SMB 3.1.1 signing/encryption per policy. Use UNC paths; avoid drive-letter mappings inside the service.
- Constrained delegation
  - If the service calls other downstream services on behalf of the identity, configure constrained delegation (Kerberos-only) explicitly; otherwise keep disabled.

2) Cryptography and integrity
- Hashing defaults
  - Use SHA-256 as the default integrity hash for clinical files. Keep xxHash as an optional performance metric only.
  - Streaming API recommendation (FIPS-appropriate on Windows):
    - Prefer IncrementalHash.CreateHash(HashAlgorithmName.SHA256) and process the stream in chunks.
- FIPS mode
  - If Windows FIPS policy is enabled, algorithms used (SHA-256) remain valid. Validate behavior on a FIPS-enabled test host.
- Optional tamper evidence
  - If integrity must be attested across untrusted hops, use HMAC-SHA-256 with a managed secret or digital signatures, not bare hashes. Store secrets outside code and never log them.

3) Filesystem safety and path handling
- Canonicalization and confinement
  - Resolve all paths to their canonical absolute form (Path.GetFullPath + normalizing trailing separators). Ensure they remain within configured allowlisted roots using OrdinalIgnoreCase comparisons on Windows.
- Reparse points
  - Deny operations on reparse points/junctions/symlinks. Detect via FileAttributes.ReparsePoint and, when opening handles, use FileOptions.OpenReparsePoint. Optionally verify final resolved path using GetFinalPathNameByHandle via SafeFileHandle.
- Atomic operations
  - Ensure temp-to-final moves are same-volume. Use File.Move for atomic rename within a volume (refuse cross-volume). Never expose partial files.
- Dedicated temp
  - Use a service-specific temp directory under each target (e.g., <target>\.forker\tmp\). Apply restrictive ACLs to this folder and refuse to operate if ACLs are broader than expected.
- Startup cleanup
  - On service start, sweep only the dedicated temp directories for orphaned temp files; never delete outside these roots.

4) Service hosting and OS hardening
- Windows Service
  - Host using .NET Worker Service (UseWindowsService). Assign a Service SID and reduce privileges; deny interact, desktop, and network logon as appropriate.
  - Configure RequiredPrivileges minimally (no SeDebugPrivilege, no unnecessary device privileges). Logon as service only.
- Code signing and allowlisting
  - Sign release binaries. Enforce WDAC or AppLocker allowlisting for the signed publisher.
- Patching strategy
  - Prefer framework-dependent deployment on .NET 8 LTS to leverage OS/runtime patching. If self-contained, institute a mandatory redeploy cadence when .NET security updates are released.

5) Configuration, secrets, and validation
- Configuration storage
  - Store appsettings and environment overrides in restricted ACL locations. Avoid secrets in config where possible.
- Secrets
  - If secrets are unavoidable, use Windows DPAPI (ProtectedData.Protect with DataProtectionScope.LocalMachine) or a vault approved by the organization. Never log secrets or derived values.
- Validation
  - Implement IValidateOptions for all configuration sections. Validate that paths exist, are canonicalized, not reparse points, and are unique. Fail fast on invalid configuration.

6) Networking, endpoints, and telemetry
- Bindings
  - Bind health and metrics endpoints to 127.0.0.1 by default. If remote access is required:
    - Prefer Windows Authentication via Http.sys with Negotiate (Kerberos) for on-prem Windows-only access, or
    - Require mTLS in Kestrel (client certificates) with firewall restrictions.
- TLS policy
  - Enforce TLS 1.2+; disable weak cipher suites. Use OS certificate stores.
- Egress control
  - Default to no outbound egress. If metrics/export is needed, route to approved collectors; document destinations and open ports explicitly.
- Logging hygiene
  - Avoid PII/PHI in logs (including patient identifiers embedded in filenames). Redact or hash identifiers in structured logs. Keep retention limited and protect logs with ACLs.

7) Supply-chain and build integrity
- Dependency hygiene
  - Pin NuGet packages (central package management). Enable package signature verification and lock files (packages.lock.json). Prefer first-party, maintained libraries.
- SBOM and scanning
  - Generate an SBOM (CycloneDX/SPDX) during build and enable Dependabot and GitHub Advanced Security code/vulnerability scanning.
- Build provenance
  - Sign artifacts, enforce branch protection, require code review, and protect CI/CD credentials. Consider reproducible build settings where feasible.

8) .NET implementation deltas to the design
- Change default hashing to SHA-256 and make verification always re-hash targets using SHA-256 before marking VERIFIED.
- Add a configuration flag: "Hashing": { "mode": "sha256" } with validation rejecting non-approved modes when FIPS is enabled.
- File system abstraction must:
  - Forbid reparse points (detect via FileAttributes/ReparsePoint and FileOptions.OpenReparsePoint).
  - Provide a GetCanonicalPath method and a GuardWithinRoots check.
  - Open files with sequential scan and no sharing beyond what is required; ensure fsync on finalized files.
- Endpoints
  - Default Kestrel to listen on localhost only. Provide an optional HttpSys hosting mode when Windows Authentication is requested.
- Observability
  - Add a log redaction utility to strip PII-like tokens from paths. Provide an on/off switch and test coverage.

9) Example configuration snippets
- appsettings.json (bindings)
{
  "Kestrel": {
    "Endpoints": {
      "Http": { "Url": "http://127.0.0.1:5008" }
    },
    "EndpointDefaults": { "Protocols": "Http1" }
  },
  "Hashing": { "mode": "sha256" }
}

- Program.cs for HttpSys (optional remote with Windows Auth)
if (useHttpSys)
{
    builder.WebHost.UseHttpSys(options =>
    {
        options.Authentication.Schemes = Microsoft.AspNetCore.Server.HttpSys.AuthenticationSchemes.Negotiate;
        options.Authentication.AllowAnonymous = false;
        options.MaxConnections = 100;
    });
}

- Streaming SHA-256 example
using var sha = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
var buffer = ArrayPool<byte>.Shared.Rent(262_144);
try
{
    int read;
    while ((read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
        sha.AppendData(buffer, 0, read);
    var digest = sha.GetCurrentHash();
}
finally { ArrayPool<byte>.Shared.Return(buffer); }

10) Deployment and operations checklist
- [ ] Dedicated service account (or gMSA) created; interactive login denied
- [ ] NTFS/SMB ACLs applied to source/target/temp paths (least privilege)
- [ ] Service installed with UseWindowsService, Service SID, minimal privileges
- [ ] Binaries code-signed; WDAC/AppLocker policy in place
- [ ] Default endpoints bound to localhost; firewall denies external access unless explicitly permitted
- [ ] TLS policy enforced (1.2+); certificates managed via OS store when remote access is required
- [ ] FIPS behavior validated on a test host (if applicable)
- [ ] Config validated at startup; reparse points disabled; allowlisted roots enforced
- [ ] Logs free of PII/PHI; rotation and retention configured; access controlled
- [ ] SBOM generated; Dependabot and GHAS scanning enabled; NuGet packages pinned
- [ ] Patch plan defined for .NET runtime and OS; redeploy policy if self-contained

Open questions
- Will the service access SMB shares (UNC paths) or only local volumes?
- Is Windows FIPS mode enabled on target servers?
- Do you require remote access to health/metrics, and if so, which authentication method (Kerberos vs mTLS)?
- Any organizational requirements for log encryption at rest or specific retention windows?
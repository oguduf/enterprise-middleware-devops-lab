# Interview walkthrough: Enterprise Middleware DevOps Lab

Use this walkthrough to explain the project in a 10–15 minute interview. Frame it as a lab implementation and distinguish tested automation behavior from unverified live middleware operations.

## 1. Problem and design (2 minutes)

“The project packages a small Java 11 Servlet application as a WAR and deploys the same immutable artifact to either WebLogic 14.1.1 or JBoss EAP 7.4. The design separates application source, environment configuration, credentials, deployment logic, and CI orchestration. Middleware administration is performed through the supported vendor clients: `weblogic.Deployer` and the JBoss management CLI.”

Explain that the runner has separate routes to the middleware management endpoint and the application's HTTP health endpoint. The app path and admin endpoint are distinct dependencies with separate access controls.

## 2. CI and artifact identity (2 minutes)

“CI runs Maven verification and the health/configuration automation tests, validates the WAR archive, computes SHA-256, and uploads the WAR, checksum, and build metadata. Deployment selects a successful workflow run by ID. The workflow checks that run's status, repository, trusted branch, event and workflow path before retrieving the artifact, then verifies the downloaded checksum and WAR structure.”

Discuss why build-once/promote-the-same-digest helps: TEST receives the bits that passed CI/DEV, rather than a rebuild that could differ. SHA-256 detects accidental or unauthorized artifact substitution when compared against a trusted manifest; for stronger supply-chain assurance, signing/attestation and protected trust roots are additional controls.

## 3. Deployment and security (3 minutes)

“The deployment workflow is manual, only runs from trusted branches, uses protected GitHub Environments, serializes deployments per environment/platform, and targets a private self-hosted Linux runner. It defaults to dry-run. Environment variables hold non-secret target settings; environment secrets deliver protected client configuration. Credentials are materialized in runner temporary storage with restrictive permissions and are not command-line password arguments.”

For WebLogic, describe the domain's AdminServer, Managed Servers, and cluster targets; `weblogic.Deployer` connects to the AdminServer and targets the requested server/cluster. For EAP, distinguish standalone deployments from domain server groups. In both cases, management success is followed by an explicit deployment state check and application readiness check.

Mention least privilege, TLS trust, network segmentation, runner patching, secret rotation, environment reviewers, artifact retention, and audit logs. Environment approvals and branch protection require repository settings; workflow YAML alone cannot enforce all organization policy.

## 4. Verification and recovery (2 minutes)

“The Python health check uses bounded retries/timeouts and requires the expected JSON readiness response. Deployment logs include command output and artifact digest. Rollback requires a previously retained WAR and matching SHA-256, and the workflow adds an explicit operator confirmation. It then uses the same platform deployment path and checks health.”

Explain operational limits: a single health URL is not a full synthetic transaction or a per-node cluster check; automation does not automatically rollback after a failure because the operator should inspect evidence and choose the intended last-known-good artifact. A production platform could add policy-driven canary/blue-green promotion and automated rollback after carefully defining safe criteria.

## 5. Testing boundary and lessons (2–3 minutes)

“Local tests exercise the Python HTTP checker with a local server, the artifact provenance validator with mocked API responses, WAR archive validation, and shell workflows using stub administration commands. This proves local control flow, input rejection, and command construction. It does not prove a live server deployment.”

Be explicit about unverified dependencies: Oracle/JBoss are not assumed installed; the exact client versions, domain targets, credentials, TLS trust, firewall routes, cluster health, and application compatibility need an authorized DEV integration test. No credentials or installation paths are invented.

Possible follow-up improvements:

- Add signed build provenance and signature verification tied to a protected identity.
- Integrate a secret manager and short-lived credentials rather than long-lived static client configuration.
- Add per-node readiness checks, smoke transactions, canary traffic shifting, and measured rollback criteria.
- Export structured logs and deployment events to a central audit/observability system.
- Test supported WebLogic/EAP patch levels in disposable integration environments and document a compatibility matrix.
- Define retention and last-known-good release policy so rollback artifacts outlive ordinary CI artifact retention.

## Likely interviewer questions

**Why Bash and Python?** Bash is a thin orchestration layer around vendor CLIs; Python provides portable HTTP checks and testable validation logic. The scripts avoid replacing supported management APIs with hand-written protocol calls.

**Why not put credentials in an env file?** Source-controlled examples are non-secret templates. Secrets are injected by the protected deployment environment and stored in restricted files where the vendor clients expect credential configuration. Production should integrate a secret manager and short-lived identity where supported.

**What does a successful deployment mean?** The admin command completed, the target deployment state is enabled/active as checked by the script, and the app's readiness endpoint returned the expected response. That still does not demonstrate every business transaction or every node's health.

**How do you avoid deploying different bits to TEST?** Select the same CI run/artifact by immutable run ID and checksum; do not rebuild between environments.

**What if health fails after the admin operation succeeded?** Preserve workflow and server evidence, determine whether the issue is application startup, target coverage, network, or health configuration, then choose a known-good artifact and deliberately roll back if appropriate. Avoid automatic repeated redeploys that could worsen a partial failure.

**What is missing before production?** Live integration validation, signed provenance, centrally managed secrets, stronger health/smoke policy, explicit change and rollback governance, monitoring/audit integration, and operational ownership for runner and middleware lifecycle.

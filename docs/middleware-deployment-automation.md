# Middleware deployment automation and GitHub Actions (Phases B–C)

These scripts deploy the Phase A WAR to WebLogic 14.1.1 or JBoss EAP 7.4 from a controlled Bash runner. They call each vendor's administration client and then require the application's `/health` endpoint to return HTTP 200 with JSON `{"status":"UP"}`. The scripts do not install, start, or configure middleware.

## Files and responsibilities

| File | Purpose |
| --- | --- |
| `scripts/deploy-common.sh` | Parses a restricted `KEY=value` file without evaluating it, validates shared settings, creates private timestamped logs, and wraps external commands. |
| `scripts/deploy-weblogic.sh` | Validates the WAR and WebLogic connection inputs, calls `weblogic.Deployer`, then runs the health check. |
| `scripts/deploy-jboss.sh` | Validates JBoss standalone/domain inputs, calls `jboss-cli.sh`, then runs the health check. |
| `scripts/health-check.py` | Retries the HTTP readiness endpoint with request timeouts and clear attempt output. |
| `scripts/validate-war.py` | Checks the WAR extension, ZIP structure, CRCs, and presence of `WEB-INF` before deployment or rollback. |
| `scripts/rollback.sh` | Verifies a supplied WAR's SHA-256 digest and sends it through the same platform deploy path. |
| `scripts/verify-ci-artifact.py` | Uses the GitHub Actions API to require a successful trusted CI run and a present, non-expired artifact before deployment. |
| `config/dev.env.example`, `config/test.env.example` | Non-secret DEV and TEST templates. Replace placeholders in local protected copies. |
| `tests/test_health_check.py` | Local HTTP-server tests for healthy, unhealthy, retry, and invalid-URL cases. |
| `tests/test_ci_artifact_validation.py` | Unit tests for CI run and artifact provenance rules. |
| `tests/test_deployment_validation.sh` | Shell tests of configuration failures, command failures, status verification, dry-run, health, and rollback validation using stubs. |
| `.github/workflows/ci.yml` | Builds/tests the app, checks WAR structure, creates SHA-256 and metadata, and uploads an immutable artifact. |
| `.github/workflows/deploy-middleware.yml` | Manually triggered deployment/rollback workflow with environment gate, trusted artifact selection, dry-run default, and private runner requirement. |

## Prerequisites

- Bash 4 or newer, Python 3, `sha256sum`, `awk`, GNU-compatible `stat`, and standard shell utilities (`date`, `mkdir`, `chmod`, `tee`) on the controlled runner. Deployment scripts check these dependencies before invoking a server administration client.
- For WebLogic, a supported Java runtime and the WebLogic 14.1.1 client libraries for `weblogic.Deployer`. The script expects `WEBLOGIC_CLASSPATH` to point at the installation-provided client JAR(s); it does not guess an Oracle Home.
- For JBoss, the JBoss EAP 7.4 `jboss-cli.sh` and its client dependencies.
- Network access from the runner to the application server's management interface and from the runner to the application's health URL. Keep management interfaces on a private network/VPN and allow only approved runner sources. Do not expose them to the public internet.
- A deployment principal with only the permissions needed to deploy to the specified target(s), and TLS trust configured for management and application endpoints.

Run the scripts on a Linux self-hosted runner or a controlled Bash environment. The project is Windows-hosted, but these Bash scripts are intended for the controlled deployment runner; paths in env files must be paths as seen by that runner.

## Configure environments

Copy the appropriate example to a local, access-controlled file and edit it. Keep the example in source control; never commit the real file, admin user config/key files, Elytron config/credential stores, or deployment logs. Values with spaces can be wrapped in matching single or double quotes. The parser accepts only known keys and a conservative character set; it does not evaluate `$`, backticks, or shell expressions. Exported process environment variables override values from the env file.

The provided files deliberately contain `REPLACE_WITH_...` values and are rejected until configured. `WEBLOGIC_TARGETS` should name the Managed Server or cluster in the domain. For JBoss standalone mode, set `JBOSS_MODE=standalone`; for domain mode, set `JBOSS_MODE=domain` and `JBOSS_SERVER_GROUPS` to the explicit server group(s). `HEALTH_URL` is the application URL including its context path. The DEV and TEST config files are intentionally separate to make environment targeting explicit.

### WebLogic credentials

WebLogic `weblogic.Deployer` supports `-userconfigfile` and `-userkeyfile`. Generate both on a trusted machine using the WebLogic 14.1.1 WLST, after connecting interactively to the correct AdminServer, with `storeUserConfig(userConfigFile='...', userKeyFile='...')`. Store the pair outside the repository, limit filesystem access to the deployment identity, and provision the matching pair for each environment. Do not put a WebLogic password on the command line. Oracle documents these files as the automated alternative to plain-text credentials ([WebLogic deployment guide](https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/depgd/deploying-applications-oracle-weblogic-server.pdf)).

### JBoss credentials

Set `JBOSS_WILDFLY_CONFIG` to a protected Elytron client `wildfly-config.xml` file which matches the management host and uses your approved authentication and TLS trust configuration. In production, reference an Elytron credential store or runner-provided secret material instead of embedding a clear password. EAP 7.4's CLI accepts `-Dwildfly.config.url=...`; the script passes this setting before connecting. Validate the file against the schema shipped with the installed EAP client. See the [EAP 7.4 client configuration guide](https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/html/development_guide/configuring_clients) and [management CLI guide](https://docs.redhat.com/en/documentation/red_hat_jboss_enterprise_application_platform/7.4/pdf/management_cli_guide/index).

## Deployment order

1. CI builds and tests the WAR; it publishes the WAR, checksum, and metadata as a named GitHub artifact. Select the run ID as the deployment's artifact source.
2. A private Linux self-hosted runner checks out deployment scripts, verifies that the source run succeeded on `main`/`dev` in this repository via push/manual dispatch, checks the named artifact is available, then downloads it and checks its SHA-256 and WAR structure.
3. The deployment workflow uses environment-scoped variables and secrets, downloads credentials only into runner temporary storage with restrictive permissions, and runs in dry-run mode by default. The selected environment must be configured with required approvals and secrets in GitHub settings.
4. For a live DEV action, set dry-run false. Scripts validate configuration and WAR contents, inspect existing deployment state, invoke the vendor admin interface, verify the resulting deployment state, then poll the health URL.
5. Review the workflow summary, script log, and server-side status/logs. Promote the same CI run and digest to TEST after its environment approval.
6. For recovery, select the prior successful CI artifact, explicitly confirm that it is the environment's last-known-good release, and invoke rollback. The script requires a valid artifact and matching SHA-256 before redeploying it.

The WAR artifact path is an explicit script argument, so an env file cannot silently redirect an invocation to a different archive. Logs contain timestamps, target names, external command output, and the WAR digest; they are created with restrictive local permissions and should still be retained/forwarded only according to your organization's log policy.

## Commands

From the repository root in Bash, after replacing placeholders and preparing credentials:

```bash
# First installation in DEV. `deploy` creates the named WebLogic deployment.
bash scripts/deploy-weblogic.sh config/dev.env middleware-demo/target/middleware-demo.war deploy

# WebLogic update to an already deployed application.
bash scripts/deploy-weblogic.sh config/dev.env middleware-demo/target/middleware-demo.war redeploy

# JBoss EAP deployment/update. --force replaces an existing deployment with the same name.
bash scripts/deploy-jboss.sh config/dev.env middleware-demo/target/middleware-demo.war

# Roll back WebLogic or JBoss to an archive whose digest you retained from CI.
bash scripts/rollback.sh weblogic config/dev.env /secure/artifacts/middleware-demo-previous.war <64-character-sha256>
bash scripts/rollback.sh jboss config/dev.env /secure/artifacts/middleware-demo-previous.war <64-character-sha256>
```

For a first JBoss deployment, the management CLI deploy command creates the deployment; on later calls `--force` replaces it. For WebLogic, choose `deploy` for first install and `redeploy` for an existing deployment. The WebLogic rollback path always uses `redeploy`, so use it when the deployment is still registered. If an application has been undeployed, restore it with the initial `deploy` command after confirming target state.

Add `--dry-run` to a deployment or rollback script to validate local configuration, credentials, and artifact without invoking the administration client or making the HTTP health request. This is suitable for confirming runner configuration before enabling live actions.

Manual health check:

```bash
python3 scripts/health-check.py --url 'https://<application-host>/middleware-demo/health' --timeout 5 --interval 5 --attempts 12
```

The script does not delete files from middleware staging directories, stop servers, or automatically revert after a failed check. A failed post-deploy health check exits non-zero and leaves evidence in the deployment log; the release operator investigates and deliberately invokes rollback after verifying the chosen artifact.

## Test locally

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_deployment_validation.sh
```

These tests use a local HTTP server and stub administration commands. They do not need Oracle/JBoss installations and intentionally do not connect to middleware. A live deployment still needs to be verified in an authorized DEV environment with the actual middleware, target, credentials, TLS, and network path.

## Enterprise CI/CD placement

CI builds once, tests once, and publishes an immutable WAR plus digest and build metadata. The manually dispatched deployment workflow verifies the source run and retrieves that exact run's artifact on a private, self-hosted runner. GitHub Environments provide environment-specific approval gates, variables, and secrets. The deployment job serializes work per environment and middleware. TEST promotion reuses the same successful CI run, preserving artifact identity. Recovery selects a prior trusted CI artifact and requires explicit rollback confirmation. This separates build provenance, environment-specific connection configuration, secret delivery, deployment, verification, promotion, and recovery.

### GitHub setup

Create GitHub Environments named exactly `DEV` and `TEST`; configure required reviewers for live deployment where appropriate. Add environment-scoped variables using the names in the workflow: `APP_HEALTH_URL`, `DEPLOY_TIMEOUT_SECONDS`, `WEBLOGIC_ADMIN_URL`, `WEBLOGIC_TARGETS`, `WEBLOGIC_CLASSPATH`, `JBOSS_HOME`, `JBOSS_CONTROLLER`, `JBOSS_MODE`, `JBOSS_SERVER_GROUPS`, and `JBOSS_CLI`. Populate the selected middleware's secret(s): base64-encoded WebLogic user config/key files (`WEBLOGIC_USER_CONFIG_B64`, `WEBLOGIC_USER_KEY_B64`) or the protected Elytron client configuration (`JBOSS_WILDFLY_CONFIG_B64`). Base64 is transport encoding, not encryption; GitHub secret storage and environment access controls protect values, and generated files are mode 600 in runner temp storage.

The deployment runner must be Linux x64, carry labels `self-hosted`, `linux`, `x64`, and `middleware-devops`, have Bash, Python 3, GNU utilities, Java/WebLogic client libraries or JBoss EAP CLI as appropriate, and reach only the approved management and application endpoints. Set `WEBLOGIC_CLASSPATH` and `JBOSS_HOME`/`JBOSS_CLI` to actual installation paths; this repository intentionally does not guess them. A normal GitHub-hosted runner cannot reach a private middleware management network. Workflow actions use pinned major/minor patch tags; keep the runner software current enough for their Node runtime requirements.

The workflow only accepts a selected artifact from a successful push/manual CI run on `main` or `dev` in this same repository. It rejects pull request artifacts, forks, wrong workflows, unsuccessful runs, missing/expired artifacts, checksum mismatch, and malformed WARs. GitHub branch protection and environment approval settings remain repository administration responsibilities. For stronger enterprise provenance, add artifact signing/attestation and verify it against a centrally managed trust policy.

For production, add signed artifact provenance, secret-manager integration, concurrency locks per application/environment, explicit change approvals, audit log forwarding, and server-side deployment health/rollback policy. The scripts provide the basic deployment primitives; they do not by themselves make an unverified server cluster safe to release to.

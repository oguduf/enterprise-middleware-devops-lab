#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
printf 'not a real archive; validation must stop before contacting a server\n' >"$TEMP_DIR/fake.war"
mkdir -p "$TEMP_DIR/bin"
cat >"$TEMP_DIR/bin/python3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TEMP_DIR/bin/python3"
export PATH="$TEMP_DIR/bin:$PATH"

run_expect_placeholder_failure() {
  local script="$1" output rc=0
  output="$(bash "$script" "$ROOT/config/dev.env.example" "$TEMP_DIR/fake.war" 2>&1)" || rc=$?
  if (( rc == 0 )); then echo "Expected placeholder configuration to be rejected: $script" >&2; exit 1; fi
  if [[ "$output" != *"still contains a placeholder"* ]]; then
    printf 'Expected a clear placeholder error from %s, got:\n%s\n' "$script" "$output" >&2
    exit 1
  fi
}

run_expect_placeholder_failure "$ROOT/scripts/deploy-weblogic.sh"
run_expect_placeholder_failure "$ROOT/scripts/deploy-jboss.sh"

# A checksum mismatch must fail before a platform command can be invoked.
actual="$(sha256sum -- "$TEMP_DIR/fake.war" | awk '{print $1}')"
wrong="0000000000000000000000000000000000000000000000000000000000000000"
[[ "$actual" != "$wrong" ]]
output="$(bash "$ROOT/scripts/rollback.sh" weblogic "$ROOT/config/dev.env.example" "$TEMP_DIR/fake.war" "$wrong" 2>&1)" && {
  echo "Expected rollback checksum mismatch to fail" >&2; exit 1;
} || rc=$?
if [[ "${output:-}" != *"SHA-256 mismatch"* ]]; then
  printf 'Expected a clear rollback checksum error, got:\n%s\n' "${output:-}" >&2
  exit 1
fi

# Exercise the deployment scripts' argument assembly with stub admin clients.
# This proves validation/logging/health-check sequencing only; it is not a
# middleware deployment test and makes no network calls.
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/secure" "$TEMP_DIR/eap"
cat >"$TEMP_DIR/bin/java" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ADMIN_CAPTURE"
if [[ "${ADMIN_FAIL:-0}" == 1 ]]; then echo "simulated unavailable middleware" >&2; exit 28; fi
if [[ " $* " == *" -listapps "* ]]; then
  [[ ! -f "$ADMIN_STATE" ]] || printf '%s\n' "${APP_NAME:-middleware-demo}"
elif [[ " $* " == *" -deploy "* || " $* " == *" -redeploy "* ]]; then
  touch "$ADMIN_STATE"
fi
STUB
cat >"$TEMP_DIR/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == *validate-war.py ]]; then
  [[ "${2:-}" == "${VALID_WAR:-}" ]] || { echo "simulated invalid WAR" >&2; exit 1; }
  exit 0
fi
printf '%s\n' "$@" >>"$HEALTH_CAPTURE"
STUB
cat >"$TEMP_DIR/bin/jboss-cli" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ADMIN_CAPTURE"
if [[ "${ADMIN_FAIL:-0}" == 1 ]]; then echo "simulated unavailable middleware" >&2; exit 28; fi
for arg in "$@"; do [[ "$arg" == --command=* ]] && command="${arg#--command=}"; done
if [[ "${command:-}" == "deployment info "* ]]; then
  if [[ "$command" == *"--server-group="* ]]; then
    printf 'NAME RUNTIME-NAME STATE\n%s middleware-demo.war enabled\n' "${APP_NAME:-middleware-demo}"
  else
    printf 'NAME RUNTIME-NAME PERSISTENT ENABLED STATUS\n%s middleware-demo.war true true OK\n' "${APP_NAME:-middleware-demo}"
  fi
fi
STUB
chmod +x "$TEMP_DIR/bin/java" "$TEMP_DIR/bin/python3" "$TEMP_DIR/bin/jboss-cli"
touch "$TEMP_DIR/secure/user.config" "$TEMP_DIR/secure/user.key" "$TEMP_DIR/secure/wildfly-config.xml"
touch "$TEMP_DIR/weblogic.jar"
chmod 600 "$TEMP_DIR/secure/user.config" "$TEMP_DIR/secure/user.key" "$TEMP_DIR/secure/wildfly-config.xml"
cat >"$TEMP_DIR/test.env" <<EOF
DEPLOY_ENV=DEV
APP_NAME=middleware-demo
HEALTH_URL=https://app.example.invalid/middleware-demo/health
HEALTH_TIMEOUT_SECONDS=5
HEALTH_INTERVAL_SECONDS=1
HEALTH_ATTEMPTS=2
DEPLOY_TIMEOUT_SECONDS=60
LOG_DIR=$TEMP_DIR/logs
WEBLOGIC_ADMIN_URL=t3s://admin.example.invalid:7002
WEBLOGIC_TARGETS=demo-cluster
WEBLOGIC_USER_CONFIG_FILE=$TEMP_DIR/secure/user.config
WEBLOGIC_USER_KEY_FILE=$TEMP_DIR/secure/user.key
WEBLOGIC_CLASSPATH=$TEMP_DIR/weblogic.jar
WEBLOGIC_ACTION=deploy
JBOSS_HOME=$TEMP_DIR/eap
JBOSS_CLI=$TEMP_DIR/bin/jboss-cli
JBOSS_CONTROLLER=remote+https://jboss.example.invalid:9993
JBOSS_MODE=standalone
JBOSS_WILDFLY_CONFIG=$TEMP_DIR/secure/wildfly-config.xml
JBOSS_RUNTIME_NAME=middleware-demo.war
EOF
export PATH="$TEMP_DIR/bin:$PATH"
export ADMIN_CAPTURE="$TEMP_DIR/admin-args" HEALTH_CAPTURE="$TEMP_DIR/health-args" ADMIN_STATE="$TEMP_DIR/wls-state"
export VALID_WAR="$TEMP_DIR/fake.war"
: >"$ADMIN_CAPTURE"; : >"$HEALTH_CAPTURE"
bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war"
grep -q -- '-deploy' "$ADMIN_CAPTURE"
grep -q -- '-userconfigfile' "$ADMIN_CAPTURE"
grep -q -- '-listapps' "$ADMIN_CAPTURE"
if grep -Eq -- '-password|--password' "$ADMIN_CAPTURE"; then echo "A password flag reached the admin command" >&2; exit 1; fi
grep -q 'health-check.py' "$HEALTH_CAPTURE"
: >"$ADMIN_CAPTURE"; : >"$HEALTH_CAPTURE"; rm -f "$ADMIN_STATE"
output="$(bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war" --dry-run 2>&1)"
[[ "$output" == *"DRY RUN"* && ! -s "$ADMIN_CAPTURE" && ! -s "$HEALTH_CAPTURE" && ! -e "$ADMIN_STATE" ]] || { echo "WebLogic dry-run invoked an admin or health command" >&2; exit 1; }

# A repeated initial deployment is rejected; the caller must request redeploy explicitly.
touch "$ADMIN_STATE"
output="$(bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected existing WebLogic deployment to require redeploy" >&2; exit 1; } || true
[[ "$output" == *"already exists; use redeploy explicitly"* ]] || { echo "WebLogic duplicate deploy was not rejected safely" >&2; exit 1; }
: >"$ADMIN_CAPTURE"; : >"$HEALTH_CAPTURE"
bash "$ROOT/scripts/deploy-jboss.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war"
grep -q -- '--force' "$ADMIN_CAPTURE"
grep -q 'deployment info middleware-demo' "$ADMIN_CAPTURE"
grep -q -- '--server-groups=' "$ADMIN_CAPTURE" && { echo "Standalone mode unexpectedly set server groups" >&2; exit 1; } || true
grep -q 'health-check.py' "$HEALTH_CAPTURE"
: >"$ADMIN_CAPTURE"; : >"$HEALTH_CAPTURE"
output="$(bash "$ROOT/scripts/deploy-jboss.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war" --dry-run 2>&1)"
[[ "$output" == *"DRY RUN"* && ! -s "$ADMIN_CAPTURE" && ! -s "$HEALTH_CAPTURE" ]] || { echo "JBoss dry-run invoked an admin or health command" >&2; exit 1; }

# Domain mode verifies each explicitly selected server group.
sed -e 's/^JBOSS_MODE=standalone$/JBOSS_MODE=domain/' -e 's#^JBOSS_RUNTIME_NAME=.*#JBOSS_RUNTIME_NAME=middleware-demo.war\nJBOSS_SERVER_GROUPS=group-a,group-b#' "$TEMP_DIR/test.env" >"$TEMP_DIR/domain.env"
: >"$ADMIN_CAPTURE"; : >"$HEALTH_CAPTURE"
bash "$ROOT/scripts/deploy-jboss.sh" "$TEMP_DIR/domain.env" "$TEMP_DIR/fake.war"
[[ "$(grep -c 'deployment info --server-group=' "$ADMIN_CAPTURE")" -eq 2 ]] || { echo "Domain deployment did not check both server groups" >&2; exit 1; }

# Invalid environment configuration and missing credentials fail before admin clients run.
sed 's/^DEPLOY_ENV=DEV$/DEPLOY_ENV=PROD/' "$TEMP_DIR/test.env" >"$TEMP_DIR/invalid-env.env"
: >"$ADMIN_CAPTURE"
output="$(bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/invalid-env.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected invalid environment to fail" >&2; exit 1; } || true
[[ "$output" == *"DEPLOY_ENV must be DEV or TEST"* && ! -s "$ADMIN_CAPTURE" ]] || { echo "Invalid config was not rejected before admin invocation" >&2; exit 1; }

sed "s#^WEBLOGIC_USER_CONFIG_FILE=.*#WEBLOGIC_USER_CONFIG_FILE=$TEMP_DIR/secure/missing.config#" "$TEMP_DIR/test.env" >"$TEMP_DIR/missing-weblogic-credential.env"
output="$(bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/missing-weblogic-credential.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected missing WebLogic credentials to fail" >&2; exit 1; } || true
[[ "$output" == *"must be a readable file"* && ! -s "$ADMIN_CAPTURE" ]] || { echo "Missing WebLogic credentials were not rejected before admin invocation" >&2; exit 1; }

sed "s#^JBOSS_WILDFLY_CONFIG=.*#JBOSS_WILDFLY_CONFIG=$TEMP_DIR/secure/missing-wildfly.xml#" "$TEMP_DIR/test.env" >"$TEMP_DIR/missing-jboss-credential.env"
output="$(bash "$ROOT/scripts/deploy-jboss.sh" "$TEMP_DIR/missing-jboss-credential.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected missing JBoss credentials to fail" >&2; exit 1; } || true
[[ "$output" == *"must be a readable file"* && ! -s "$ADMIN_CAPTURE" ]] || { echo "Missing JBoss credentials were not rejected before admin invocation" >&2; exit 1; }

# Simulated management-client failures must be non-zero and must prevent the health-check phase.
export ADMIN_FAIL=1
: >"$HEALTH_CAPTURE"
output="$(bash "$ROOT/scripts/deploy-weblogic.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected WebLogic client failure" >&2; exit 1; } || true
[[ "$output" == *"Administration command failed"* && ! -s "$HEALTH_CAPTURE" ]] || { echo "WebLogic failure handling did not stop before health check" >&2; exit 1; }
: >"$HEALTH_CAPTURE"
output="$(bash "$ROOT/scripts/deploy-jboss.sh" "$TEMP_DIR/test.env" "$TEMP_DIR/fake.war" 2>&1)" && { echo "Expected JBoss client failure" >&2; exit 1; } || true
[[ "$output" == *"Administration command failed"* && ! -s "$HEALTH_CAPTURE" ]] || { echo "JBoss failure handling did not stop before health check" >&2; exit 1; }
unset ADMIN_FAIL

# A non-archive named .war is rejected before rollback can call an admin client.
printf 'not a war archive\n' >"$TEMP_DIR/bad.war"
bad_digest="$(sha256sum -- "$TEMP_DIR/bad.war" | awk '{print $1}')"
output="$(bash "$ROOT/scripts/rollback.sh" jboss "$TEMP_DIR/test.env" "$TEMP_DIR/bad.war" "$bad_digest" 2>&1)" && { echo "Expected malformed rollback WAR to fail" >&2; exit 1; } || true
[[ "$output" == *"WAR artifact validation failed"* ]] || { echo "Malformed rollback WAR was not rejected" >&2; exit 1; }

echo "Deployment validation, credential/config failures, unavailable-client handling, and rollback artifact checks passed using stubs (no middleware contacted)."

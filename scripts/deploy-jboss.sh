#!/usr/bin/env bash
# Deploy a WAR to JBoss EAP 7.4 through the supported management CLI.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

usage() { echo "Usage: $0 <environment.env> <application.war> [--dry-run]" >&2; exit 2; }
(( $# >= 2 && $# <= 3 )) || usage
ENV_FILE="$1"
export WAR_FILE="$2"
DRY_RUN=false
if [[ "${3:-}" == --dry-run ]]; then DRY_RUN=true; elif [[ -n "${3:-}" ]]; then usage; fi
load_env_file "$ENV_FILE"
validate_common
validate_war

require_value JBOSS_HOME
[[ -d "$JBOSS_HOME" ]] || die "JBOSS_HOME must be an existing directory: $JBOSS_HOME"
require_value JBOSS_CONTROLLER
[[ "$JBOSS_CONTROLLER" =~ ^(remote\+https?|https?)://[^[:space:]]+$ ]] || die "JBOSS_CONTROLLER must be a remote/http(s) management URL"
require_private_file JBOSS_WILDFLY_CONFIG
JBOSS_MODE="${JBOSS_MODE:-standalone}"
case "$JBOSS_MODE" in
  standalone) ;;
  domain)
    require_value JBOSS_SERVER_GROUPS
    [[ "$JBOSS_SERVER_GROUPS" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || die "JBOSS_SERVER_GROUPS must be a comma-separated list"
    ;;
  *) die "JBOSS_MODE must be standalone or domain" ;;
esac
JBOSS_RUNTIME_NAME="${JBOSS_RUNTIME_NAME:-$APP_NAME.war}"
[[ "$JBOSS_RUNTIME_NAME" =~ ^[A-Za-z0-9_.-]+\.war$ ]] || die "JBOSS_RUNTIME_NAME must be a safe .war filename"
JBOSS_CLI="${JBOSS_CLI:-$JBOSS_HOME/bin/jboss-cli.sh}"
[[ -x "$JBOSS_CLI" ]] || die "JBOSS_CLI must point to an executable management CLI: $JBOSS_CLI"

start_log jboss-deploy
log INFO "Mode: $JBOSS_MODE; controller: $JBOSS_CONTROLLER; deployment: $APP_NAME"
if [[ "$DRY_RUN" == true ]]; then
  log INFO "DRY RUN: configuration and WAR validated; no middleware command or health request was made"
  exit 0
fi

DEPLOY_COMMAND="deploy --force --name=$APP_NAME --runtime-name=$JBOSS_RUNTIME_NAME"
if [[ "$JBOSS_MODE" == domain ]]; then DEPLOY_COMMAND+=" --server-groups=$JBOSS_SERVER_GROUPS"; fi
# The shared config parser rejects quotes and shell metacharacters in values.
DEPLOY_COMMAND+=" \"$WAR_FILE\""
run_logged "$JBOSS_CLI" "-Dwildfly.config.url=$JBOSS_WILDFLY_CONFIG" \
  --command-timeout="$DEPLOY_TIMEOUT_SECONDS" \
  --connect "--controller=$JBOSS_CONTROLLER" --command="$DEPLOY_COMMAND"

jboss_cli() {
  "$JBOSS_CLI" "-Dwildfly.config.url=$JBOSS_WILDFLY_CONFIG" \
    --command-timeout="$DEPLOY_TIMEOUT_SECONDS" \
    --connect "--controller=$JBOSS_CONTROLLER" --command="$1"
}
if [[ "$JBOSS_MODE" == standalone ]]; then
  capture_logged deployment_status jboss_cli "deployment info $APP_NAME"
  if ! awk -v name="$APP_NAME" '$1 == name && $4 == "true" && $5 == "OK" { found=1 } END { exit(found ? 0 : 1) }' <<<"$deployment_status"; then
    die "JBoss deployment '$APP_NAME' is not enabled with status OK"
  fi
else
  IFS=, read -r -a SERVER_GROUPS <<<"$JBOSS_SERVER_GROUPS"
  for server_group in "${SERVER_GROUPS[@]}"; do
    capture_logged deployment_status jboss_cli "deployment info --server-group=$server_group"
    if ! awk -v name="$APP_NAME" '$1 == name && $3 == "enabled" { found=1 } END { exit(found ? 0 : 1) }' <<<"$deployment_status"; then
      die "JBoss deployment '$APP_NAME' is not enabled in server group '$server_group'"
    fi
  done
fi
log INFO "JBoss deployment status verified"

log INFO "Deployment command completed; checking application health"
run_logged python3 "$SCRIPT_DIR/health-check.py" \
  --url "$HEALTH_URL" --timeout "$HEALTH_TIMEOUT_SECONDS" \
  --interval "$HEALTH_INTERVAL_SECONDS" --attempts "$HEALTH_ATTEMPTS"
log INFO "JBoss EAP deployment and health check succeeded"

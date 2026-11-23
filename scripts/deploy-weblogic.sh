#!/usr/bin/env bash
# Deploy a WAR to WebLogic 14.1.1 using its weblogic.Deployer administration tool.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

usage() { echo "Usage: $0 <environment.env> <application.war> [deploy|redeploy] [--dry-run]" >&2; exit 2; }
(( $# >= 2 && $# <= 4 )) || usage
ENV_FILE="$1"
export WAR_FILE="$2"
load_env_file "$ENV_FILE"
DRY_RUN=false
ACTION_OVERRIDE=""
for option in "${@:3}"; do
  case "$option" in
    deploy|redeploy) [[ -z "$ACTION_OVERRIDE" ]] || usage; ACTION_OVERRIDE="$option" ;;
    --dry-run) [[ "$DRY_RUN" == false ]] || usage; DRY_RUN=true ;;
    *) usage ;;
  esac
done
[[ -z "$ACTION_OVERRIDE" ]] || export WEBLOGIC_ACTION="$ACTION_OVERRIDE"
validate_common
validate_war

require_value WEBLOGIC_ADMIN_URL
[[ "$WEBLOGIC_ADMIN_URL" =~ ^(t3s?|https?)://[^[:space:]]+$ ]] || die "WEBLOGIC_ADMIN_URL must be a t3/t3s/http/https URL"
require_value WEBLOGIC_TARGETS
[[ "$WEBLOGIC_TARGETS" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || die "WEBLOGIC_TARGETS must be a comma-separated list of target names"
require_private_file WEBLOGIC_USER_CONFIG_FILE
require_private_file WEBLOGIC_USER_KEY_FILE
require_value WEBLOGIC_CLASSPATH
IFS=: read -r -a WEBLOGIC_CLASSPATH_ENTRIES <<<"$WEBLOGIC_CLASSPATH"
for classpath_entry in "${WEBLOGIC_CLASSPATH_ENTRIES[@]}"; do
  [[ -e "$classpath_entry" && -r "$classpath_entry" ]] || die "WebLogic classpath entry is not readable: $classpath_entry"
done
WEBLOGIC_JAVA="${WEBLOGIC_JAVA:-java}"
command -v -- "$WEBLOGIC_JAVA" >/dev/null 2>&1 || die "Java executable not found: $WEBLOGIC_JAVA"
WEBLOGIC_ACTION="${WEBLOGIC_ACTION:-deploy}"
case "$WEBLOGIC_ACTION" in deploy) ACTION=-deploy ;; redeploy) ACTION=-redeploy ;; *) die "WEBLOGIC_ACTION must be deploy or redeploy" ;; esac

start_log weblogic-deploy
log INFO "Target(s): $WEBLOGIC_TARGETS; deployment name: $APP_NAME; action: $WEBLOGIC_ACTION"
if [[ "$DRY_RUN" == true ]]; then
  log INFO "DRY RUN: configuration and WAR validated; no middleware command or health request was made"
  exit 0
fi

deployer=("$WEBLOGIC_JAVA" -cp "$WEBLOGIC_CLASSPATH" weblogic.Deployer
  -adminurl "$WEBLOGIC_ADMIN_URL"
  -userconfigfile "$WEBLOGIC_USER_CONFIG_FILE"
  -userkeyfile "$WEBLOGIC_USER_KEY_FILE")
capture_logged deployed_before "${deployer[@]}" -listapps
already_deployed=false
if awk -v name="$APP_NAME" '$1 == name { found=1 } END { exit(found ? 0 : 1) }' <<<"$deployed_before"; then already_deployed=true; fi
if [[ "$WEBLOGIC_ACTION" == deploy && "$already_deployed" == true ]]; then
  die "Application '$APP_NAME' already exists; use redeploy explicitly"
fi
if [[ "$WEBLOGIC_ACTION" == redeploy && "$already_deployed" == false ]]; then
  die "Application '$APP_NAME' is not deployed; use deploy for the initial installation"
fi

run_logged "$WEBLOGIC_JAVA" -cp "$WEBLOGIC_CLASSPATH" weblogic.Deployer \
  -adminurl "$WEBLOGIC_ADMIN_URL" \
  -userconfigfile "$WEBLOGIC_USER_CONFIG_FILE" \
  -userkeyfile "$WEBLOGIC_USER_KEY_FILE" \
  "$ACTION" -name "$APP_NAME" -source "$WAR_FILE" \
  -targets "$WEBLOGIC_TARGETS" -upload -stage \
  -timeout "$DEPLOY_TIMEOUT_SECONDS" -verbose

capture_logged deployed_after "${deployer[@]}" -listapps
if ! awk -v name="$APP_NAME" '$1 == name { found=1 } END { exit(found ? 0 : 1) }' <<<"$deployed_after"; then
  die "WebLogic deployment '$APP_NAME' was not present in -listapps after the deployment command"
fi
log INFO "WebLogic deployment '$APP_NAME' is registered in the domain"

log INFO "Deployment command completed; checking application health"
run_logged python3 "$SCRIPT_DIR/health-check.py" \
  --url "$HEALTH_URL" --timeout "$HEALTH_TIMEOUT_SECONDS" \
  --interval "$HEALTH_INTERVAL_SECONDS" --attempts "$HEALTH_ATTEMPTS"
log INFO "WebLogic deployment and health check succeeded"

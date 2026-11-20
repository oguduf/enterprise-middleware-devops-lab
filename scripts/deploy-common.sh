#!/usr/bin/env bash
# Shared validation, configuration parsing, and logging for deployment scripts.
set -Eeuo pipefail
umask 077

DEPLOY_COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
  local level="$1"; shift
  local line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
  printf '%s\n' "$line" >&2
  if [[ -n "${DEPLOY_LOG_FILE:-}" ]]; then printf '%s\n' "$line" >>"$DEPLOY_LOG_FILE"; fi
}

die() { log ERROR "$*"; exit 1; }

require_cmd() {
  command -v -- "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

start_log() {
  local label="$1"; local env_name="${DEPLOY_ENV:-unknown}"
  local log_dir="${LOG_DIR:-$DEPLOY_COMMON_DIR/../logs}"
  mkdir -p -- "$log_dir" || die "Cannot create log directory: $log_dir"
  DEPLOY_LOG_FILE="$log_dir/${label}-${env_name}-$(date -u '+%Y%m%dT%H%M%SZ')-$$.log"
  export DEPLOY_LOG_FILE
  : >"$DEPLOY_LOG_FILE" || die "Cannot write deployment log: $DEPLOY_LOG_FILE"
  chmod 600 "$DEPLOY_LOG_FILE" 2>/dev/null || true
  log INFO "Starting $label for environment '$env_name'"
  log INFO "Detailed log: $DEPLOY_LOG_FILE"
}

run_logged() {
  log INFO "Running administration command"
  local rc=0
  "$@" 2>&1 | tee -a "$DEPLOY_LOG_FILE" || rc=$?
  if (( rc != 0 )); then die "Administration command failed with exit code $rc (see $DEPLOY_LOG_FILE)"; fi
}

capture_logged() {
  local destination="$1" output rc=0
  shift
  output="$("$@" 2>&1)" || rc=$?
  [[ -z "$output" ]] || printf '%s\n' "$output" | tee -a "$DEPLOY_LOG_FILE"
  if (( rc != 0 )); then die "Administration command failed with exit code $rc (see $DEPLOY_LOG_FILE)"; fi
  printf -v "$destination" '%s' "$output"
}

require_value() {
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || die "Required configuration is missing: $name"
  if [[ "$value" == *REPLACE_WITH* || "$value" == *CHANGE_ME* ]]; then die "$name still contains a placeholder; edit the environment file first"; fi
}

require_file() {
  local name="$1" path="${!1:-}"
  require_value "$name"
  [[ -f "$path" && -r "$path" ]] || die "$name must be a readable file: $path"
}

require_private_file() {
  local name="$1" path="${!1:-}" mode permissions
  require_file "$name"
  mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || die "Cannot inspect permissions on $name: $path"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "Cannot interpret permissions for $name: $mode"
  permissions=$((8#$mode))
  (( (permissions & 077) == 0 )) || die "$name is accessible by group/others; restrict it (for example chmod 600): $path"
}

validate_token() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$name contains unsupported characters"
}

validate_env_name() {
  case "${DEPLOY_ENV:-}" in DEV|TEST) ;; *) die "DEPLOY_ENV must be DEV or TEST" ;; esac
}

# Parse a deliberately small KEY=value format without evaluating shell code.
# Values may be unquoted or enclosed in matching single/double quotes. Shell
# expansion, command substitution, and control characters are rejected.
load_env_file() {
  local file="$1" line key value line_no=0
  [[ -f "$file" && -r "$file" ]] || die "Environment file is not readable: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_no+=1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "Invalid configuration syntax at $file:$line_no"
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    value="${value%$'\r'}"
    if (( ${#value} >= 2 )) && { [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] || [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; }; then
      value="${value:1:${#value}-2}"
    fi
    [[ "$value" =~ ^[A-Za-z0-9_./:@,+%\ -]*$ ]] || die "Unsupported characters in $key at $file:$line_no"
    case "$key" in
      DEPLOY_ENV|APP_NAME|WAR_FILE|HEALTH_URL|HEALTH_TIMEOUT_SECONDS|HEALTH_INTERVAL_SECONDS|HEALTH_ATTEMPTS|LOG_DIR|DEPLOY_TIMEOUT_SECONDS|WEBLOGIC_ADMIN_URL|WEBLOGIC_TARGETS|WEBLOGIC_USER_CONFIG_FILE|WEBLOGIC_USER_KEY_FILE|WEBLOGIC_CLASSPATH|WEBLOGIC_JAVA|WEBLOGIC_ACTION|JBOSS_HOME|JBOSS_CLI|JBOSS_CONTROLLER|JBOSS_MODE|JBOSS_SERVER_GROUPS|JBOSS_WILDFLY_CONFIG|JBOSS_RUNTIME_NAME)
        # Explicitly supplied process environment takes precedence over file values.
        if [[ ! -v "$key" ]]; then printf -v "$key" '%s' "$value"; export "$key"; fi
        ;;
      *) die "Unknown configuration key '$key' at $file:$line_no" ;;
    esac
  done <"$file"
}

validate_positive_integer() {
  local name="$1" value="${!1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) || die "$name must be a positive integer"
}

validate_war() {
  require_cmd date
  require_cmd python3
  require_cmd sha256sum
  require_cmd awk
  require_file WAR_FILE
  [[ "$WAR_FILE" == *.war ]] || die "WAR_FILE must end in .war"
  [[ -s "$WAR_FILE" ]] || die "WAR_FILE is empty: $WAR_FILE"
  python3 "$DEPLOY_COMMON_DIR/validate-war.py" "$WAR_FILE" || die "WAR artifact validation failed: $WAR_FILE"
  local digest
  digest="$(sha256sum -- "$WAR_FILE" | awk '{print $1}')"
  log INFO "WAR: $WAR_FILE (sha256=$digest)"
}

validate_common() {
  local dependency
  for dependency in date mkdir chmod tee sha256sum awk stat python3; do require_cmd "$dependency"; done
  validate_env_name
  require_value APP_NAME; validate_token APP_NAME
  require_value HEALTH_URL
  [[ "$HEALTH_URL" =~ ^https?://[^[:space:]]+$ ]] || die "HEALTH_URL must be an http(s) URL"
  validate_positive_integer HEALTH_TIMEOUT_SECONDS
  validate_positive_integer HEALTH_INTERVAL_SECONDS
  validate_positive_integer HEALTH_ATTEMPTS
  validate_positive_integer DEPLOY_TIMEOUT_SECONDS
}

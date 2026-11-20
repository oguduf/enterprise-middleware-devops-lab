#!/usr/bin/env bash
# Redeploy a known-good archive after verifying its supplied SHA-256 digest.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

usage() { echo "Usage: $0 <weblogic|jboss> <environment.env> <verified.war> <sha256> [--dry-run]" >&2; exit 2; }
(( $# == 4 || $# == 5 )) || usage
platform="$1" env_file="$2" war="$3" expected_digest="$4" dry_run="${5:-}"
[[ "$platform" == weblogic || "$platform" == jboss ]] || usage
[[ -z "$dry_run" || "$dry_run" == --dry-run ]] || usage
[[ "$expected_digest" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Expected digest must be a 64-character SHA-256 hex value"
export WAR_FILE="$war"
validate_war
actual_digest="$(sha256sum -- "$WAR_FILE" | awk '{print $1}')"
[[ "${actual_digest,,}" == "${expected_digest,,}" ]] || die "Rollback WAR SHA-256 mismatch; refusing to deploy it"
log INFO "Rollback artifact SHA-256 verified: $actual_digest"

case "$platform" in
  weblogic)
    if [[ "$dry_run" == --dry-run ]]; then exec "$SCRIPT_DIR/deploy-weblogic.sh" "$env_file" "$war" redeploy --dry-run
    else exec "$SCRIPT_DIR/deploy-weblogic.sh" "$env_file" "$war" redeploy; fi
    ;;
  jboss)
    if [[ "$dry_run" == --dry-run ]]; then exec "$SCRIPT_DIR/deploy-jboss.sh" "$env_file" "$war" --dry-run
    else exec "$SCRIPT_DIR/deploy-jboss.sh" "$env_file" "$war"; fi
    ;;
esac

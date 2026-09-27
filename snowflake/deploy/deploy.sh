#!/usr/bin/env bash
# Deploy all manifest scripts to one environment with SnowSQL variable substitution.
# Usage: snowflake/deploy/deploy.sh <ENV> [--from <path>] [--dry-run]
#   Connection comes from ~/.snowsql/config [connections.cv_<env>] (key-pair auth, SVC_<ENV>_CICD).
#   Account-level scripts need an admin connection: set SNOWSQL_CONN_ADMIN for the first 9 entries.
set -euo pipefail

ENV="${1:?usage: deploy.sh DEV|QA|PROD [--from path] [--dry-run]}"; shift || true
FROM=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONN="cv_$(echo "$ENV" | tr '[:upper:]' '[:lower:]')"
: "${AZURE_TENANT_ID:?set AZURE_TENANT_ID}"
: "${ADLS_ACCOUNT:?set ADLS_ACCOUNT (e.g. stcvlakeprod)}"
: "${PHI_SALT_REF:?set PHI_SALT_REF (Key Vault-sourced salt reference)}"

started=$([[ -z "$FROM" ]] && echo 1 || echo 0)
grep -vE '^\s*(#|$|manual:)' "$HERE/deploy/manifest.txt" | while read -r rel; do
  [[ "$rel" == "$FROM" ]] && started=1
  [[ "$started" == 1 ]] || continue
  echo ">>> [$ENV] $rel"
  [[ "$DRY" == 1 ]] && continue
  snowsql -c "$CONN" -o exit_on_error=true -o variable_substitution=true -o friendly=false -o quiet=true \
    -D ENV="$ENV" -D AZURE_TENANT_ID="$AZURE_TENANT_ID" -D ADLS_ACCOUNT="$ADLS_ACCOUNT" -D PHI_SALT_REF="$PHI_SALT_REF" \
    -f "$HERE/$rel"
done
echo "deploy complete: $ENV"

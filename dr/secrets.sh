#!/usr/bin/env bash
# Creates the break-glass secrets for one drill run: S3 identities, the
# object store's SSE master key, the Velero/Kopia repository password and the
# database password. They are random per run, written outside the repository
# (mode 600) and masked in GitHub Actions logs. In production these live in a
# password manager or secret store that does not depend on the cluster.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ -f "$DR_SECRETS_FILE" ]]; then
  log "secrets already exist at $DR_SECRETS_FILE"
  exit 0
fi

mkdir -p "$(dirname "$DR_SECRETS_FILE")"
chmod 700 "$(dirname "$DR_SECRETS_FILE")"
umask 077

rand() { openssl rand -hex "$1"; }
{
  echo "S3_ADMIN_ACCESS_KEY=admin$(rand 8)"
  echo "S3_ADMIN_SECRET_KEY=$(rand 24)"
  echo "S3_VELERO_ACCESS_KEY=velero$(rand 8)"
  echo "S3_VELERO_SECRET_KEY=$(rand 24)"
  echo "S3_CNPG_ACCESS_KEY=cnpg$(rand 8)"
  echo "S3_CNPG_SECRET_KEY=$(rand 24)"
  echo "SSE_KEK=$(rand 32)"
  echo "VELERO_REPO_PASSWORD=$(rand 24)"
  echo "DB_APP_PASSWORD=$(rand 24)"
} >"$DR_SECRETS_FILE"

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  while IFS='=' read -r _ value; do
    echo "::add-mask::${value}"
  done <"$DR_SECRETS_FILE"
fi
log "created secrets in $DR_SECRETS_FILE"

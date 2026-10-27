#!/usr/bin/env bash
# First deployment of the stateful workload: namespace, secrets, ObjectStore,
# the CNPG cluster (initdb), the daily ScheduledBackup, the ledger API and
# its NetworkPolicies. Ends with a verified first base backup.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
secrets_load

SERVER_NAME=pg-g1

kubectl apply -f "$ROOT/deploy/ledger/namespace.yaml" >/dev/null

# Secrets are labelled so Velero backs them up with the namespace.
kubectl -n "$NS" create secret generic ledger-db-credentials --type=kubernetes.io/basic-auth \
  --from-literal=username=app --from-literal=password="$DB_APP_PASSWORD" --dry-run=client -o yaml |
  kubectl label --local -f - app.kubernetes.io/part-of=ledger -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic pg-backup-s3 \
  --from-literal=ACCESS_KEY_ID="$S3_CNPG_ACCESS_KEY" --from-literal=ACCESS_SECRET_KEY="$S3_CNPG_SECRET_KEY" \
  --from-literal=REGION=us-east-1 --dry-run=client -o yaml |
  kubectl label --local -f - app.kubernetes.io/part-of=ledger -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f "$ROOT/deploy/ledger/objectstore.yaml" >/dev/null
# shellcheck disable=SC2016  # envsubst takes the variable list literally
PG_IMAGE=$PG_IMAGE SERVER_NAME=$SERVER_NAME envsubst '${PG_IMAGE} ${SERVER_NAME}' \
  <"$ROOT/deploy/ledger/cluster.yaml" | kubectl apply -f - >/dev/null
kubectl apply -f "$ROOT/deploy/ledger/scheduledbackup.yaml" -f "$ROOT/deploy/ledger/networkpolicy.yaml" >/dev/null
# shellcheck disable=SC2016
APP_IMAGE=$APP_IMAGE envsubst '${APP_IMAGE}' <"$ROOT/deploy/ledger/app.yaml" | kubectl apply -f - >/dev/null

t0=$(now)
wait_cluster_ready 600
log "PostgreSQL ready in $(secs "$t0" "$(now)")s"
wait_app_writing "$t0" 300
log "ledger-api writing"

# End-to-end proof that WAL reaches the bucket: close a segment, wait for it.
archive_current_wal
log "continuous WAL archiving active (serverName $SERVER_NAME)"

take_base_backup base-initial
state_set SERVER_NAME "$SERVER_NAME"

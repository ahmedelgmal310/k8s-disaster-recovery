#!/usr/bin/env bash
# Shared helpers and pinned versions for the DR scripts. Source, do not run.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=ledger
RESULTS_DIR="${RESULTS_DIR:-$ROOT/dr-results}"
STATE_FILE="$RESULTS_DIR/state.env"
# Break-glass secrets live outside the repository and outside the uploaded
# results directory.
DR_SECRETS_FILE="${DR_SECRETS_FILE:-${RUNNER_TEMP:-/tmp}/dr-secrets/secrets.env}"
mkdir -p "$RESULTS_DIR"

# ---- pins (indexed in docs/versions.md) ------------------------------------
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed}"
PG_IMAGE="${PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.6-202610120828-minimal-trixie@sha256:c9be7f221a05b18fe65259d9136affbabe3b39ad91c3b68f8f2f990a45f35f38}"
SEAWEEDFS_IMAGE="${SEAWEEDFS_IMAGE:-chrislusf/seaweedfs:4.48@sha256:4e61d15fd35994cb1e43e1e553dff106794841fd9a99ade2fc8c8bfce4d7872d}"
APP_IMAGE="${APP_IMAGE:-ledger-api:ci}"

CERT_MANAGER_VERSION=v1.21.2
CERT_MANAGER_SHA256=e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f
CNPG_VERSION=1.30.1
CNPG_SHA256=37237f145d8138256ea25ae830f87759255665ff08f8d552fdd8224a5ec032fb
CNPG_IMAGE="ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1@sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07"
BARMAN_VERSION=v0.15.1
BARMAN_SHA256=8f377ff4a7d0d3f74fc64b0f7ac4f449fc38ca9e83a40107cca2f9315a9bd920
BARMAN_IMAGE="ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.15.1@sha256:c75acad19a36e8176cfe2885761ff1b836c6ef977d7257e298c99a28b5c302ef"
BARMAN_SIDECAR_IMAGE="ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.1@sha256:2287a793a804db751edd0d07d44cd549e357677e98a800eb12e2cf7c0d53f9b0"
VELERO_CHART_VERSION=12.2.0

# ---- targets: a drill fails when it misses one -----------------------------
RTO_TARGET_NAMESPACE="${RTO_TARGET_NAMESPACE:-300}"   # seconds
RTO_TARGET_PITR="${RTO_TARGET_PITR:-300}"
RTO_TARGET_CLUSTER="${RTO_TARGET_CLUSTER:-900}"
RPO_TARGET_PITR="${RPO_TARGET_PITR:-1}"               # seconds of committed data lost
RPO_TARGET_LOSS="${RPO_TARGET_LOSS:-60}"              # abrupt loss: bounded by archive_timeout (15s)

# ---- logging and time -------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() {
  log "FAIL: $*"
  exit 1
}
group() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::group::$*" || log "== $*"; }
endgroup() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::endgroup::" || true; }

# Epoch seconds with millisecond precision.
now() { date -u +%s.%3N; }
# b - a, one decimal.
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# max(0, b - a), three decimals (for data-loss windows).
gap() { awk -v a="$1" -v b="$2" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.3f", d }'; }
# Succeeds when $1 <= $2.
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }

# retry TIMEOUT_SECONDS DESCRIPTION CMD... : run CMD every 2s until it succeeds.
retry() {
  local timeout=$1 desc=$2
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      log "timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 2
  done
}

# ---- state shared between drills -------------------------------------------
state_set() {
  touch "$STATE_FILE"
  sed -i "/^$1=/d" "$STATE_FILE"
  printf '%s=%q\n' "$1" "$2" >>"$STATE_FILE"
}
state_load() {
  # shellcheck disable=SC1090
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  return 0
}
secrets_load() {
  [[ -f "$DR_SECRETS_FILE" ]] || die "secrets file $DR_SECRETS_FILE missing (run dr/secrets.sh)"
  # shellcheck disable=SC1090
  source "$DR_SECRETS_FILE"
}

# Next archive folder: pg-g1 -> pg-g2. Each recovery opens a new timeline and
# must not archive into the folder it restored from.
next_server() { echo "pg-g$((${1#pg-g} + 1))"; }

# ---- downloads ----------------------------------------------------------------
fetch_verified() { # URL SHA256 DEST
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || die "checksum mismatch for $1"
}

# ---- Kubernetes helpers -------------------------------------------------------
primary_pod() { kubectl get cluster pg -n "$NS" -o jsonpath='{.status.currentPrimary}'; }

# psql as the postgres OS user inside the primary (local peer authentication).
psql_app() {
  local pod
  pod=$(primary_pod)
  [[ -n "$pod" ]] || die "no primary pod"
  kubectl exec -n "$NS" "$pod" -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -d app -tA "$@"
}

# The ledger API through the API server's service proxy (no port-forward).
api_get() { kubectl get --raw "/api/v1/namespaces/$NS/services/http:ledger-api:http/proxy$1"; }
api_post() { echo '{}' | kubectl create --raw "/api/v1/namespaces/$NS/services/http:ledger-api:http/proxy$1" -f -; }

cluster_ready() {
  [[ "$(kubectl get cluster pg -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

wait_cluster_ready() { # TIMEOUT
  retry "$1" "CNPG cluster pg Ready" cluster_ready || {
    kubectl get cluster,pods,jobs -n "$NS" -o wide || true
    die "cluster pg not Ready within $1s"
  }
}

# Succeeds once the API is ready and has committed a row after epoch $1.
app_writing_since() {
  local stats ack
  api_get /readyz >/dev/null || return 1
  stats=$(api_get /api/stats) || return 1
  ack=$(jq -r '.last_ack_at // empty' <<<"$stats")
  [[ -n "$ack" ]] || return 1
  awk -v a="$(date -u -d "$ack" +%s.%3N)" -v b="$1" 'BEGIN { exit !(a > b) }'
}

wait_app_writing() { # SINCE_EPOCH TIMEOUT
  retry "$2" "ledger-api ready and writing" app_writing_since "$1" || {
    kubectl get pods -n "$NS" -o wide || true
    kubectl logs -n "$NS" deploy/ledger-api --tail=50 || true
    die "ledger-api not writing within $2s"
  }
}

backup_phase() { kubectl get backups.postgresql.cnpg.io "$1" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null; }

# On-demand CNPG base backup through the Barman Cloud plugin.
take_base_backup() { # NAME
  local name=$1 deadline=$((SECONDS + 600)) phase
  kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: ${NS}
spec:
  cluster:
    name: pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  while :; do
    phase=$(backup_phase "$name")
    case "$phase" in
      completed) break ;;
      failed)
        kubectl get backups.postgresql.cnpg.io "$name" -n "$NS" -o yaml
        die "base backup $name failed"
        ;;
    esac
    ((SECONDS < deadline)) || die "base backup $name did not complete (phase '$phase')"
    sleep 2
  done
  log "base backup $name completed"
}

# Velero backup from the hourly schedule's template.
velero_backup() { # NAME
  velero backup create "$1" --from-schedule ledger-hourly --wait >/dev/null
  local phase
  phase=$(kubectl get backups.velero.io "$1" -n velero -o jsonpath='{.status.phase}')
  if [[ "$phase" != "Completed" ]]; then
    velero backup describe "$1" --details || true
    velero backup logs "$1" | tail -50 || true
    die "Velero backup $1 ended in phase $phase"
  fi
  log "Velero backup $1 completed ($(kubectl get backups.velero.io "$1" -n velero -o jsonpath='{.status.progress.itemsBackedUp}') items)"
}

# Velero restore with the CNPG recovery modifier.
velero_restore() { # BACKUP SOURCE_SERVER NEW_SERVER RESTORE_NAME
  # shellcheck disable=SC2016  # envsubst takes the variable list literally
  SOURCE_SERVER=$2 SERVER_NAME=$3 envsubst '${SOURCE_SERVER} ${SERVER_NAME}' \
    <"$ROOT/deploy/platform/restore-modifiers.yaml" | kubectl apply -f -
  velero restore create "$4" --from-backup "$1" \
    --resource-modifier-configmap ledger-restore-modifiers --wait >/dev/null
  local phase
  phase=$(kubectl get restores.velero.io "$4" -n velero -o jsonpath='{.status.phase}')
  if [[ "$phase" != "Completed" ]]; then
    velero restore describe "$4" --details || true
    velero restore logs "$4" | tail -80 || true
    die "Velero restore $4 ended in phase $phase"
  fi
  log "Velero restore $4 completed ($(kubectl get restores.velero.io "$4" -n velero -o jsonpath='{.status.progress.itemsRestored}') items, $(kubectl get restores.velero.io "$4" -n velero -o jsonpath='{.status.warnings}') warnings)"
}

wal_archived() { # SEGMENT
  [[ "$(psql_app -c "SELECT coalesce(last_archived_wal, '') >= '$1' FROM pg_stat_archiver")" == t ]]
}

# Close the current WAL segment and wait until the archive has it. Sets
# DURABLE_BEFORE: every row created before that epoch is in the archive (one
# second of margin covers rows inserted but not yet committed at the switch).
archive_current_wal() {
  local out wal
  out=$(psql_app -c "SELECT extract(epoch FROM clock_timestamp()) || ' ' || pg_walfile_name(pg_switch_wal())")
  wal=${out#* }
  DURABLE_BEFORE=$(awk '{ printf "%.3f", $1 - 1 }' <<<"$out")
  retry 120 "WAL $wal archived" wal_archived "$wal" || die "WAL segment $wal was not archived"
  log "WAL segment $wal archived"
}

# Rows and newest commit that existed before epoch $1, as "rows max_seq last_epoch".
db_snapshot_before() { # EPOCH
  psql_app -c "SELECT count(*), coalesce(max(seq), 0), coalesce(extract(epoch FROM max(created_at)), 0)
               FROM events WHERE created_at < to_timestamp($1)" | tr '|' ' '
}

pass_fail() { # VALUE TARGET -> "pass"/"fail"
  if le "$1" "$2"; then echo pass; else echo fail; fi
}

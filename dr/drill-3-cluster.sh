#!/usr/bin/env bash
# Drill 3: the whole Kubernetes cluster is lost.
#
# The primary kind cluster is deleted without any graceful shutdown. A new
# cluster is built from nothing: platform from this repository, secrets from
# the break-glass store, application state from the object store only
# (Velero backup + CNPG base backup + WAL).
#
# Pass criteria: every row confirmed in the WAL archive is back, the export
# file has the same SHA-256, the API writes again, RTO <= RTO_TARGET_CLUSTER
# (including building the cluster) and RPO <= RPO_TARGET_LOSS.
# Usage: dr/drill-3-cluster.sh PRIMARY_CLUSTER STANDBY_CLUSTER
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
state_load

primary=${1:?usage: drill-3-cluster.sh PRIMARY STANDBY}
standby=${2:?usage: drill-3-cluster.sh PRIMARY STANDBY}
source_server=$SERVER_NAME
new_server=$(next_server "$source_server")
run_id=$(date -u +%H%M%S)

group "drill 3: prepare on $primary"
kubectl config use-context "kind-$primary" >/dev/null
export_json=$(api_get /api/exports)
export_name=$(jq -r '.[-1].name' <<<"$export_json")
export_sha=$(jq -r '.[-1].sha256' <<<"$export_json")
[[ -n "$export_name" && "$export_name" != null ]] || die "no export file to verify"
# The latest Velero backup must describe the cluster as it is now (after the
# PITR in drill 2 changed its spec).
velero_backup "drill3-$run_id"
sleep 15
archive_current_wal
read -r pre_rows pre_max _ <<<"$(db_snapshot_before "$DURABLE_BEFORE")"
log "confirmed in archive: $pre_rows rows, max seq $pre_max"
# Writes after this point are only in the current WAL segment; an abrupt loss
# takes them unless archive_timeout (15s) fires first.
sleep 10
endgroup

group "drill 3: disaster - delete cluster $primary"
t_disaster=$(now)
kind delete cluster --name "$primary"
endgroup

group "drill 3: rebuild $standby from the object store"
t0=$(now)
"$ROOT/dr/cluster-up.sh" "$standby"
t_cluster=$(now)
"$ROOT/dr/platform.sh"
t_platform=$(now)

backup_synced() { [[ "$(kubectl -n velero get backups.velero.io "drill3-$run_id" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Completed" ]]; }
retry 180 "Velero backup drill3-$run_id synced from the bucket" backup_synced ||
  die "standby cluster does not see backup drill3-$run_id"
t_synced=$(now)

velero_restore "drill3-$run_id" "$source_server" "$new_server" "restore-drill3-$run_id"
t_restored=$(now)
wait_cluster_ready 900
t_db=$(now)
wait_app_writing "$t0" 300
t_ready=$(now)
endgroup

group "drill 3: verify"
read -r rec_rows rec_max rec_last <<<"$(db_snapshot_before "$t_disaster")"
kept=$(psql_app -c "SELECT count(*) FROM events WHERE seq <= $pre_max AND created_at < to_timestamp($DURABLE_BEFORE)")
log "recovered: $rec_rows rows from before the disaster (max seq $rec_max), $kept of $pre_rows archived rows"
((kept == pre_rows)) || die "lost $((pre_rows - kept)) rows that were confirmed in the WAL archive"

restored_sha=$(api_get /api/exports | jq -r --arg n "$export_name" '.[] | select(.name == $n) | .sha256')
[[ "$restored_sha" == "$export_sha" ]] || die "export $export_name not restored intact (got '${restored_sha}')"
log "volume data intact: $export_name sha256 matches"

rto=$(secs "$t0" "$t_ready")
rpo=$(gap "$rec_last" "$t_disaster")
log "RTO ${rto}s (target ${RTO_TARGET_CLUSTER}s), RPO ${rpo}s (target ${RPO_TARGET_LOSS}s)"
endgroup

take_base_backup "base-after-drill3-$run_id"
state_set SERVER_NAME "$new_server"

jq -n \
  --arg rto "$rto" --arg rpo "$rpo" \
  --arg cluster "$(secs "$t0" "$t_cluster")" --arg platform "$(secs "$t_cluster" "$t_platform")" \
  --arg synced "$(secs "$t_platform" "$t_synced")" --arg restore "$(secs "$t_synced" "$t_restored")" \
  --arg db "$(secs "$t_restored" "$t_db")" --arg app "$(secs "$t_db" "$t_ready")" \
  --arg restore_only "$(secs "$t_synced" "$t_ready")" \
  --argjson pre_rows "$pre_rows" --argjson kept "$kept" --argjson rec_rows "$rec_rows" \
  --arg source "$source_server" --arg target "$new_server" --arg sha "$export_sha" \
  --arg rto_target "$RTO_TARGET_CLUSTER" --arg rpo_target "$RPO_TARGET_LOSS" \
  --arg rto_status "$(pass_fail "$rto" "$RTO_TARGET_CLUSTER")" --arg rpo_status "$(pass_fail "$rpo" "$RPO_TARGET_LOSS")" \
  '{drill: "cluster-lost", rto_seconds: ($rto|tonumber), rpo_seconds: ($rpo|tonumber),
    rto_target_seconds: ($rto_target|tonumber), rpo_target_seconds: ($rpo_target|tonumber),
    rto_status: $rto_status, rpo_status: $rpo_status,
    phases: {kind_cluster_seconds: ($cluster|tonumber), platform_install_seconds: ($platform|tonumber),
             velero_sync_seconds: ($synced|tonumber), velero_restore_seconds: ($restore|tonumber),
             postgres_recovery_seconds: ($db|tonumber), app_ready_seconds: ($app|tonumber),
             restore_only_seconds: ($restore_only|tonumber)},
    rows_confirmed_in_archive: $pre_rows, rows_confirmed_recovered: $kept, rows_recovered_before_disaster: $rec_rows,
    export_sha256_verified: $sha, restored_from_server: $source, archiving_to_server: $target}' \
  >"$RESULTS_DIR/drill-3.json"

le "$rto" "$RTO_TARGET_CLUSTER" || die "RTO ${rto}s exceeds target ${RTO_TARGET_CLUSTER}s"
le "$rpo" "$RPO_TARGET_LOSS" || die "RPO ${rpo}s exceeds target ${RPO_TARGET_LOSS}s"
log "drill 3 passed"

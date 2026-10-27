#!/usr/bin/env bash
# Drill 1: the ledger namespace is deleted by accident.
#
# Recovery: one Velero restore brings back every labelled object (API,
# Secrets, NetworkPolicies, the exports volume via Kopia, and the CNPG
# definitions). A resource modifier rewrites the restored Cluster to bootstrap
# from the object store, so PostgreSQL comes back from base backup + WAL.
#
# Pass criteria: restore Completed, every row committed before the incident is
# back, the export file on the volume has the same SHA-256, the API writes
# again, RTO <= RTO_TARGET_NAMESPACE and RPO <= RPO_TARGET_LOSS.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
state_load

source_server=$SERVER_NAME
new_server=$(next_server "$source_server")
run_id=$(date -u +%H%M%S)

group "drill 1: prepare"
# Volume data: an export file whose checksum must survive the restore.
export_json=$(api_post /api/exports)
export_name=$(jq -r .name <<<"$export_json")
export_sha=$(jq -r .sha256 <<<"$export_json")
log "export $export_name sha256 $export_sha"
velero_backup "drill1-$run_id"
endgroup

group "drill 1: incident - delete namespace $NS"
# Rows written after the Velero backup exist only in the WAL archive.
sleep 15
# Everything before DURABLE_BEFORE is confirmed in the archive and must come
# back. The rows written in the next 10s sit in a WAL segment that is not yet
# archived: whether they survive is what the RPO measures.
archive_current_wal
read -r pre_rows pre_max _ <<<"$(db_snapshot_before "$DURABLE_BEFORE")"
log "confirmed in archive: $pre_rows rows, max seq $pre_max"
sleep 10
t_incident=$(now)
kubectl delete namespace "$NS" --wait=true --timeout=300s
t_gone=$(now)
log "namespace deleted in $(secs "$t_incident" "$t_gone")s"
endgroup

group "drill 1: restore"
t0=$(now)
velero_restore "drill1-$run_id" "$source_server" "$new_server" "restore-drill1-$run_id"
t_restored=$(now)
wait_cluster_ready 600
t_db=$(now)
wait_app_writing "$t0" 300
t_ready=$(now)
endgroup

group "drill 1: verify"
read -r rec_rows rec_max rec_last <<<"$(db_snapshot_before "$t_incident")"
kept=$(psql_app -c "SELECT count(*) FROM events WHERE seq <= $pre_max AND created_at < to_timestamp($DURABLE_BEFORE)")
log "recovered: $rec_rows rows from before the incident (max seq $rec_max), $kept of $pre_rows archived rows"
((kept == pre_rows)) || die "lost $((pre_rows - kept)) rows that were confirmed in the WAL archive"

files=$(api_get /api/exports)
restored_sha=$(jq -r --arg n "$export_name" '.[] | select(.name == $n) | .sha256' <<<"$files")
[[ "$restored_sha" == "$export_sha" ]] || die "export $export_name not restored intact (got '${restored_sha}')"
log "volume data intact: $export_name sha256 matches"

rto=$(secs "$t0" "$t_ready")
rpo=$(gap "$rec_last" "$t_incident")
log "RTO ${rto}s (target ${RTO_TARGET_NAMESPACE}s), RPO ${rpo}s (target ${RPO_TARGET_LOSS}s)"
endgroup

# A recovered cluster archives to a new serverName that has no base backup yet.
take_base_backup "base-after-drill1-$run_id"
state_set SERVER_NAME "$new_server"

jq -n \
  --arg rto "$rto" --arg rpo "$rpo" \
  --arg velero_restore "$(secs "$t0" "$t_restored")" --arg db_ready "$(secs "$t0" "$t_db")" \
  --arg delete "$(secs "$t_incident" "$t_gone")" \
  --argjson pre_rows "$pre_rows" --argjson kept "$kept" --argjson rec_rows "$rec_rows" \
  --arg source "$source_server" --arg target "$new_server" --arg sha "$export_sha" \
  --arg rto_target "$RTO_TARGET_NAMESPACE" --arg rpo_target "$RPO_TARGET_LOSS" \
  --arg rto_status "$(pass_fail "$rto" "$RTO_TARGET_NAMESPACE")" --arg rpo_status "$(pass_fail "$rpo" "$RPO_TARGET_LOSS")" \
  '{drill: "namespace-deleted", rto_seconds: ($rto|tonumber), rpo_seconds: ($rpo|tonumber),
    rto_target_seconds: ($rto_target|tonumber), rpo_target_seconds: ($rpo_target|tonumber),
    rto_status: $rto_status, rpo_status: $rpo_status,
    phases: {namespace_delete_seconds: ($delete|tonumber), velero_restore_seconds: ($velero_restore|tonumber),
             postgres_ready_seconds: ($db_ready|tonumber)},
    rows_confirmed_in_archive: $pre_rows, rows_confirmed_recovered: $kept, rows_recovered_before_incident: $rec_rows,
    export_sha256_verified: $sha, restored_from_server: $source, archiving_to_server: $target}' \
  >"$RESULTS_DIR/drill-1.json"

le "$rto" "$RTO_TARGET_NAMESPACE" || die "RTO ${rto}s exceeds target ${RTO_TARGET_NAMESPACE}s"
le "$rpo" "$RPO_TARGET_LOSS" || die "RPO ${rpo}s exceeds target ${RPO_TARGET_LOSS}s"
log "drill 1 passed"

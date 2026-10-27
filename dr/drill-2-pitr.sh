#!/usr/bin/env bash
# Drill 2: bad data. Someone runs DELETE without a WHERE clause.
#
# Recovery: point-in-time recovery to the moment just before the DELETE. Writes
# are stopped, the damaged cluster is replaced by one bootstrapped from the
# newest base backup plus the WAL archive, replayed up to TARGET_TIME.
#
# Pass criteria: every row committed before the DELETE is back, nothing
# committed after the target time is present, the API writes again,
# RPO <= RPO_TARGET_PITR and RTO <= RTO_TARGET_PITR.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
state_load

source_server=$SERVER_NAME
new_server=$(next_server "$source_server")

group "drill 2: incident - DELETE FROM events (no WHERE)"
sleep 10
# One psql session: snapshot, then the target time, then the bad statement.
out=$(psql_app \
  -c "SELECT count(*) || ' ' || coalesce(max(seq), 0) FROM events" \
  -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') || '+00' || ' ' || extract(epoch FROM clock_timestamp())" \
  -c "WITH d AS (DELETE FROM events RETURNING 1) SELECT count(*) FROM d")
mapfile -t lines <<<"$out"
read -r pre_rows pre_max <<<"${lines[0]}"
target_time="${lines[1]% *}"
target_epoch="${lines[1]##* }"
deleted=${lines[2]}
log "snapshot: $pre_rows rows (max seq $pre_max); target time $target_time; DELETE removed $deleted rows"
((deleted >= pre_rows)) || die "DELETE removed $deleted rows, expected at least $pre_rows"
left=$(psql_app -c "SELECT count(*) FROM events WHERE seq <= $pre_max")
((left == 0)) || die "rows survived the DELETE"

# The writer keeps going: the archive must contain WAL past the target, or
# recovery cannot tell where to stop.
sleep 3
archive_current_wal
endgroup

group "drill 2: point-in-time recovery to $target_time"
t0=$(now)
# 1. Stop the writers so nothing else lands on the damaged database.
kubectl -n "$NS" scale deploy/ledger-api --replicas=0 >/dev/null
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=ledger-api --timeout=120s >/dev/null 2>&1 || true
# 2. Replace the cluster. Its PVCs go with it; the archive is untouched.
kubectl -n "$NS" delete cluster pg --wait=true --timeout=300s >/dev/null
pvcs_gone() { [[ -z "$(kubectl -n "$NS" get pvc -l cnpg.io/cluster=pg -o name)" ]]; }
retry 180 "PGDATA PVCs removed" pvcs_gone || die "PVCs of the old cluster were not removed"
# 3. Recover to the target time, archiving to a fresh serverName.
# shellcheck disable=SC2016  # envsubst takes the variable list literally
PG_IMAGE=$PG_IMAGE SOURCE_SERVER=$source_server SERVER_NAME=$new_server TARGET_TIME=$target_time \
  envsubst '${PG_IMAGE} ${SOURCE_SERVER} ${SERVER_NAME} ${TARGET_TIME}' \
  <"$ROOT/deploy/ledger/cluster-pitr.yaml" | kubectl apply -f - >/dev/null
wait_cluster_ready 900
t_db=$(now)

# Verify before the writers return, so the numbers describe the recovery only.
read -r rec_rows rec_max rec_last <<<"$(psql_app -c "SELECT count(*), coalesce(max(seq), 0), coalesce(extract(epoch FROM max(created_at)), 0) FROM events" | tr '|' ' ')"
kept=$(psql_app -c "SELECT count(*) FROM events WHERE seq <= $pre_max")
after_target=$(psql_app -c "SELECT count(*) FROM events WHERE created_at > to_timestamp($target_epoch)")
log "recovered $rec_rows rows (max seq $rec_max): $kept of $pre_rows snapshot rows, $after_target rows newer than the target"
((kept == pre_rows)) || die "PITR is missing $((pre_rows - kept)) rows from before the DELETE"
((after_target == 0)) || die "PITR replayed $after_target rows past the target time"

# 4. Let the writers back in.
kubectl -n "$NS" scale deploy/ledger-api --replicas=1 >/dev/null
wait_app_writing "$t0" 300
t_ready=$(now)
endgroup

rto=$(secs "$t0" "$t_ready")
rpo=$(gap "$rec_last" "$target_epoch")
log "RTO ${rto}s (target ${RTO_TARGET_PITR}s), RPO ${rpo}s before the target time (target ${RPO_TARGET_PITR}s)"

take_base_backup "base-after-drill2-$(date -u +%H%M%S)"
state_set SERVER_NAME "$new_server"

jq -n \
  --arg rto "$rto" --arg rpo "$rpo" --arg db_ready "$(secs "$t0" "$t_db")" \
  --argjson pre_rows "$pre_rows" --argjson deleted "$deleted" --argjson kept "$kept" \
  --argjson rec_rows "$rec_rows" --argjson after "$after_target" \
  --arg target_time "$target_time" --arg source "$source_server" --arg target "$new_server" \
  --arg rto_target "$RTO_TARGET_PITR" --arg rpo_target "$RPO_TARGET_PITR" \
  --arg rto_status "$(pass_fail "$rto" "$RTO_TARGET_PITR")" --arg rpo_status "$(pass_fail "$rpo" "$RPO_TARGET_PITR")" \
  '{drill: "bad-delete-pitr", rto_seconds: ($rto|tonumber), rpo_seconds: ($rpo|tonumber),
    rto_target_seconds: ($rto_target|tonumber), rpo_target_seconds: ($rpo_target|tonumber),
    rto_status: $rto_status, rpo_status: $rpo_status,
    phases: {postgres_ready_seconds: ($db_ready|tonumber)},
    target_time: $target_time, rows_before_delete: $pre_rows, rows_deleted: $deleted,
    rows_restored_of_snapshot: $kept, rows_recovered: $rec_rows, rows_after_target: $after,
    restored_from_server: $source, archiving_to_server: $target}' \
  >"$RESULTS_DIR/drill-2.json"

le "$rto" "$RTO_TARGET_PITR" || die "RTO ${rto}s exceeds target ${RTO_TARGET_PITR}s"
le "$rpo" "$RPO_TARGET_PITR" || die "RPO ${rpo}s exceeds target ${RPO_TARGET_PITR}s"
log "drill 2 passed"

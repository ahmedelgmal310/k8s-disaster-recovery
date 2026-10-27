#!/usr/bin/env bash
# Proves the alert rules watch real signals: every cnpg_/barman_/velero_ metric
# referenced in monitoring/rules is scraped from the live components, and the
# backup timestamps they expose are recent.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

out="$RESULTS_DIR/metrics"
mkdir -p "$out"

scrape() { # KIND/NAME NAMESPACE REMOTE_PORT FILE
  local lport=$((20000 + RANDOM % 10000))
  kubectl port-forward -n "$2" "$1" "$lport:$3" >/dev/null 2>&1 &
  local pf=$!
  local ok=1
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${lport}/metrics" -o "$4" 2>/dev/null; then
      ok=0
      break
    fi
    sleep 1
  done
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  return $ok
}

# A Velero backup created from the schedule populates the per-schedule series.
velero_backup "metrics-$(date -u +%H%M%S)"

scrape "pod/$(primary_pod)" "$NS" 9187 "$out/cnpg.prom" || die "cannot scrape the PostgreSQL instance exporter"
scrape deploy/velero velero 8085 "$out/velero.prom" || die "cannot scrape Velero"

mapfile -t names < <(sed 's/#.*//' "$ROOT"/monitoring/rules/*.yml | grep -oE '\b(cnpg|barman|velero)_[a-z0-9_]*[a-z0-9]' | sort -u)
((${#names[@]} > 0)) || die "no metric names found in the rules"

missing=0
for n in "${names[@]}"; do
  if grep -qE "^${n}(\{| )" "$out/cnpg.prom" "$out/velero.prom"; then
    log "ok      $n"
  else
    log "MISSING $n"
    missing=$((missing + 1))
  fi
done
if ((missing > 0)); then
  log "metric families exposed:"
  grep -hoE '^(cnpg|barman|velero)_[a-z0-9_]+' "$out/cnpg.prom" "$out/velero.prom" | sort -u >&2
  die "$missing metric(s) used by the alert rules are not exposed"
fi

last_backup=$(awk '/^barman_cloud_cloudnative_pg_io_last_available_backup_timestamp/ { print $2 }' "$out/cnpg.prom" | sort -g | tail -1)
age=$(awk -v t="$last_backup" -v n="$(date +%s)" 'BEGIN { printf "%.0f", n - t }')
le "$age" 3600 || die "barman last_available_backup_timestamp is ${age}s old"
log "all ${#names[@]} metrics used by alerts are live; last base backup ${age}s ago"

jq -n --argjson names "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" --arg age "$age" \
  '{metrics_checked: $names, base_backup_age_seconds: ($age | tonumber)}' >"$RESULTS_DIR/metrics.json"

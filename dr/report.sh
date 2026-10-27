#!/usr/bin/env bash
# Collects the drill results into results.json and a Markdown summary (also
# written to the GitHub job summary). Runs even when a drill failed.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

cd "$RESULTS_DIR"
files=()
for f in drill-1.json drill-2.json drill-3.json metrics.json encryption.json; do
  [[ -f "$f" ]] && files+=("$f")
done

jq -n --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}" \
  --arg sha "${GITHUB_SHA:-local}" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{run: $run, commit: $sha, finished_at: $when}' >meta.json
if ((${#files[@]} > 0)); then
  jq -s 'reduce .[] as $x ({}; . + {($x.drill // (if $x.metrics_checked then "metrics" else "encryption" end)): $x})' \
    "${files[@]}" | jq --slurpfile m meta.json '. + {meta: $m[0]}' >results.json
else
  cp meta.json results.json
fi

row() { # FILE TITLE
  if [[ -f "$1" ]]; then
    jq -r --arg t "$2" '"| \($t) | **\(.rto_seconds) s** (≤ \(.rto_target_seconds) s, \(.rto_status)) | **\(.rpo_seconds) s** (≤ \(.rpo_target_seconds) s, \(.rpo_status)) |"' "$1"
  else
    echo "| $2 | not completed | not completed |"
  fi
}

{
  echo "## Disaster-recovery drills"
  echo
  echo "| Drill | RTO | RPO |"
  echo "|---|---|---|"
  row drill-1.json "1. Namespace deleted → Velero restore"
  row drill-2.json "2. DELETE without WHERE → PITR"
  row drill-3.json "3. Cluster lost → rebuild from object store"
  echo
  if [[ -f drill-3.json ]]; then
    echo "Drill 3 phases (s): $(jq -r '.phases | to_entries | map("\(.key)=\(.value)") | join(", ")' drill-3.json)"
    echo
  fi
  if [[ -f encryption.json ]]; then
    jq -r '"Encryption: \(.velero_bucket.checked)/\(.velero_bucket.objects) Velero objects and \(.pg_backups_bucket.checked)/\(.pg_backups_bucket.objects) PostgreSQL backup objects checked, all SSE-S3 AES256; \(.kopia_packs_without_plaintext) Kopia packs without plaintext."' encryption.json
    echo
  fi
  if [[ -f metrics.json ]]; then
    jq -r '"Alert inputs live: \(.metrics_checked | length) metrics referenced by the rules are exposed by CNPG, the Barman Cloud plugin and Velero."' metrics.json
  fi
} >summary.md

cat summary.md
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat summary.md >>"$GITHUB_STEP_SUMMARY"
fi

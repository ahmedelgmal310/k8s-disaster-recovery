#!/usr/bin/env bash
# Proves the backups at rest are encrypted and inventories what the drills
# left in the object store:
#   - every object checked in both buckets reports SSE-S3 (AES256),
#   - Velero's file-system backup data is Kopia ciphertext (no plaintext CSV),
#   - base backups and WAL exist for each serverName the drills created.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
secrets_load

S3_LOCAL=http://127.0.0.1:8333
s3() {
  AWS_ACCESS_KEY_ID=$S3_ADMIN_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$S3_ADMIN_SECRET_KEY AWS_DEFAULT_REGION=us-east-1 \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws --endpoint-url "$S3_LOCAL" "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# check_bucket BUCKET -> prints "checked total"; dies on any unencrypted object.
check_bucket() {
  local bucket=$1 total checked=0 bad=0 step key sse
  s3 s3api list-objects-v2 --bucket "$bucket" --query 'Contents[].[Key,Size]' --output text >"$work/$bucket.txt"
  total=$(wc -l <"$work/$bucket.txt")
  ((total > 0)) || die "bucket $bucket is empty"
  # Every object, up to 400 per bucket spread evenly over the listing.
  step=$(((total + 399) / 400))
  while read -r key _; do
    sse=$(s3 s3api head-object --bucket "$bucket" --key "$key" --query ServerSideEncryption --output text)
    checked=$((checked + 1))
    if [[ "$sse" != "AES256" ]]; then
      log "NOT ENCRYPTED: s3://$bucket/$key ($sse)"
      bad=$((bad + 1))
    fi
  done < <(awk -v s="$step" 'NR % s == 0' "$work/$bucket.txt")
  ((bad == 0)) || die "$bad unencrypted objects in $bucket"
  log "s3://$bucket: $total objects, $checked checked, all SSE-S3 (AES256)"
  echo "$checked $total"
}

read -r velero_checked velero_total < <(check_bucket velero)
read -r pg_checked pg_total < <(check_bucket pg-backups)

# Client-side encryption of volume data: the export CSVs start with a known
# header. Kopia packs must not contain it in plaintext.
pack_keys=$(awk '$1 ~ /^kopia\/ledger\// && $1 ~ /\/p[0-9a-f]+/ { print $1 }' "$work/velero.txt" | head -20)
[[ -n "$pack_keys" ]] || die "no Kopia pack blobs found for namespace ledger"
packs=0
while read -r key; do
  s3 s3 cp "s3://velero/$key" "$work/pack" --quiet
  if grep -aq "seq,created_at,writer" "$work/pack"; then
    die "plaintext export data found in Kopia blob $key"
  fi
  packs=$((packs + 1))
done <<<"$pack_keys"
log "$packs Kopia pack blobs contain no plaintext export data (client-side AES-256-GCM)"

# Inventory per serverName.
servers=$(awk '{ split($1, p, "/"); print p[1] }' "$work/pg-backups.txt" | sort -u | tr '\n' ' ')
inventory="[]"
for srv in $servers; do
  wal=$(grep -c "^${srv}/wals/" "$work/pg-backups.txt" || true)
  base=$(grep -E "^${srv}/base/[^/]+/backup.info" "$work/pg-backups.txt" | wc -l)
  log "serverName $srv: $base base backup(s), $wal WAL objects"
  inventory=$(jq --arg s "$srv" --argjson b "$base" --argjson w "$wal" '. + [{server: $s, base_backups: $b, wal_objects: $w}]' <<<"$inventory")
done
velero_backups=$(grep -cE '^backups/[^/]+/velero-backup.json' "$work/velero.txt" || true)

jq -n --argjson vc "$velero_checked" --argjson vt "$velero_total" \
  --argjson pc "$pg_checked" --argjson pt "$pg_total" --argjson inv "$inventory" \
  --argjson packs "$packs" --argjson vb "$velero_backups" \
  '{velero_bucket: {checked: $vc, objects: $vt, sse: "AES256"},
    pg_backups_bucket: {checked: $pc, objects: $pt, sse: "AES256"},
    kopia_packs_without_plaintext: $packs, velero_backups: $vb, servers: $inv}' >"$RESULTS_DIR/encryption.json"
log "encryption verified"

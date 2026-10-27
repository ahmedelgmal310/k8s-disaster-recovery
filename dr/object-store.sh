#!/usr/bin/env bash
# Starts the S3-compatible object store (SeaweedFS) as a container on the kind
# Docker network, outside every Kubernetes cluster, so it survives the loss of
# a whole cluster. Creates the buckets with default SSE-S3 encryption and
# least-privilege identities, then proves the isolation between them.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
secrets_load

S3_LOCAL=http://127.0.0.1:8333
CONTAINER=dr-s3

s3() { # IDENTITY ARGS...  (admin | velero | cnpg)
  local who=$1
  shift
  local ak sk
  case "$who" in
    admin) ak=$S3_ADMIN_ACCESS_KEY sk=$S3_ADMIN_SECRET_KEY ;;
    velero) ak=$S3_VELERO_ACCESS_KEY sk=$S3_VELERO_SECRET_KEY ;;
    cnpg) ak=$S3_CNPG_ACCESS_KEY sk=$S3_CNPG_SECRET_KEY ;;
  esac
  AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk AWS_DEFAULT_REGION=us-east-1 \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws --endpoint-url "$S3_LOCAL" "$@"
}

record_ip() {
  local ip
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$CONTAINER")
  state_set S3_IP "$ip"
  log "object store at ${ip}:8333 on the kind network"
}

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]; then
  log "object store already running"
  record_ip
  exit 0
fi
docker network inspect kind >/dev/null 2>&1 || die "docker network 'kind' missing: create a kind cluster first"

# Identities: each tool can only reach its own bucket.
cfg_dir="$(dirname "$DR_SECRETS_FILE")/seaweedfs"
mkdir -p "$cfg_dir"
cat >"$cfg_dir/s3.json" <<EOF
{
  "identities": [
    {"name": "admin",
     "credentials": [{"accessKey": "${S3_ADMIN_ACCESS_KEY}", "secretKey": "${S3_ADMIN_SECRET_KEY}"}],
     "actions": ["Admin", "Read", "List", "Tagging", "Write"]},
    {"name": "velero",
     "credentials": [{"accessKey": "${S3_VELERO_ACCESS_KEY}", "secretKey": "${S3_VELERO_SECRET_KEY}"}],
     "actions": ["Read:velero", "Write:velero", "List:velero", "Tagging:velero"]},
    {"name": "cnpg",
     "credentials": [{"accessKey": "${S3_CNPG_ACCESS_KEY}", "secretKey": "${S3_CNPG_SECRET_KEY}"}],
     "actions": ["Read:pg-backups", "Write:pg-backups", "List:pg-backups", "Tagging:pg-backups"]}
  ]
}
EOF
# The container runs as uid 1000; the runner is single-use.
chmod 755 "$cfg_dir"
chmod 644 "$cfg_dir/s3.json"

# Prefer Google's Docker Hub mirror (no anonymous pull limits on shared runners).
image="$SEAWEEDFS_IMAGE"
if docker pull -q "mirror.gcr.io/${SEAWEEDFS_IMAGE}" >/dev/null 2>&1; then
  image="mirror.gcr.io/${SEAWEEDFS_IMAGE}"
else
  docker pull -q "$SEAWEEDFS_IMAGE" >/dev/null
fi

log "starting SeaweedFS ($image)"
# WEED_S3_SSE_KEK is the key-encryption key that wraps every per-object
# SSE-S3 data key. Keeping it outside the store's own metadata means a copy of
# the volume files alone cannot be decrypted.
docker run -d --name "$CONTAINER" --network kind --restart unless-stopped \
  -p 127.0.0.1:8333:8333 \
  -v dr-s3-data:/data \
  -v "$cfg_dir/s3.json:/etc/seaweedfs/s3.json:ro" \
  -e WEED_S3_SSE_KEK="$SSE_KEK" \
  "$image" server -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json >/dev/null

retry 120 "S3 API answering" s3 admin s3api list-buckets || {
  docker logs --tail 80 "$CONTAINER" || true
  die "object store did not start"
}

for bucket in velero pg-backups; do
  s3 admin s3api create-bucket --bucket "$bucket" >/dev/null 2>&1 || true
  retry 60 "bucket $bucket" s3 admin s3api head-bucket --bucket "$bucket" || die "bucket $bucket missing"
  s3 admin s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  algo=$(s3 admin s3api get-bucket-encryption --bucket "$bucket" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
  [[ "$algo" == "AES256" ]] || die "bucket $bucket default encryption is '$algo', want AES256"
  log "bucket $bucket ready, default encryption $algo"
done

# Least privilege: each identity can use its own bucket and is denied the other.
s3 velero s3api list-objects-v2 --bucket velero --max-items 1 >/dev/null || die "velero identity cannot list its bucket"
s3 cnpg s3api list-objects-v2 --bucket pg-backups --max-items 1 >/dev/null || die "cnpg identity cannot list its bucket"
if s3 velero s3api list-objects-v2 --bucket pg-backups --max-items 1 >/dev/null 2>&1; then
  die "velero identity can read the PostgreSQL backups bucket"
fi
if s3 cnpg s3api list-objects-v2 --bucket velero --max-items 1 >/dev/null 2>&1; then
  die "cnpg identity can read the Velero bucket"
fi
log "bucket isolation verified (velero !-> pg-backups, cnpg !-> velero)"

record_ip

#!/usr/bin/env bash
# Creates a kind cluster, makes sure the object store is running, points the
# in-cluster s3.storage service at it and loads the application image.
# Usage: dr/cluster-up.sh CLUSTER_NAME
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

name=${1:?usage: cluster-up.sh CLUSTER_NAME}

log "creating kind cluster $name ($KIND_NODE_IMAGE)"
kind create cluster --name "$name" --image "$KIND_NODE_IMAGE" \
  --config "$ROOT/deploy/kind/cluster.yaml" --wait 120s
kubectl config use-context "kind-$name" >/dev/null

# The object store runs once per job on the kind Docker network.
"$ROOT/dr/object-store.sh"
state_load
[[ -n "${S3_IP:-}" ]] || die "object store IP unknown"

# shellcheck disable=SC2016  # envsubst takes the variable list literally
S3_IP=$S3_IP envsubst '${S3_IP}' <"$ROOT/deploy/platform/s3-endpoint.yaml" | kubectl apply -f -

kind load docker-image "$APP_IMAGE" --name "$name"
log "cluster $name ready"

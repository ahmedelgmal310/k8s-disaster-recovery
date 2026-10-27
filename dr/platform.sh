#!/usr/bin/env bash
# Installs the backup platform into the current kube context:
#   cert-manager -> CloudNativePG operator -> Barman Cloud plugin -> Velero.
# Release manifests are checksum-verified, operator images pinned by digest.
# The same script rebuilds the platform on the standby cluster in drill 3.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
secrets_load

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

group "cert-manager ${CERT_MANAGER_VERSION}"
fetch_verified "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  "$CERT_MANAGER_SHA256" "$work/cert-manager.yaml"
kubectl apply -f "$work/cert-manager.yaml" >/dev/null
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s
endgroup

group "CloudNativePG ${CNPG_VERSION}"
fetch_verified "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_VERSION}/cnpg-${CNPG_VERSION}.yaml" \
  "$CNPG_SHA256" "$work/cnpg.yaml"
# Pin the operator image (also used as the instance manager) by digest.
sed -i "s#ghcr.io/cloudnative-pg/cloudnative-pg:${CNPG_VERSION}#${CNPG_IMAGE}#g" "$work/cnpg.yaml"
kubectl apply --server-side -f "$work/cnpg.yaml" >/dev/null
kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s
endgroup

group "Barman Cloud plugin ${BARMAN_VERSION}"
fetch_verified "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${BARMAN_VERSION}/manifest.yaml" \
  "$BARMAN_SHA256" "$work/barman.yaml"
sed -i "s#ghcr.io/cloudnative-pg/plugin-barman-cloud:${BARMAN_VERSION}#${BARMAN_IMAGE}#g" "$work/barman.yaml"
# cert-manager's webhook can take a few seconds to serve after it is Available.
retry 120 "barman plugin manifest applied" kubectl apply -f "$work/barman.yaml" || die "cannot apply barman plugin manifest"
# The sidecar image injected into every PostgreSQL pod, pinned by digest.
kubectl -n cnpg-system set env deploy/barman-cloud SIDECAR_IMAGE="$BARMAN_SIDECAR_IMAGE" >/dev/null
kubectl -n cnpg-system rollout status deploy/barman-cloud --timeout=300s
endgroup

group "Velero chart ${VELERO_CHART_VERSION}"
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# S3 credentials of the velero identity (velero bucket only).
kubectl -n velero create secret generic velero-s3 --dry-run=client -o yaml \
  --from-literal=cloud="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
    "$S3_VELERO_ACCESS_KEY" "$S3_VELERO_SECRET_KEY")" | kubectl apply -f - >/dev/null
# Kopia repository password. It encrypts all volume data client-side; without
# it, the volume backups in the bucket cannot be read, so it is a break-glass
# secret and the standby cluster must be given the same value.
kubectl -n velero create secret generic velero-repo-credentials --dry-run=client -o yaml \
  --from-literal=repository-password="$VELERO_REPO_PASSWORD" | kubectl apply -f - >/dev/null

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts --force-update >/dev/null
helm upgrade --install velero vmware-tanzu/velero --version "$VELERO_CHART_VERSION" \
  --namespace velero -f "$ROOT/deploy/platform/velero-values.yaml" --wait --timeout 5m >/dev/null
kubectl -n velero rollout status ds/node-agent --timeout=180s

bsl_available() {
  [[ "$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')" == "Available" ]]
}
retry 180 "BackupStorageLocation Available" bsl_available || {
  kubectl -n velero get backupstoragelocation default -o yaml || true
  kubectl -n velero logs deploy/velero --tail=60 || true
  die "Velero cannot reach the bucket"
}
kubectl apply -f "$ROOT/deploy/platform/velero-schedule.yaml" >/dev/null
endgroup

log "platform ready: cert-manager, CNPG ${CNPG_VERSION}, barman-cloud ${BARMAN_VERSION}, Velero chart ${VELERO_CHART_VERSION}"

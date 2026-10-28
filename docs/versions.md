# Pinned versions

Every tool, chart, manifest, image and action is pinned. Images use
`tag@sha256:digest`, actions use a full commit SHA with the version in a
comment, release manifests are verified against a recorded SHA-256, and Go
modules are locked by `go.sum`. A version is adopted only after it has been
released for at least two weeks; Dependabot proposes updates with a 14-day
cooldown (`.github/dependabot.yml`).

Where each pin lives: drill platform in `dr/lib.sh`, Velero images in
`deploy/platform/velero-values.yaml`, build images in `Dockerfile`, CI tools in
`.github/workflows/*.yml`. This file is the index; update it in the same change.

Pins as of 2026-10-28.

## Disaster-recovery platform (`dr/lib.sh`, `deploy/platform/velero-values.yaml`)

| Component | Version | Released | Pin |
|---|---|---|---|
| kind | v0.33.0 | 2026-08-26 | release binary (`helm/kind-action`) |
| Kubernetes node image | kindest/node v1.36.4 | | `sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed` |
| cert-manager (manifest) | v1.21.2 | 2026-09-11 | manifest `sha256:e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f` |
| CloudNativePG operator (manifest) | 1.30.1 | 2026-09-23 | manifest `sha256:37237f145d8138256ea25ae830f87759255665ff08f8d552fdd8224a5ec032fb` |
| CloudNativePG operator image | 1.30.1 | 2026-09-23 | `sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07` |
| Barman Cloud plugin (manifest) | v0.15.1 | 2026-09-30 | manifest `sha256:8f377ff4a7d0d3f74fc64b0f7ac4f449fc38ca9e83a40107cca2f9315a9bd920` |
| Barman Cloud plugin image | v0.15.1 | 2026-09-30 | `sha256:c75acad19a36e8176cfe2885761ff1b836c6ef977d7257e298c99a28b5c302ef` |
| Barman Cloud sidecar image | v0.15.1 | 2026-09-30 | `sha256:2287a793a804db751edd0d07d44cd549e357677e98a800eb12e2cf7c0d53f9b0` |
| PostgreSQL operand image | 18.6 (`18.6-202610120828-minimal-trixie`) | 2026-10-12 | `sha256:c9be7f221a05b18fe65259d9136affbabe3b39ad91c3b68f8f2f990a45f35f38` |
| Velero Helm chart | 12.2.0 | 2026-09-16 | chart version |
| Velero server / node-agent | v1.18.4 | 2026-09-28 | `sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b` |
| velero-plugin-for-aws | v1.14.4 | 2026-09-28 | `sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa` |
| Velero CLI | v1.18.4 | 2026-09-28 | tarball `sha256:e520c17d8997e1c9d0a28ae013592e4473ca3bd82cb3acd132e51286263f74bf` |
| SeaweedFS (S3 object store) | 4.48 | 2026-09-28 | `sha256:4e61d15fd35994cb1e43e1e553dff106794841fd9a99ade2fc8c8bfce4d7872d` |

The CNPG and Barman manifests reference their images by tag; `dr/platform.sh`
rewrites them to the digests above before applying, and sets the sidecar image
by digest on the plugin deployment. The cert-manager manifest is verified by
checksum and its images are used by tag.

## Service image (`Dockerfile`)

| Stage | Image | Digest |
|---|---|---|
| build | golang 1.27.3-alpine3.24 | `sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb` |
| runtime | gcr.io/distroless/static-debian13:nonroot | `sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99` |

## Go (`go.mod`)

| Module | Version |
|---|---|
| Go toolchain | 1.27.3 |
| github.com/jackc/pgx/v5 | v5.11.0 (2026-09-07) |
| github.com/prometheus/client_golang | v1.24.1 (2026-07-24) |
| golang.org/x/text (indirect, raised for GO-2026-6629 / CVE-2026-56851) | v0.41.0 (2026-08-11) |

## CI (`.github/workflows/ci.yml`, `.github/workflows/dr-drills.yml`)

| Tool | Version | Pin |
|---|---|---|
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/setup-go | v7.0.0 | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` |
| actions/upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| golangci/golangci-lint-action | v9.3.0 (golangci-lint v2.15.0) | `ba0d7d2ec06a0ea1cb5fa41b2e4a3ab91d21278a` |
| docker/setup-buildx-action | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| docker/build-push-action | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
| helm/kind-action | v1.15.1 | `1544676c07bb3570fcb70166beaa07c4528fd4aa` |
| azure/setup-helm | v5.0.1 (Helm v4.3.1) | `9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310` |
| govulncheck | v1.9.0 | module version |
| kubeconform | v0.8.0 | tarball `sha256:9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883` |
| datreeio/CRDs-catalog | | commit `3eb90d47aba8d61919d4419dd38301536e32a94b` |
| promtool (prom/prometheus) | v3.15.0 | `sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` |
| actionlint | 1.7.12 | `sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667` |
| hadolint | v2.15.1 | `sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d` |
| Gitleaks | v8.30.1 | `sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` |
| Trivy | 0.76.1 | `sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c` |
| PostgreSQL (Go integration tests) | 18.6-alpine3.23 | `sha256:1a0c23d53c1ad77468c8653fa6eed4f4105cfbef9e6f027bc1dfeb16949a8c29` |
| shellcheck | runner image | preinstalled on `ubuntu-latest` |

PostgreSQL 18.6 itself is older than two weeks; the Docker Official Image
digest is a recent rebuild of that version (base OS patches), which is how that
image is published.

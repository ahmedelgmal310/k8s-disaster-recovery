# Security Policy

## Supported versions

Only the `main` branch is maintained.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/ahmedelgmal310/k8s-disaster-recovery/security/advisories/new).
Do not open a public issue. You can expect an acknowledgement within 72 hours.

## How backups are protected

- **Encryption at rest, server side.** Both buckets enforce default SSE-S3
  (AES-256). CNPG sends `x-amz-server-side-encryption: AES256` on every WAL
  segment and base backup, and Velero does the same for its resource tarballs.
  The store's key-encryption key is passed in at start-up and is not stored next
  to the data. CI checks the encryption header on the stored objects after every drill run.
- **Encryption at rest, client side.** Velero's file-system backups go through
  Kopia, which encrypts every blob with AES-256-GCM using the repository
  password before upload. CI downloads Kopia packs and checks that no plaintext
  application data is inside.
- **Least privilege.** Velero and CloudNativePG each have their own S3 identity
  that can only reach its own bucket. CI checks that each identity is refused
  access to the other bucket.
- **No secrets in git.** All credentials, the key-encryption key and the Kopia
  password are created per CI run by `dr/secrets.sh`, written outside the
  workspace with mode 600, and masked in logs. Gitleaks scans the full history
  on every push.
- **Break-glass secrets.** Recovering a lost cluster needs the S3 credentials,
  the Kopia repository password and the object store's key. Keep them in a
  secret store that does not depend on the cluster being alive (see the
  runbook in the README).

## Supply-chain controls

- Every GitHub Action is pinned to a full commit SHA, and container images are
  pinned by digest (`docs/versions.md` lists all of them).
- Operator release manifests are downloaded with a recorded SHA-256 and the
  operator images inside them are rewritten to digests before they are applied.
- CI gates: `govulncheck`, Trivy (fixable HIGH/CRITICAL fails the build),
  Gitleaks, golangci-lint (gosec), shellcheck, actionlint, hadolint.
- The service image is distroless and runs as a non-root user with a read-only
  root filesystem and all capabilities dropped.

FROM golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY cmd/ cmd/
COPY internal/ internal/

ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/ledger-api ./cmd/ledger-api

FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99

LABEL org.opencontainers.image.source="https://github.com/ahmedelgmal310/k8s-disaster-recovery" \
      org.opencontainers.image.title="ledger-api" \
      org.opencontainers.image.description="Stateful demo service for Kubernetes backup and disaster-recovery drills" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /out/ledger-api /ledger-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/ledger-api"]

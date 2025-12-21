# syntax=docker/dockerfile:1

FROM alpine:3.20 AS fetch

ARG HELM_VERSION=v3.19.4
ARG KUBECONFORM_VERSION=v0.7.0
ARG YQ_VERSION=v4.50.1
ARG K8S_SCHEMA_VERSION=v1.32.1

RUN apk add --no-cache ca-certificates curl tar gzip git

# Detect arch without TARGETARCH (works in classic docker build too)
RUN set -eux; \
  A="$(apk --print-arch 2>/dev/null || true)"; \
  if [ -z "$A" ]; then A="$(uname -m)"; fi; \
  case "$A" in \
    x86_64|amd64)  ARCH=amd64 ;; \
    aarch64|arm64) ARCH=arm64 ;; \
    *) echo "Unsupported arch: $A" && exit 1 ;; \
  esac; \
  echo "$ARCH" > /tmp/arch

# ---- Helm
RUN set -eux; \
  ARCH="$(cat /tmp/arch)"; \
  mkdir -p /out /tmp/helm; \
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tgz; \
  tar -xzf /tmp/helm.tgz -C /tmp/helm; \
  install -m 0755 "/tmp/helm/linux-${ARCH}/helm" /out/helm; \
  rm -rf /tmp/helm /tmp/helm.tgz

# ---- kubeconform
RUN set -eux; \
  ARCH="$(cat /tmp/arch)"; \
  mkdir -p /out /tmp/kc; \
  curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" -o /tmp/kc.tgz; \
  tar -xzf /tmp/kc.tgz -C /tmp/kc; \
  install -m 0755 "/tmp/kc/kubeconform" /out/kubeconform; \
  rm -rf /tmp/kc /tmp/kc.tgz

# ---- yq
RUN set -eux; \
  ARCH="$(cat /tmp/arch)"; \
  mkdir -p /out; \
  curl -fsSL -o /out/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"; \
  chmod +x /out/yq

# ---- Kubernetes JSON Schemas (ONLY what we need)
RUN set -eux; \
  mkdir -p /out/schemas; \
  git clone --depth 1 --filter=blob:none --sparse https://github.com/yannh/kubernetes-json-schema.git /tmp/k8s-schemas; \
  cd /tmp/k8s-schemas; \
  git sparse-checkout set "${K8S_SCHEMA_VERSION}-standalone-strict"; \
  test -d "/tmp/k8s-schemas/${K8S_SCHEMA_VERSION}-standalone-strict"; \
  cp -a "/tmp/k8s-schemas/${K8S_SCHEMA_VERSION}-standalone-strict" "/out/schemas/"; \
  rm -rf /tmp/k8s-schemas


FROM alpine:3.20

RUN apk add --no-cache bash ca-certificates git coreutils findutils

COPY --from=fetch /out/helm        /usr/local/bin/helm
COPY --from=fetch /out/kubeconform /usr/local/bin/kubeconform
COPY --from=fetch /out/yq          /usr/local/bin/yq

ARG K8S_SCHEMA_VERSION=v1.32.1
COPY --from=fetch /out/schemas/${K8S_SCHEMA_VERSION}-standalone-strict \
  /opt/kubeconform/schemas/${K8S_SCHEMA_VERSION}-standalone-strict

ENV KUBECONFORM_SCHEMA_DIR=/opt/kubeconform/schemas

RUN set -eux; \
  test -d "${KUBECONFORM_SCHEMA_DIR}/${K8S_SCHEMA_VERSION}-standalone-strict"; \
  helm version; \
  kubeconform -v; \
  yq --version

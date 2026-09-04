FROM alpine:3.20

ARG ETCD_VERSION=v3.6.8
ARG TARGETARCH

RUN apk add --no-cache \
    age \
    bash \
    ca-certificates \
    coreutils \
    curl \
    github-cli \
    gzip \
    util-linux \
  && case "${TARGETARCH:-amd64}" in \
      amd64) etcd_arch="amd64" ;; \
      arm64) etcd_arch="arm64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
  && curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${etcd_arch}.tar.gz" \
    | tar -xz -C /tmp \
  && mv "/tmp/etcd-${ETCD_VERSION}-linux-${etcd_arch}/etcdctl" /usr/local/bin/etcdctl \
  && mv "/tmp/etcd-${ETCD_VERSION}-linux-${etcd_arch}/etcdutl" /usr/local/bin/etcdutl \
  && rm -rf "/tmp/etcd-${ETCD_VERSION}-linux-${etcd_arch}" \
  && addgroup -S backup \
  && adduser -S -G backup backup \
  && mkdir -p /data/etcd-backup /var/lock \
  && chown -R backup:backup /data/etcd-backup /var/lock

COPY etcd-backups-github-release.sh /usr/local/bin/etcd-backups-github-release

RUN chmod 0755 /usr/local/bin/etcd-backups-github-release

USER backup
WORKDIR /data/etcd-backup
ENV GH_CONFIG_DIR=/data/etcd-backup/gh-config

ENTRYPOINT ["/usr/local/bin/etcd-backups-github-release"]

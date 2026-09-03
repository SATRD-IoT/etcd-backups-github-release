FROM alpine:latest

ARG ETCD_VERSION=v3.5.13

ENV ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"
ENV ETCDCTL_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
ENV ETCDCTL_KEY="/etc/kubernetes/pki/etcd/healthcheck-client.key"
ENV ETCDCTL_CERT="/etc/kubernetes/pki/etcd/healthcheck-client.crt"

RUN apk add --update --no-cache bash ca-certificates tzdata openssl

RUN wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz \
 && tar xzf etcd-${ETCD_VERSION}-linux-amd64.tar.gz \
 && mv etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/etcdctl \
 && rm -rf etcd-${ETCD_VERSION}-linux-amd64*

ENTRYPOINT ["/bin/bash"]
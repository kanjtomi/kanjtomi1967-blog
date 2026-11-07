#!/bin/bash
# RHEL ホスト上で root で実行する: イメージを podman でビルドして containerd (k8s.io) に入れる。
#   ssh root@192.168.0.200 'bash -s' < linux-tuning-lab/build-image.sh
# Containerfile はこのスクリプトの下に埋め込んである内容と同じ (image/Containerfile)。
set -euo pipefail
IMG=localhost/tuning-tools:local
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Containerfile" <<'CF'
FROM docker.io/library/fedora:42
RUN dnf -y install --setopt=install_weak_deps=False \
      sysstat stress-ng fio fio-engine-libaio sysbench \
      procps-ng htop strace util-linux numactl bc python3 hostname less \
      iproute iputils bind-utils curl httpd-tools iperf3 \
 && dnf clean all
CMD ["sleep", "infinity"]
CF
podman build -t "$IMG" "$WORK"
podman save "$IMG" -o "$WORK/img.tar"
ctr -n k8s.io images import "$WORK/img.tar"
ctr -n k8s.io images ls | grep tuning-tools

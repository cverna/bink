#!/bin/bash
# Run a bink cluster end to end on aarch64.
#
# Used by the Testing Farm CI job (plans/main.fmf). bink runs nested
# libvirt/QEMU VMs, so this requires /dev/kvm and /dev/fuse, which is why the
# job requests a non-virtualized (bare metal) host.
#
# Testing Farm runs tests as root, but bink is designed to drive rootless
# Podman, so the work is done as an unprivileged user.
#
# Every potentially slow step is wrapped in `timeout` so a hang fails with the
# offending step named, instead of sitting until the plan's duration expires.
#
# Assumes the bink checkout is the current working directory.
set -euxo pipefail

KUBE_MINOR="${KUBE_MINOR:-1.36}"
FEDORA_VERSION="${FEDORA_VERSION:-45}"
NODE_IMAGE="ghcr.io/bootc-dev/bink/node:v${KUBE_MINOR}-fedora-${FEDORA_VERSION}-disk"
SRC_DIR=/src/bink
BINK_USER=bink

log() { echo "=== $* ==="; }

log "Verifying the environment"
[ "$(uname -m)" = "aarch64" ]
test -c /dev/kvm
test -c /dev/fuse
systemd-detect-virt --vm || true

log "Installing host prerequisites"
timeout 900 dnf -y install --setopt=install_weak_deps=0 \
    btrfs-progs \
    gpgme-devel \
    golang \
    make \
    openssl-devel \
    podman \
    qemu-img

log "Creating an unprivileged user for rootless Podman"
id "$BINK_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$BINK_USER"
BINK_UID=$(id -u "$BINK_USER")
XDG_RUNTIME="/run/user/${BINK_UID}"
loginctl enable-linger "$BINK_USER"
chown -R "$BINK_USER:$BINK_USER" "$SRC_DIR"

as_bink() {
    sudo -u "$BINK_USER" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME}/bus" \
        CONTAINER_HOST="unix://${XDG_RUNTIME}/podman/podman.sock" \
        bash -lc "$1"
}

log "Starting the user Podman API service"
for _ in $(seq 1 30); do
    [ -S "${XDG_RUNTIME}/bus" ] && break
    sleep 1
done
as_bink 'systemctl --user start podman.socket'
as_bink 'podman info >/dev/null'

log "Building bink"
as_bink "cd $SRC_DIR && timeout 600 make build-bink"

log "Building the node bootc image"
as_bink "cd $SRC_DIR && timeout 1200 make -C node-images/fedora build-bootc-image"

log "Building the node disk image"
as_bink "cd $SRC_DIR && timeout 1500 make -C node-images/fedora build-disk-image"

log "Building the cluster and DNS images"
# The published DNS image is amd64-only, so it has to be built locally.
as_bink "cd $SRC_DIR && timeout 900 make build-cluster-image"
as_bink "cd $SRC_DIR && timeout 600 make build-dns-image"

log "Starting the cluster"
# The default control-plane memory (1900 MB) leaves less than kubeadm's
# 1700 MB preflight minimum, so ask for more.
as_bink "cd $SRC_DIR && timeout 1800 ./bink cluster start --memory 4096 --max-memory 8192 --node-image $NODE_IMAGE"

log "Verifying the cluster"
NODES=$(as_bink "cd $SRC_DIR && timeout 300 ./bink node ssh node1 -- 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide'")
echo "$NODES"
echo "$NODES" | grep -q ' Ready '
echo "$NODES" | grep -q 'arm64'

log "Cluster is up on aarch64"
as_bink "cd $SRC_DIR && timeout 300 ./bink cluster stop" || true

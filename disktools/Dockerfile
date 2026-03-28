FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-utils \
    parted \
    kpartx \
    e2fsprogs \
    cloud-guest-utils \
    openssl \
    coreutils \
    util-linux \
    mount \
    pigz \
    && rm -rf /var/lib/apt/lists/*

COPY disk-ops.sh /usr/local/bin/disk-ops.sh
RUN chmod +x /usr/local/bin/disk-ops.sh

WORKDIR /disk

ENTRYPOINT ["/usr/local/bin/disk-ops.sh"]

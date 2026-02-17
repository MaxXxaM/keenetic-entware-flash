ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

ARG APT_MIRROR=""
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|http://archive.ubuntu.com|${APT_MIRROR}|g" /etc/apt/sources.list && \
        sed -i "s|http://security.ubuntu.com|${APT_MIRROR}|g" /etc/apt/sources.list; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        parted \
        e2fsprogs \
        dosfstools \
        kpartx \
        ca-certificates \
        curl \
        wget \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/entware-installers && \
    wget -q -O /opt/entware-installers/mipsel-installer.tar.gz \
        https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz && \
    wget -q -O /opt/entware-installers/mips-installer.tar.gz \
        https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz && \
    wget -q -O /opt/entware-installers/aarch64-installer.tar.gz \
        https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

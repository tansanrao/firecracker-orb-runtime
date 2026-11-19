# The fc-orb-runtime container: Firecracker, a guest kernel, and orbctl.
#
# It runs with /dev/kvm, /dev/net/tun, and NET_ADMIN (see lib.sh), so the
# microVMs' tap devices and NAT rules live in the container's network namespace
# and the host's network configuration is never touched.

FROM alpine:3.22 AS guest-agent
RUN apk add --no-cache gcc musl-dev linux-headers
COPY guest/orb-agent.c /src/orb-agent.c
RUN gcc -static -O2 -Wall -Wextra -o /orb-agent /src/orb-agent.c

# The guest kernel, built from Amazon Linux 2023's kernel6.18 source with
# Firecracker's microVM config. That pairing is what Firecracker validates as a
# guest and supports until at least June 2028 (docs/kernel-policy.md), and
# Amazon tags a new release every week or two. guest/kernel.config adds what
# Docker in an orb needs.
FROM debian:trixie-slim AS guest-kernel
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bc bison build-essential ca-certificates cpio curl flex git kmod libelf-dev libssl-dev python3 \
    && rm -rf /var/lib/apt/lists/*
# The commit of tag kernel6.18-6.18.62-127.179.amzn2023. To update, take the
# commit of the newest tag that this prints:
#   git ls-remote --tags https://github.com/amazonlinux/linux 'refs/tags/kernel6.18-*' | sort -V -k2
ARG KERNEL_COMMIT=b7522fb67989bd879de78486e9e253fd2f21f1dd
RUN git init -q /linux \
    && cd /linux \
    && git fetch -q --depth 1 https://github.com/amazonlinux/linux "${KERNEL_COMMIT}" \
    && git checkout -q FETCH_HEAD
# Firecracker v1.18.0, the release installed below.
ARG FIRECRACKER_COMMIT=eaf83bb718a559d324613d566eaf776b31a62340
COPY guest/kernel.config /kernel.config
RUN cd /linux \
    && for name in microvm-kernel-ci-x86_64-6.18.config ci.config; do \
        curl -fsSL "https://raw.githubusercontent.com/firecracker-microvm/firecracker/${FIRECRACKER_COMMIT}/resources/guest_configs/${name}" || exit 1; \
    done >.config \
    && cat /kernel.config >>.config \
    && make -s olddefconfig \
    # olddefconfig drops an option whose dependencies are not met without saying so.
    && grep '^CONFIG' /kernel.config | while read -r option; do \
        grep -qxF "${option}" .config || { echo "kernel.config option not applied: ${option}" >&2; exit 1; }; \
    done \
    && make -s -j"$(nproc)" vmlinux \
    && objcopy --strip-debug vmlinux /vmlinux

FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl e2fsprogs iproute2 iptables procps python3 tar util-linux \
    && rm -rf /var/lib/apt/lists/*

ARG FIRECRACKER_VERSION=v1.18.0
ARG FIRECRACKER_SHA256=1ac8eec866dd5eea14efecf6323e22b23eea24054545338a5b34bc5bca6623cd
RUN curl -fsSL -o /tmp/firecracker.tgz \
        "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-x86_64.tgz" \
    && echo "${FIRECRACKER_SHA256}  /tmp/firecracker.tgz" | sha256sum -c - \
    && tar -xzf /tmp/firecracker.tgz -C /tmp \
    && install -m 0755 "/tmp/release-${FIRECRACKER_VERSION}-x86_64/firecracker-${FIRECRACKER_VERSION}-x86_64" /usr/local/bin/firecracker \
    && rm -rf /tmp/firecracker.tgz /tmp/release-*

COPY --from=guest-kernel /vmlinux /opt/fc/vmlinux
COPY --from=guest-agent /orb-agent /opt/fc/guest/orb-agent
COPY guest/orb-init guest/orb-agent.service /opt/fc/guest/
COPY orbctl /usr/local/bin/orbctl

CMD ["orbctl", "serve"]

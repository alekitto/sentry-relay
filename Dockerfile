ARG DOCKER_ARCH=$TARGETARCH
ARG RELAY_FEATURES=processing,crash-handler
ARG RUST_TOOLCHAIN_VERSION=1.71.0

##################
### Deps stage ###
##################

FROM --platform=$BUILDARCH debian:bullseye AS base-386

ENV DEBIAN_ARCH=i386
ENV BUILD_ARCH=i686
ENV GCC_ARCH=i686

FROM --platform=$BUILDARCH debian:bullseye AS base-amd64

ENV DEBIAN_ARCH=amd64
ENV BUILD_ARCH=x86_64
ENV GCC_ARCH=x86-64

FROM --platform=$BUILDARCH debian:bullseye AS base-arm64

ENV DEBIAN_ARCH=arm64
ENV BUILD_ARCH=aarch64
ENV GCC_ARCH=aarch64

FROM --platform=$BUILDARCH getsentry/sentry-cli:2 AS sentry-cli
FROM --platform=$BUILDARCH base-$TARGETARCH AS relay-deps

ARG DOCKER_ARCH

ENV DOCKER_ARCH=${DOCKER_ARCH}
ENV BUILD_TARGET=${BUILD_ARCH}-unknown-linux-gnu

RUN dpkg --add-architecture ${DEBIAN_ARCH} \
    && apt-get update \
    && apt-get -y install llvm cmake git curl clang libcurl4-openssl-dev:${DEBIAN_ARCH} zip \
    binutils-${GCC_ARCH}-linux-gnu libc6-${DEBIAN_ARCH}-cross \
    libc6-dev-${DEBIAN_ARCH}-cross crossbuild-essential-${DEBIAN_ARCH} gcc-${GCC_ARCH}-linux-gnu \
    g++-${GCC_ARCH}-linux-gnu libgcc-10-dev-${DEBIAN_ARCH}-cross

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

# Rust version must be provided by the caller.
ARG RUST_TOOLCHAIN_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain=${RUST_TOOLCHAIN_VERSION} -t ${BUILD_TARGET} \
    && echo -e '[registries.crates-io]\nprotocol = "sparse"\n[net]\ngit-fetch-with-cli = true' > $CARGO_HOME/config

COPY --from=sentry-cli /bin/sentry-cli /bin/sentry-cli

WORKDIR /work

#####################
### Builder stage ###
#####################

FROM --platform=$BUILDARCH relay-deps AS relay-builder

ARG TARGETARCH
ARG RELAY_FEATURES
ENV RELAY_FEATURES=${RELAY_FEATURES}
ENV CARGO_TARGET_I686_UNKNOWN_LINUX_GNU_LINKER=i686-linux-gnu-gcc \
    CC_I686_unknown_linux_gnu=i686-linux-gnu-gcc \
    CXX_I686_unknown_linux_gnu=i686-linux-gnu-g++
ENV CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc \
    CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc \
    CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++
ENV BINDGEN_EXTRA_CLANG_ARGS="--sysroot /usr/${BUILD_ARCH}-linux-gnu"

COPY . .

# Build with the modern compiler toolchain enabled
RUN --mount=type=cache,id=cargo-$TARGETARCH,target=/usr/local/cargo/registry \
    echo "[net]\ngit-fetch-with-cli = true" > $CARGO_HOME/config && \
    make build-linux-release \
    OBJCOPY=${BUILD_ARCH}-linux-gnu-objcopy \
    TARGET=${BUILD_TARGET} \
    RELAY_FEATURES=${RELAY_FEATURES}

# Collect source bundle
# Produces `relay-bin`, `relay-debug.zip` and `relay.src.zip` in current directory
RUN : \
    && make collect-source-bundle \
    TARGET=${BUILD_TARGET}

###################
### Final stage ###
###################

FROM debian:bullseye-slim

RUN apt-get update \
    && apt-get install -y ca-certificates gosu curl --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV \
    RELAY_UID=10001 \
    RELAY_GID=10001

# Create a new user and group with fixed uid/gid
RUN groupadd --system relay --gid $RELAY_GID \
    && useradd --system --gid relay --uid $RELAY_UID relay

RUN mkdir /work /etc/relay \
    && chown relay:relay /work /etc/relay
VOLUME ["/work", "/etc/relay"]
WORKDIR /work

EXPOSE 3000

COPY --from=relay-builder /work/relay-bin /bin/relay
COPY --from=relay-builder /work/relay-debug.zip /work/relay.src.zip /opt/

COPY ./docker-entrypoint.sh /
ENTRYPOINT ["/bin/bash", "/docker-entrypoint.sh"]
CMD ["run"]

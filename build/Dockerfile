FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev \
    libncurses-dev \
    dwarves \
    pkg-config \
    wget \
    curl \
    git \
    xz-utils \
    p7zip-full \
    fakeroot \
    cpio \
    kmod \
    lsb-release \
    software-properties-common \
    gnupg \
    python3 \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install LLVM/Clang (latest stable via apt.llvm.org)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc && \
    echo "deb http://apt.llvm.org/noble/ llvm-toolchain-noble main" >> /etc/apt/sources.list.d/llvm.list && \
    apt-get update && apt-get install -y \
    clang \
    lld \
    llvm \
    && rm -rf /var/lib/apt/lists/*

# Install Go (for nvidia-container-toolkit)
ARG GOLANG_VERSION=1.22.4
RUN arch="$(uname -m)"; \
    case "${arch}" in \
        x86_64|amd64) GOARCH='amd64' ;; \
        aarch64|arm64) GOARCH='arm64' ;; \
        *) echo "unsupported: ${arch}"; exit 1 ;; \
    esac; \
    wget -nv -O - "https://go.dev/dl/go${GOLANG_VERSION}.linux-${GOARCH}.tar.gz" \
    | tar -C /usr/local -xz

ENV GOPATH=/go
ENV PATH="/go/bin:/usr/local/go/bin:${PATH}"

WORKDIR /build

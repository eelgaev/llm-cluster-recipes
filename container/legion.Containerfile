ARG CUDA_VERSION=13.0.3

# ---- Build Legion ------------------------------------------------------------
FROM nvcr.io/nvidia/cuda:${CUDA_VERSION}-devel-ubi9 AS builder

# Legion git ref to build (branch, tag or commit).
ARG LEGION_REF=main
# GPU architectures compiled into the binary. CUDA 13 has no sm_70 (V100); 12x gets its
# "a" suffix in Legion's build.rs automatically.
ARG CUDA_ARCHS="75;80;86;89;90;100;120"
# Parallel compile jobs (nvcc is memory hungry with many architectures).
ARG JOBS=16

RUN dnf install -y \
        git \
        cmake \
        gcc \
        gcc-c++ \
        make \
        clang \
        clang-devel \
    && dnf clean all

# Rust: the checkout's rust-toolchain.toml picks the pinned version.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:/usr/local/cuda/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none

WORKDIR /root
RUN git clone https://github.com/eelgaev/Legion.git legion \
    && cd legion \
    && git checkout --detach "$LEGION_REF" \
    && git submodule update --init --depth 1 third_party/ggml \
    && git rev-parse HEAD > /root/legion-commit

RUN cd legion \
    && export CUDA_PATH=/usr/local/cuda \
              CMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS" \
              GGML_NATIVE=OFF \
              CUDAFLAGS="-Xcompiler=-fPIC" \
              LIBRARY_PATH=/usr/local/cuda/lib64/stubs \
              CMAKE_BUILD_PARALLEL_LEVEL="$JOBS" \
    && cargo build --release --features cuda --locked -j "$JOBS" \
    && install -m 755 target/release/legion /usr/local/bin/legion \
    && rm -rf target


# ---- Runtime -----------------------------------------------------------------
FROM nvcr.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubi9

RUN dnf install -y \
        bash \
        curl-minimal \
        ca-certificates \
        wget \
        openssl \
        hostname \
        jq \
    && dnf clean all

COPY --from=builder /usr/local/bin/legion /usr/local/bin/legion
COPY --from=builder /root/legion-commit /usr/local/share/legion-commit

WORKDIR /recipe

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

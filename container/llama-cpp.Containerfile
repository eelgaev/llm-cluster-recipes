ARG CUDA_VERSION=13.0.3

# ---- Build llama.cpp ---------------------------------------------------------
FROM nvcr.io/nvidia/cuda:${CUDA_VERSION}-devel-ubi9 AS builder

RUN dnf install -y \
        git \
        cmake \
        gcc \
        gcc-c++ \
        make \
    && dnf clean all

WORKDIR /root

RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git \
    && cd llama.cpp \
    && cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_NATIVE=OFF \
        -DLLAMA_BUILD_LIBRESSL=ON -DLLAMA_BUILD_BORINGSSL=OFF -DLLAMA_OPENSSL=ON \
    && cmake --build build -j"$(nproc)" --target llama-server


# ---- Runtime -----------------------------------------------------------------
FROM nvcr.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubi9

RUN dnf install -y \
        bash \
        wget \
        openssl \
        hostname \
        jq \
    && dnf clean all

COPY --from=builder /root/llama.cpp/build/bin/ /usr/local/bin/

WORKDIR /recipe

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

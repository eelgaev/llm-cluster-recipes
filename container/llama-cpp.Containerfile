# MOCK Containerfile — placeholder, replace the runtime build with the real thing.
# One image is built per <type>-<arch> and referenced from image_for() in run-recipe.sh.
#
# Pin CUDA to the driver branch the GPU Operator installs by default:
#   operator v25.3 – v26.3 -> driver R580 -> CUDA 13.0
#   operator v26.7+        -> driver R595 -> CUDA 13.2 (13.0 still runs on it; bump when the cluster is there)
# Check with: oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.driver.version}'
# Tags are multi-arch (amd64+arm64).
ARG CUDA_VERSION=13.0.3
FROM docker.io/nvidia/cuda:${CUDA_VERSION}-runtime-ubi9

# tools the entrypoint + recipe scripts need
RUN dnf install -y bash wget curl openssl hostname && dnf clean all

# TODO: build/install the real LLM runtime onto PATH, e.g. llama-server or vllm
#   RUN git clone https://github.com/ggml-org/llama.cpp && cmake -B build -DGGML_CUDA=ON ... \
#       && install build/bin/llama-server /usr/local/bin/llama-server

WORKDIR /recipe
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

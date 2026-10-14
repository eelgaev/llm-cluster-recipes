# llm-cluster-recipes

A small runner plus readable Kubernetes manifests that install the NVIDIA GPU Operator on an
OpenShift cluster and run an LLM "recipe" as **one model-serving pod on every GPU worker**.

```
./run-recipe.sh https://host/recipes/qwen3.8-27B/ --register-url https://router.example.com/register
```

Remove the workload later with:

```bash
./run-recipe.sh uninstall
```

From a checkout, the runner uses its adjacent manifests, including when invoked through a
symlink from another project. A standalone downloaded or streamed runner clones this repository
into a temporary directory to obtain the manifests:

```bash
curl -fsSL https://raw.githubusercontent.com/eelgaev/llm-cluster-recipes/main/run-recipe.sh \
  | bash -s -- https://host/recipes/qwen3.8-27B/ \
      --register-url https://router.example.com/register
```

## Using with openshift-dpf

The `openshift-dpf` custom post-install hook accepts a script path followed by arguments. With
an executable copy of `run-recipe.sh` (or a symlink to this checkout) in the `openshift-dpf` root,
use this value when generating its `.env`:

```dotenv
CUSTOM_POSTINSTALL_SCRIPT="./run-recipe.sh https://bfb.okoyl.xyz/llms/qwen3.8-27B --register-url https://rhllm.okoyl.xyz/register"
```

The hook also supports downloading the runner directly:

```dotenv
CUSTOM_POSTINSTALL_SCRIPT="https://raw.githubusercontent.com/eelgaev/llm-cluster-recipes/main/run-recipe.sh https://bfb.okoyl.xyz/llms/qwen3.8-27B --register-url https://rhllm.okoyl.xyz/register"
```

The runner inherits the hook's management-cluster `KUBECONFIG` and preserves the caller's working
directory, including for relative kubeconfig paths. `make run-custom-postinstall-script` runs the
hook independently; `make all` includes it. The automation host needs the prerequisites below.
An explicit `REPO_URL` or `REPO_REF` selects cloned manifests even when a local checkout exists.
When pinning a release, select the same ref in the runner URL and `REPO_REF`.

By default, the runner returns after submitting the workload manifests; the in-cluster reconciler
creates the DaemonSets as GPU capacity appears. It does not wait for model pods, downloads, or
registration. Use `--wait` to verify that the current recipe is healthy and registered on every
detected GPU node. In that mode, `DEPLOY_TIMEOUT` limits the wait and a timeout prints diagnostics.
Re-run the hook when adding a CPU architecture that was absent at initial deployment.

## Prerequisites

- `oc` logged in as cluster-admin (`oc whoami` must succeed)
- `curl`
- `git` (for standalone runners or explicit remote manifest settings)
- [`yq`](https://github.com/mikefarah/yq) v4 (mikefarah)
- An OpenShift cluster with NVIDIA GPU workers and enough memory for the selected recipe
- OperatorHub reachable from the cluster (`redhat-operators` for NFD and
  `certified-operators` for the GPU Operator)
- GPU nodes can reach the recipe files, runtime image registry, and HTTPS registration endpoint

## What `run-recipe.sh` does

1. Loads local manifests or clones this repository at `REPO_REF`, then fetches
   `<url>/recipe.yaml` and validates it.
2. Installs NFD if missing, preserving an existing DPF-managed NFD configuration. Adds a rule for
   the vendor-only NVIDIA GPU label without changing DPF's compound PCI labels. It reuses an
   existing NVIDIA GPU Operator Subscription and OperatorGroup in `nvidia-gpu-operator`, or installs
   them via OLM when absent, then creates or reuses its `ClusterPolicy`. Multiple Subscriptions or
   OperatorGroups for that installation are reported as an error. An existing ClusterPolicy and
   its GPU Operator operands are preserved. For a new ClusterPolicy, GPU operands are configured
   to tolerate not-ready nodes and use
   the external API endpoint, host networking, and the host DNS resolver so their init containers
   can run before cluster pod networking.
3. Finds GPU nodes (NFD label `feature.node.kubernetes.io/pci-10de.present=true`) and groups them by
   CPU architecture.
4. For each architecture, creates an in-cluster reconciler. The reconciler
   creates or updates the workload once at least one matching node advertises `nvidia.com/gpu`
   capacity, allowing other nodes to finish initializing independently. It manages
   DaemonSet `llm-recipe-<arch>` (using `image_for`, `<type>-<arch>`) in namespace
   `llm-recipes`. The DaemonSet:
   - runs with `hostNetwork: true` (server on `https://<node-ip>:52395`),
   - uses a dedicated service account and an SCC permitting host networking, the
     server port, and the node-local model cache,
   - requests the smallest positive GPU capacity currently reported within that architecture
     (`nvidia.com/gpu: N`), so nodes with different GPU counts share one DaemonSet,
   - mounts the recipe script from a ConfigMap at `/recipe/script.sh`,
   - mounts the runner's entrypoint and health checks at `/runtime`, so deployment fixes take
     effect without rebuilding the inference image,
   - mounts a persistent node-local model cache at `/models`, with `emptyDir`s at `/certs` and a
     memory-backed `/dev/shm`.
   A root init container uses SELinux `spc_t` only to prepare and relabel the mounted cache; the
   model server uses `container_t`, drops all capabilities, and has no service-account token.
5. Submits the workload controllers and exits without waiting for model pods. Registration must
   return HTTP 2xx; redirects and failures are retried with bounded request timeouts. A startup
   probe allows model loading, readiness includes registration, and a liveness probe restarts an
   unresponsive server. With `--wait`, the runner checks the current rollout on every detected
   GPU node and prints diagnostics if it times out.
6. Prints node IPs and commands for following both the reconciler and workload. Kubernetes keeps
   reconciling the controller objects after `run-recipe.sh` exits; recipe or server failures exit
   the workload container and remain visible in pod status.

Every step is idempotent; re-run the script after editing the recipe.

Environment knobs:

| Var | Meaning |
|---|---|
| `NS` | target namespace (default `llm-recipes`) |
| `CSV_TIMEOUT` | seconds to wait for an operator CSV to install (default `600`); the runner reports OLM progress and fails immediately if the CSV enters `Failed` |
| `DEPLOY_TIMEOUT` | seconds to wait for all model servers to become healthy and registered (default `7200`); also sets the startup-probe budget |
| `WAIT_FOR_READY` | defaults to `false`; `true` or `--wait` checks model readiness and registration |
| `RECONCILE_RESYNC` | safety resync period in seconds (default `300`); node changes reconcile immediately via an API watch |
| `DRY_RUN=true` | render YAML to stdout without applying resources or waiting; does not require installed operator CRDs; uninstall only prints planned deletions |
| `REPO_URL` | manifest repository to clone (default: this GitHub repository over HTTPS) |
| `REPO_REF` | branch or tag to clone (default `main`) |
| `MODEL_CACHE_ROOT` | host directory for per-recipe model caches (default `/var/cache/llm-cluster-recipes/models`) |
| `LLAMA_CPP_X86_IMAGE` | override the x86 llama.cpp runtime image |
| `LLAMA_CPP_ARM_IMAGE` | override the ARM llama.cpp runtime image |

## Manifests

Kubernetes resources live in [`manifests/`](manifests/) rather than being embedded in the runner.
The checked-in files contain sensible placeholder values and remain valid YAML on their own;
`run-recipe.sh` renders namespace, recipe, architecture, image, URL, and checksum values with `yq`
before applying them. Dynamic recipe and DaemonSet content is loaded into the corresponding
ConfigMap manifests from temporary files.

Required flag:

- `--register-url <https-url>` — each pod POSTs
  `{"host":"<node-ip>","port":52395,"api_key":"<key>"}` here once its server is healthy. The
  connection uses normal CA and hostname verification and retries until registration succeeds.

Optional flag: `--wait` checks workload readiness and registration before returning. `--no-wait`
remains available to override `WAIT_FOR_READY=true`.

## Recipe schema

A recipe is a **folder served over HTTP** containing `recipe.yaml` plus the model weights.
`recipe.yaml` is a plain config file read by `run-recipe.sh` — it is not a Kubernetes object and is
never applied to the cluster.

```yaml
name: my-model
type: llama-cpp          # runtime key; combined with node arch to pick an image
cacheKey: my-model-v1    # optional; bump when hosted model files change
vars:                    # exported as env vars in the pod
  MODEL_NAME: org/model
script: |                # runs inside the pod on every GPU node
  #!/usr/bin/env bash
  set -euo pipefail
  if [ ! -s /models/model.gguf ]; then
    wget -c "$RECIPE_BASE_URL/model.gguf" -O /models/model.gguf.part
    mv /models/model.gguf.part /models/model.gguf
  fi
  exec llama-server --host 0.0.0.0 --port "$PORT" --api-key "$API_KEY" \
    --ssl-key-file "$TLS_KEY" --ssl-cert-file "$TLS_CRT" -m /models/model.gguf -ngl 99
```

Environment available to the script:

| Var | Meaning |
|---|---|
| `RECIPE_BASE_URL` | the recipe folder URL — `wget` weights from here |
| `PORT` | `52395`, the standard server port |
| `API_KEY` | per-pod random key generated by the entrypoint; pass it to the server |
| `TLS_KEY`, `TLS_CRT` | self-signed cert generated by the entrypoint |
| `NODE_NAME` | the node the pod is running on |
| `NODE_HOST_IP` | the node IP advertised to the registration endpoint |
| `vars` | everything you declare, verbatim |

Rules for recipe scripts: reference weights under `/models/...`, invoke the runtime from `PATH`,
and avoid host-specific tuning (`--numa`, `--cpu-strict`, `--prio`, fixed core ranges, absolute
host paths) — pods are unprivileged. `CUDA_VISIBLE_DEVICES` may narrow the GPU set, but indices
must be within the node's GPU count.

Recipe names must be valid Kubernetes label values. Variable names must be portable shell
environment names, values must be scalar strings/numbers/booleans, and runner-owned variables
(`RECIPE_BASE_URL`, `PORT`, `REGISTER_URL`, `NODE_NAME`, `NODE_HOST_IP`, `API_KEY`, `TLS_KEY`, and
`TLS_CRT`) cannot be overridden. Changing a recipe script changes the pod-template checksum and
automatically rolls the DaemonSets.

`cacheKey` defaults to the recipe name and selects the cache directory on every node. Bump it when
the hosted model artifacts change. Recipe scripts should download to a `.part` file with resume
enabled, then rename it into place only after a successful download. The included Qwen recipe has a
reusable `fetch_cached` helper demonstrating this pattern.

Registration (`--register-url`) is a required deployment setting passed to `run-recipe.sh`, not part
of the recipe — the same recipe can be deployed against different routers.

## Uninstalling

`./run-recipe.sh uninstall` deletes the workload namespace selected by `NS`, its custom SCC, and
its cluster-wide Node-reader and SCC-access RBAC. It intentionally preserves the shared NFD and
NVIDIA GPU Operator installation. It also preserves model data under `MODEL_CACHE_ROOT` on every node, so a
later deployment can reuse it. Remove those host directories separately when the cached weights
are no longer needed.

Preview uninstall without deleting resources with `DRY_RUN=true ./run-recipe.sh uninstall`.

## Images

Recipes do not name images. `run-recipe.sh` holds a lookup at the top:

```bash
image_for() {
  case "$1" in
    llama-cpp-arm) echo "${LLAMA_CPP_ARM_IMAGE:-quay.io/eelgaev/llama-cpp-arm:latest}" ;;
    llama-cpp-x86) echo "${LLAMA_CPP_X86_IMAGE:-quay.io/eelgaev/llama-cpp-x86:latest}" ;;
    *) return 1 ;;
  esac
}
```

Add a `<type>-<arch>` entry (and list it in `KNOWN_IMAGES`) for every combination you want to
support. Unsupported runtime types are rejected before cluster resources are changed.
`container/llama-cpp.Containerfile` builds a CUDA-enabled llama-server with TLS and the runtime tools
needed by the recipe. The runner pulls a prebuilt image; it does not compile llama.cpp during
deployment. Custom images must provide Bash, curl, OpenSSL, wget, coreutils, and the recipe runtime.

The current deployment target is x86. Before enabling ARM GPU workers, publish an accessible ARM
image or set `LLAMA_CPP_ARM_IMAGE`; private images also require appropriate cluster pull credentials.

## Staging weights (maintainer)

On the machine serving the recipe folder:

```
cd recipes/qwen3.8-27B
HF_TOKEN=hf_... ./download.sh
python3 -m http.server 8080 --directory ..   # or any HTTP server
```

`download.sh` is a maintainer-only convenience. The cluster never fetches or runs it, and no
`HF_TOKEN` is needed cluster-side.

## Checking on it

```
oc get pods -n llm-recipes -o wide
oc logs -f -l app=llm-recipe -n llm-recipes --max-log-requests=20
curl -k https://<node-ip>:52395/health -H "Authorization: Bearer <api-key>"
```

The API key is per pod and is sent to the registration endpoint. Administrators can also read it
with `oc exec -n llm-recipes <pod> -- cat /certs/api-key`. It is stored with mode `0600`, and the
entrypoint invalidates the old registration marker whenever the container restarts.

## Local checks

Run `python3 -m unittest discover -s tests -v` with Bash and mikefarah `yq` v4 installed.
The regression tests mock `oc`, `curl`, `git`, and `wget`; they do not contact a cluster,
download weights, or register servers. They cover DPF-style invocation, rendering and RBAC,
dry-run uninstall, fresh NFD/GPU Operator bootstrap, preservation of shared configuration, current
rollout readiness on all GPU nodes, timeout diagnostics, registration failures, probe authentication,
reconciliation with initializing nodes, watch failures, and interrupted downloads.

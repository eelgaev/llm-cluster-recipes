#!/usr/bin/env bash
#
# run-recipe.sh — install the NVIDIA GPU Operator on an OpenShift cluster and run an
# LLM "recipe" on every GPU worker via a DaemonSet (one DaemonSet per node architecture).
#
# Usage: ./run-recipe.sh <http-url-to-recipe-folder> --register-url <https-url>
#   e.g. ./run-recipe.sh https://host/recipes/qwen3.8-27B/ --register-url https://router/register
#        ./run-recipe.sh uninstall
#
# --register-url: each pod POSTs {"host","port","api_key"} here once its server is healthy.
#
# The recipe folder must contain recipe.yaml; model weights are served from the same
# folder and fetched by the recipe script inside the pod via $RECIPE_BASE_URL.
#
# Every step is idempotent — the script is safe to re-run.
set -euo pipefail

# ----------------------------------------------------------------------------
# Image map: <type>-<arch> -> container image. Recipes never carry an image;
# they declare `type` and the node architecture decides the rest.
# ----------------------------------------------------------------------------
# (a case statement rather than an associative array so stock macOS bash 3.2 works)
image_for() {
  case "$1" in
    llama-cpp-arm) echo "quay.io/eelgaev/llama-cpp-arm:latest" ;;
    llama-cpp-x86) echo "quay.io/eelgaev/llama-cpp-x86:latest" ;;
    vllm-x86)      echo "quay.io/PLACEHOLDER/vllm:x86" ;; # Nahh
    # ... add more type-arch entries here ...
    *) return 1 ;;
  esac
}
KNOWN_IMAGES="llama-cpp-arm llama-cpp-x86 vllm-x86"

# ----------------------------------------------------------------------------
# Tunables
# ----------------------------------------------------------------------------
NS="${NS:-llm-recipes}"
NFD_NS="openshift-nfd"
GPU_NS="nvidia-gpu-operator"
WORKLOAD_SA="llm-recipe"
GPU_LABEL="feature.node.kubernetes.io/pci-10de.present=true"
PORT=52395
CSV_TIMEOUT="${CSV_TIMEOUT:-600}"          # seconds to wait for an operator CSV
RECONCILE_RESYNC="${RECONCILE_RESYNC:-300}"
DRY_RUN="${DRY_RUN:-false}"                 # true -> skip cluster mutations, render only
REPO_URL="${REPO_URL:-https://github.com/eelgaev/llm-cluster-recipes.git}"
REPO_REF="${REPO_REF:-main}"
MODEL_CACHE_ROOT="${MODEL_CACHE_ROOT:-/var/cache/llm-cluster-recipes/models}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for timeout_name in CSV_TIMEOUT RECONCILE_RESYNC; do
  timeout_value=${!timeout_name}
  [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]] \
    || die "$timeout_name must be a positive integer (got: $timeout_value)"
done
case "$DRY_RUN" in true|false) ;; *) die "DRY_RUN must be true or false" ;; esac

oc_apply() {
  if [ "$DRY_RUN" = true ]; then
    oc apply --dry-run=client -f -
  else
    oc apply -f -
  fi
}

# wait_for <timeout-seconds> <description> <command...>
# Polls until the command succeeds (exit 0) or the timeout elapses.
wait_for() {
  local timeout=$1 desc=$2; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start >= timeout )); then
      die "timed out after ${timeout}s waiting for: $desc"
    fi
    sleep 5
  done
}

csv_succeeded() {
  local ns=$1 pkg=$2 csv
  csv=$(oc get subscription "$pkg" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null) || return 1
  [ -n "$csv" ] || return 1
  [ "$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Succeeded" ]
}

# ----------------------------------------------------------------------------
# 1. Args & preflight
# ----------------------------------------------------------------------------
usage() {
  die "usage: $0 <http-url-to-recipe-folder> --register-url <https-url>
       $0 uninstall"
}

if [ "${1:-}" = uninstall ]; then
  shift
  [ $# -eq 0 ] || usage
  if ! [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#NS}" -gt 63 ]; then
    die "NS must be a valid Kubernetes namespace name (got: $NS)"
  fi
  command -v oc >/dev/null 2>&1 || die "required tool not found: oc"
  oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (oc whoami failed)"
  log "Uninstalling the LLM recipe workload from namespace $NS"
  oc delete clusterrolebinding "llm-recipe-node-reader-$NS" --ignore-not-found
  oc delete clusterrole "llm-recipe-node-reader-$NS" --ignore-not-found
  oc delete securitycontextconstraints "llm-recipe-host-cache-$NS" --ignore-not-found
  oc delete namespace "$NS" --ignore-not-found --wait=false
  log "Uninstall submitted; the shared NFD/GPU Operator installation and node model cache were preserved"
  exit 0
fi

BASE=""
REGISTER_URL=""   # pods POST {host,port,api_key} here once healthy
while [ $# -gt 0 ]; do
  case "$1" in
    --register-url)   [ $# -ge 2 ] || usage; REGISTER_URL=$2; shift 2 ;;
    --register-url=*) REGISTER_URL=${1#*=}; shift ;;
    -h|--help)        usage ;;
    -*)               die "unknown option: $1" ;;
    *)                [ -z "$BASE" ] || usage; BASE="${1%/}"; shift ;;
  esac
done
[ -n "$BASE" ] || usage
[ -n "$REGISTER_URL" ] || die "--register-url is required"
case "$BASE" in
  http://*|https://*) ;;
  *) die "recipe URL must start with http:// or https:// (got: $BASE)" ;;
esac
case "$REGISTER_URL" in
  https://*) ;;
  *) die "registration URL must start with https:// (got: $REGISTER_URL)" ;;
esac
for u in "$BASE" "$REGISTER_URL"; do
  case "$u" in
    *[[:space:]]*|*'"'*|*\\*) die "URL contains unsupported whitespace, quote, or backslash: $u" ;;
  esac
done
if ! [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [ "${#NS}" -gt 63 ]; then
  die "NS must be a valid Kubernetes namespace name (got: $NS)"
fi
if ! [[ "$MODEL_CACHE_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || [ "$MODEL_CACHE_ROOT" = / ] \
    || [[ "/$MODEL_CACHE_ROOT/" == *"/../"* ]]; then
  die "MODEL_CACHE_ROOT must be a non-root absolute path without '..' (got: $MODEL_CACHE_ROOT)"
fi
MODEL_CACHE_ROOT=${MODEL_CACHE_ROOT%/}
RECIPE_URL="$BASE/recipe.yaml"

for tool in oc curl git yq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
yq --version 2>/dev/null | grep -q 'mikefarah\|version v4' \
  || warn "yq does not look like mikefarah/yq v4 — parsing may fail"
oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (oc whoami failed)"
log "Logged in as $(oc whoami) on $(oc whoami --show-server)"

# ----------------------------------------------------------------------------
# 2. Fetch & validate recipe
# ----------------------------------------------------------------------------
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RECIPE="$WORKDIR/recipe.yaml"
REPO_DIR="$WORKDIR/llm-cluster-recipes"

log "Cloning manifests from $REPO_URL (ref: $REPO_REF)"
git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR" \
  || die "failed to clone $REPO_URL at ref $REPO_REF"
MANIFEST_DIR="$REPO_DIR/manifests"
[ -d "$MANIFEST_DIR" ] || die "cloned repository does not contain a manifests directory"
REQUIRED_MANIFESTS="
cluster-policy.yaml
gpu-operator.yaml
nfd-gpu-rule.yaml
recipe-script-configmap.yaml
reconciler-code.yaml
reconciler-deployment.yaml
reconciler-template-configmap.yaml
workload-access.yaml
workload-daemonset.yaml
"
for manifest in $REQUIRED_MANIFESTS; do
  [ -f "$MANIFEST_DIR/$manifest" ] || die "required manifest not found: manifests/$manifest"
  yq -e '.' "$MANIFEST_DIR/$manifest" >/dev/null 2>&1 \
    || die "manifest is not valid YAML: manifests/$manifest"
done

log "Fetching recipe from $RECIPE_URL"
curl -fsSL "$RECIPE_URL" -o "$RECIPE" || die "failed to fetch $RECIPE_URL"

yq -e '.' "$RECIPE" >/dev/null 2>&1 || die "recipe.yaml is not valid YAML"
yq -e 'type == "!!map"' "$RECIPE" >/dev/null 2>&1 || die "recipe must be a YAML mapping"
yq -e '(.name | type == "!!str") and (.name | length > 0)' "$RECIPE" >/dev/null 2>&1 \
  || die "recipe name must be a non-empty string"
yq -e '(.type | type == "!!str") and (.type | length > 0)' "$RECIPE" >/dev/null 2>&1 \
  || die "recipe type must be a non-empty string"
yq -e '(.script | type == "!!str") and (.script | length > 0)' "$RECIPE" >/dev/null 2>&1 \
  || die "recipe script must be a non-empty multiline string"
yq -e '(.vars == null) or ((.vars | type) == "!!map")' "$RECIPE" >/dev/null 2>&1 \
  || die "recipe vars must be a mapping"
yq -e '(.cacheKey == null) or ((.cacheKey | type) == "!!str" and (.cacheKey | length) > 0)' \
  "$RECIPE" >/dev/null 2>&1 \
  || die "recipe cacheKey must be a non-empty string"
yq -e '(.vars // {}) | keys | map(select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)) | length == 0' \
  "$RECIPE" >/dev/null 2>&1 \
  || die "recipe var names must be portable environment variable names"

RECIPE_NAME=$(yq -r '.name' "$RECIPE")
RECIPE_TYPE=$(yq -r '.type' "$RECIPE")
CACHE_KEY=$(yq -r '.cacheKey // .name' "$RECIPE")
if ! [[ "$RECIPE_NAME" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] \
    || [ "${#RECIPE_NAME}" -gt 63 ]; then
  die "recipe name must be a valid Kubernetes label value of at most 63 characters"
fi
if ! [[ "$RECIPE_TYPE" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]]; then
  die "recipe type contains unsupported characters: $RECIPE_TYPE"
fi
if ! [[ "$CACHE_KEY" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] \
    || [ "${#CACHE_KEY}" -gt 128 ]; then
  die "recipe cacheKey must be a safe path segment of at most 128 characters"
fi
MODEL_CACHE_PATH="$MODEL_CACHE_ROOT/$CACHE_KEY"

RESERVED_VARS=" RECIPE_BASE_URL PORT REGISTER_URL NODE_NAME NODE_HOST_IP API_KEY TLS_KEY TLS_CRT "
while IFS= read -r var_type; do
  case "$var_type" in
    '!!str'|'!!int'|'!!float'|'!!bool') ;;
    *) die "recipe var values must be strings, numbers, or booleans" ;;
  esac
done < <(yq -r '.vars // {} | to_entries[] | .value | type' "$RECIPE")
while IFS= read -r var_name; do
  case "$RESERVED_VARS" in
    *" $var_name "*) die "recipe var is reserved by the runner: $var_name" ;;
  esac
done < <(yq -r '.vars // {} | keys | .[]' "$RECIPE")
if yq -e '.image' "$RECIPE" >/dev/null 2>&1; then
  warn "recipe declares image — ignored; images come from image_for() by type+arch"
fi
log "Recipe '$RECIPE_NAME' type=$RECIPE_TYPE"
log "Model cache: $MODEL_CACHE_PATH on each GPU node"
log "Pods will register at $REGISTER_URL once healthy"

# ----------------------------------------------------------------------------
# 3. Configure the parent-managed NFD + install NVIDIA GPU Operator (OLM)
# ----------------------------------------------------------------------------
configure_nfd_gpu_label() {
  log "Configuring NVIDIA GPU detection in the existing NFD deployment"
  if [ "$DRY_RUN" != true ]; then
    wait_for "$CSV_TIMEOUT" "parent-managed NFD operator CSV Succeeded" \
      csv_succeeded "$NFD_NS" nfd
    oc get nodefeaturediscovery nfd -n "$NFD_NS" >/dev/null 2>&1 \
      || die "parent-managed NodeFeatureDiscovery/nfd not found in $NFD_NS"
  fi

  # DPF relies on compound PCI labels (class_vendor_device). Add the vendor-only
  # label required by the NVIDIA GPU Operator without changing DPF's NFD config.
  NFD_NS="$NFD_NS" yq '.metadata.namespace = strenv(NFD_NS)' \
    "$MANIFEST_DIR/nfd-gpu-rule.yaml" | oc_apply
}

install_gpu_operator() {
  log "Installing NVIDIA GPU Operator"
  local channel
  channel=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)
  [ -n "$channel" ] || { warn "could not read default channel for gpu-operator-certified; using 'stable'"; channel=stable; }

  GPU_NS="$GPU_NS" CHANNEL="$channel" yq '
    (select(.kind == "Namespace").metadata.name) = strenv(GPU_NS) |
    (select(.kind != "Namespace").metadata.namespace) = strenv(GPU_NS) |
    (select(.kind == "OperatorGroup").spec.targetNamespaces) = [strenv(GPU_NS)] |
    (select(.kind == "Subscription").spec.channel) = strenv(CHANNEL)
  ' "$MANIFEST_DIR/gpu-operator.yaml" | oc_apply
  [ "$DRY_RUN" = true ] && return
  wait_for "$CSV_TIMEOUT" "GPU Operator CSV Succeeded" csv_succeeded "$GPU_NS" gpu-operator-certified

  if oc get clusterpolicy gpu-cluster-policy >/dev/null 2>&1; then
    log "ClusterPolicy already exists"
  else
    # Prefer the operator's own default CR (alm-examples) so version-specific fields are right.
    local csv cp="$WORKDIR/clusterpolicy.json"
    csv=$(oc get subscription gpu-operator-certified -n "$GPU_NS" -o jsonpath='{.status.installedCSV}')
    oc get csv "$csv" -n "$GPU_NS" -o jsonpath='{.metadata.annotations.alm-examples}' \
      | yq -p json -o json '.[] | select(.kind == "ClusterPolicy")' > "$cp" 2>/dev/null || true
    if [ -s "$cp" ]; then
      log "Creating ClusterPolicy from operator defaults"
      oc_apply < "$cp"
    else
      log "Creating minimal ClusterPolicy"
      oc_apply < "$MANIFEST_DIR/cluster-policy.yaml"
    fi
  fi

  # GPU operands need to run before a DPF host is Ready. Preserve existing
  # settings while adding the required taint tolerance and point
  # k8s-driver-manager at the externally reachable API endpoint rather than the
  # cluster Service VIP. Explicit manager env is supported by ClusterPolicy and
  # survives GPU Operator reconciliation.
  local api_url api_authority api_host api_port cp_patch
  api_url=$(oc whoami --show-server)
  api_authority=${api_url#https://}
  api_authority=${api_authority%%/*}
  api_host=${api_authority%:*}
  api_port=${api_authority##*:}
  [ -n "$api_host" ] && [ -n "$api_port" ] && [ "$api_host" != "$api_port" ] \
    || die "could not parse API host and port from: $api_url"

  # shellcheck disable=SC2016 # yq variables are intentionally single-quoted
  cp_patch=$(API_HOST="$api_host" API_PORT="$api_port" \
    oc get clusterpolicy gpu-cluster-policy -o json | \
    API_HOST="$api_host" API_PORT="$api_port" yq -p json -o json -I=0 '
      (.spec.daemonsets.tolerations // []) as $tolerations |
      (.spec.driver.manager.env // []) as $manager_env |
      {"spec": {
        "daemonsets": {"tolerations": (
          ($tolerations | map(select(
            .key != "nvidia.com/gpu" and
            .key != "node.kubernetes.io/not-ready"
          ))) + [
            {"key":"nvidia.com/gpu", "operator":"Exists", "effect":"NoSchedule"},
            {"key":"node.kubernetes.io/not-ready", "operator":"Exists", "effect":"NoSchedule"}
          ]
        )},
        "driver": {"manager": {"env": (
          ($manager_env | map(select(
            .name != "KUBERNETES_SERVICE_HOST" and
            .name != "KUBERNETES_SERVICE_PORT"
          ))) + [
            {"name":"KUBERNETES_SERVICE_HOST", "value":strenv(API_HOST)},
            {"name":"KUBERNETES_SERVICE_PORT", "value":strenv(API_PORT)}
          ]
        )}}
      }}')
  oc patch clusterpolicy gpu-cluster-policy --type=merge -p "$cp_patch" >/dev/null
  log "Configured GPU operands for not-ready nodes and external API access"

  # ClusterPolicy has no field for these common pod-level network settings.
  # Patch every generated operand DaemonSet so API-using init containers (not
  # just k8s-driver-manager) use host networking, the host resolver, and the
  # external API endpoint. Strategic merge preserves all other container env.
  # The GPU Operator preserves these fields when reconciling managed settings.
  wait_for "$CSV_TIMEOUT" "NVIDIA driver DaemonSet to be generated" \
    sh -c "oc get daemonsets -n '$GPU_NS' -o name | grep -q '/nvidia-driver-daemonset-'"
  local operand_ds operand_json operand_patch
  for operand_ds in $(oc get daemonsets -n "$GPU_NS" -o name | awk -F/ '{ print $2 }'); do
    operand_json=$(oc get daemonset "$operand_ds" -n "$GPU_NS" -o json)
    # shellcheck disable=SC2016 # yq variables are intentionally single-quoted
    operand_patch=$(API_HOST="$api_host" API_PORT="$api_port" \
      yq -p json -o json -I=0 '
        . as $ds |
        {"spec":{"template":{"spec":{
          "hostNetwork":true,
          "dnsPolicy":"Default",
          "initContainers": (($ds.spec.template.spec.initContainers // []) |
            map({"name":.name, "env":(
              ((.env // []) | map(select(
                .name != "KUBERNETES_SERVICE_HOST" and
                .name != "KUBERNETES_SERVICE_PORT"
              ))) + [
                {"name":"KUBERNETES_SERVICE_HOST", "value":strenv(API_HOST)},
                {"name":"KUBERNETES_SERVICE_PORT", "value":strenv(API_PORT)}
              ]
            )})),
          "containers": (($ds.spec.template.spec.containers // []) |
            map({"name":.name, "env":(
              ((.env // []) | map(select(
                .name != "KUBERNETES_SERVICE_HOST" and
                .name != "KUBERNETES_SERVICE_PORT"
              ))) + [
                {"name":"KUBERNETES_SERVICE_HOST", "value":strenv(API_HOST)},
                {"name":"KUBERNETES_SERVICE_PORT", "value":strenv(API_PORT)}
              ]
            )}))
        }}}}' <<<"$operand_json")
    oc patch daemonset "$operand_ds" -n "$GPU_NS" --type=strategic \
      -p "$operand_patch" >/dev/null
  done
  log "Configured NVIDIA operand networking (hostNetwork, host DNS, external API)"

  # ClusterPolicy and its operands are controllers themselves. Do not keep this
  # client attached while they converge; the in-cluster workload reconciler below
  # will wait for the device plugin to advertise GPU capacity.
  log "ClusterPolicy submitted; GPU Operator will continue reconciling it"
}

configure_nfd_gpu_label
install_gpu_operator

# ----------------------------------------------------------------------------
# 4. Discover GPU-node architectures
# ----------------------------------------------------------------------------
gpu_nodes_json() {
  oc get nodes -l "$GPU_LABEL" -o json
}

if [ "$DRY_RUN" = true ]; then
  warn "DRY_RUN: assuming one amd64 GPU group with 1 GPU"
  ARCH_GROUPS="amd64"
else
  log "Discovering GPU nodes (label $GPU_LABEL)"
  wait_for 120 "at least one node labeled $GPU_LABEL" \
    sh -c "oc get nodes -l '$GPU_LABEL' -o name | grep -q ."

  # Capacity may not exist yet. Discover only architecture here; an in-cluster
  # reconciler derives the GPU count and creates/updates the DaemonSet later.
  ARCH_GROUPS=$(gpu_nodes_json | yq -p json -oy -r '
    .items
    | map(.status.nodeInfo.architecture)
    | unique
    | .[]')
fi
[ -n "$ARCH_GROUPS" ] || die "no GPU nodes found"

log "GPU node groups:"
[ "$DRY_RUN" = true ] || oc get nodes -l "$GPU_LABEL" \
  -o custom-columns='NODE:.metadata.name,ARCH:.status.nodeInfo.architecture,GPUS:.status.capacity.nvidia\.com/gpu'

# ----------------------------------------------------------------------------
# 5. Render workloads
# ----------------------------------------------------------------------------
log "Creating namespace $NS and recipe ConfigMap"
NS="$NS" WORKLOAD_SA="$WORKLOAD_SA" yq '
  (select(.kind == "Namespace").metadata.name) = strenv(NS) |
  (select(.kind != "Namespace" and .kind != "ClusterRole" and .kind != "ClusterRoleBinding" and .kind != "SecurityContextConstraints").metadata.namespace) = strenv(NS) |
  (select(.kind == "ServiceAccount" and .metadata.name == "llm-recipe").metadata.name) = strenv(WORKLOAD_SA) |
  (select(.kind == "SecurityContextConstraints").metadata.name) = ("llm-recipe-host-cache-" + strenv(NS)) |
  (select(.kind == "RoleBinding" and .metadata.name == "llm-recipe-use-host-cache").roleRef.name) = ("system:openshift:scc:llm-recipe-host-cache-" + strenv(NS)) |
  (select(.kind == "RoleBinding" and .metadata.name == "llm-recipe-use-host-cache").subjects[0].name) = strenv(WORKLOAD_SA) |
  (select(.kind == "RoleBinding" and .metadata.name == "llm-recipe-use-host-cache").subjects[0].namespace) = strenv(NS) |
  (select(.kind == "ClusterRole").metadata.name) = ("llm-recipe-node-reader-" + strenv(NS)) |
  (select(.kind == "ClusterRoleBinding").metadata.name) = ("llm-recipe-node-reader-" + strenv(NS)) |
  (select(.kind == "ClusterRoleBinding").roleRef.name) = ("llm-recipe-node-reader-" + strenv(NS)) |
  (select(.kind == "ClusterRoleBinding").subjects[0].namespace) = strenv(NS) |
  (select(.kind == "RoleBinding" and .metadata.name == "llm-recipe-daemonset-reconciler").subjects[0].namespace) = strenv(NS)
' "$MANIFEST_DIR/workload-access.yaml" | oc_apply

# ConfigMap: recipe script
yq '.script' "$RECIPE" > "$WORKDIR/script.sh"
read -r script_crc script_bytes _ < <(cksum < "$WORKDIR/script.sh")
SCRIPT_CHECKSUM="${script_crc}-${script_bytes}"
NS="$NS" RECIPE_NAME="$RECIPE_NAME" SCRIPT_FILE="$WORKDIR/script.sh" yq '
  .metadata.namespace = strenv(NS) |
  .metadata.labels.recipe = strenv(RECIPE_NAME) |
  .data."script.sh" = load_str(strenv(SCRIPT_FILE))
' "$MANIFEST_DIR/recipe-script-configmap.yaml" | oc_apply

render_daemonset() {
  local arch=$1 gpus=$2 image=$3 k8s_arch=$4
  NS="$NS" WORKLOAD_SA="$WORKLOAD_SA" RECIPE_NAME="$RECIPE_NAME" \
    SCRIPT_CHECKSUM="$SCRIPT_CHECKSUM" ARCH="$arch" GPU_COUNT="$gpus" \
    IMAGE="$image" K8S_ARCH="$k8s_arch" BASE="$BASE" PORT="$PORT" \
    REGISTER_URL="$REGISTER_URL" RECIPE="$RECIPE" MODEL_CACHE_PATH="$MODEL_CACHE_PATH" yq '
      .metadata.name = ("llm-recipe-" + strenv(ARCH)) |
      .metadata.namespace = strenv(NS) |
      .metadata.labels.recipe = strenv(RECIPE_NAME) |
      .metadata.labels.arch = strenv(ARCH) |
      .spec.selector.matchLabels.arch = strenv(ARCH) |
      .spec.template.metadata.labels.recipe = strenv(RECIPE_NAME) |
      .spec.template.metadata.labels.arch = strenv(ARCH) |
      .spec.template.metadata.annotations."llm-recipes.openai.com/script-checksum" = strenv(SCRIPT_CHECKSUM) |
      .spec.template.spec.serviceAccountName = strenv(WORKLOAD_SA) |
      .spec.template.spec.nodeSelector."kubernetes.io/arch" = strenv(K8S_ARCH) |
      .spec.template.spec.containers[0].image = strenv(IMAGE) |
      (.spec.template.spec.containers[0].env[] | select(.name == "RECIPE_BASE_URL").value) = strenv(BASE) |
      (.spec.template.spec.containers[0].env[] | select(.name == "PORT").value) = strenv(PORT) |
      (.spec.template.spec.containers[0].env[] | select(.name == "REGISTER_URL").value) = strenv(REGISTER_URL) |
      .spec.template.spec.containers[0].ports[0].containerPort = env(PORT) |
      .spec.template.spec.containers[0].ports[0].hostPort = env(PORT) |
      .spec.template.spec.containers[0].resources.limits."nvidia.com/gpu" = strenv(GPU_COUNT) |
      (.spec.template.spec.volumes[] | select(.name == "models").hostPath.path) = strenv(MODEL_CACHE_PATH) |
      .spec.template.spec.containers[0].env +=
        (load(strenv(RECIPE)).vars // {} | to_entries | map({"name": .key, "value": (.value | tostring)}))
    ' "$MANIFEST_DIR/workload-daemonset.yaml"
}

CLI_IMAGE="quay.io/openshift/origin-cli:latest"
if [ "$DRY_RUN" != true ]; then
  discovered_cli_image=$(oc adm release info --image-for=cli 2>/dev/null || true)
  [ -z "$discovered_cli_image" ] || CLI_IMAGE=$discovered_cli_image
fi

# This controller-side loop is deliberately stored in-cluster. The invoking
# shell can exit while it waits for every matching node to advertise capacity.
NS="$NS" yq '.metadata.namespace = strenv(NS)' \
  "$MANIFEST_DIR/reconciler-code.yaml" | oc_apply

DEPLOYED_ARCHES=
while read -r k8s_arch; do
  [ -n "$k8s_arch" ] || continue
  case "$k8s_arch" in
    amd64) arch=x86 ;;
    arm64) arch=arm ;;
    *) die "unsupported node architecture: $k8s_arch" ;;
  esac
  key="${RECIPE_TYPE}-${arch}"
  image=$(image_for "$key") \
    || die "no image for '$key' (known: $KNOWN_IMAGES) — add an entry to image_for() in run-recipe.sh"

  # Keep a complete DaemonSet template in a ConfigMap. The placeholder is
  # replaced only after node status contains a numeric GPU capacity.
  ds_template="$WORKDIR/daemonset-$arch.yaml"
  render_daemonset "$arch" "__GPU_COUNT__" "$image" "$k8s_arch" > "$ds_template"
  read -r template_crc template_bytes _ < <(cksum < "$ds_template")
  template_checksum="${template_crc}-${template_bytes}"

  log "Creating in-cluster reconciler for llm-recipe-$arch (image=$image)"
  NS="$NS" ARCH="$arch" DS_TEMPLATE="$ds_template" yq '
    .metadata.name = ("llm-recipe-reconciler-" + strenv(ARCH)) |
    .metadata.namespace = strenv(NS) |
    .data."daemonset.yaml" = load_str(strenv(DS_TEMPLATE))
  ' "$MANIFEST_DIR/reconciler-template-configmap.yaml" | oc_apply

  NS="$NS" ARCH="$arch" K8S_ARCH="$k8s_arch" CLI_IMAGE="$CLI_IMAGE" \
    TEMPLATE_CHECKSUM="$template_checksum" RECONCILE_RESYNC="$RECONCILE_RESYNC" yq '
      .metadata.name = ("llm-recipe-reconciler-" + strenv(ARCH)) |
      .metadata.namespace = strenv(NS) |
      .metadata.labels.arch = strenv(ARCH) |
      .spec.selector.matchLabels.arch = strenv(ARCH) |
      .spec.template.metadata.labels.arch = strenv(ARCH) |
      .spec.template.metadata.annotations."llm-recipes.openai.com/template-checksum" = strenv(TEMPLATE_CHECKSUM) |
      .spec.template.spec.containers[0].image = strenv(CLI_IMAGE) |
      (.spec.template.spec.containers[0].env[] | select(.name == "TARGET_NAMESPACE").value) = strenv(NS) |
      (.spec.template.spec.containers[0].env[] | select(.name == "K8S_ARCH").value) = strenv(K8S_ARCH) |
      (.spec.template.spec.containers[0].env[] | select(.name == "DS_NAME").value) = ("llm-recipe-" + strenv(ARCH)) |
      (.spec.template.spec.containers[0].env[] | select(.name == "RECONCILE_RESYNC").value) = strenv(RECONCILE_RESYNC) |
      .spec.template.spec.volumes[0].configMap.name = ("llm-recipe-reconciler-" + strenv(ARCH))
    ' "$MANIFEST_DIR/reconciler-deployment.yaml" | oc_apply
  DEPLOYED_ARCHES="$DEPLOYED_ARCHES $arch"
done <<<"$ARCH_GROUPS"

# Remove DaemonSets for archs that are no longer present (e.g. re-run after node removal)
if [ "$DRY_RUN" != true ]; then
  for existing in $(oc get ds -n "$NS" -l app=llm-recipe -o jsonpath='{.items[*].metadata.name}'); do
    keep=false
    for a in $DEPLOYED_ARCHES; do [ "$existing" = "llm-recipe-$a" ] && keep=true; done
    [ "$keep" = true ] || { warn "deleting stale DaemonSet $existing"; oc delete ds "$existing" -n "$NS"; }
  done
fi

# ----------------------------------------------------------------------------
# 6. Report
# ----------------------------------------------------------------------------
[ "$DRY_RUN" = true ] && { log "DRY_RUN complete"; exit 0; }

log "Recipe '$RECIPE_NAME' submitted. In-cluster reconcilers will create the DaemonSets when GPU capacity is available."
log "Servers (hostNetwork) will then be reachable at:"
oc get nodes -l "$GPU_LABEL" -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  | sed "s|^|  https://|; s|\$|:$PORT|"
echo
log "Reconciler:      oc logs -f -l app=llm-recipe-reconciler -n $NS --all-containers --max-log-requests=20"
log "Tail logs with:   oc logs -f -l app=llm-recipe -n $NS --all-containers --max-log-requests=20"
log "Pods:             oc get pods -n $NS -o wide"

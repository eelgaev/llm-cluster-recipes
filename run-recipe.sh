#!/usr/bin/env bash
#
# run-recipe.sh — install the NVIDIA GPU Operator on an OpenShift cluster and run an
# LLM "recipe" on every GPU worker via a DaemonSet (one DaemonSet per node architecture).
#
# Usage: ./run-recipe.sh <http-url-to-recipe-folder> --register-url <https-url>
#   e.g. ./run-recipe.sh https://host/recipes/qwen3.8-27B/ --register-url https://router/register
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
    llama-cpp-arm) echo "quay.io/PLACEHOLDER/llama-cpp:arm" ;;
    llama-cpp-x86) echo "quay.io/PLACEHOLDER/llama-cpp:x86" ;;
    vllm-x86)      echo "quay.io/PLACEHOLDER/vllm:x86" ;;
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
CLUSTERPOLICY_TIMEOUT="${CLUSTERPOLICY_TIMEOUT:-1800}"
GPU_CAPACITY_TIMEOUT="${GPU_CAPACITY_TIMEOUT:-600}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-1800}"
DRY_RUN="${DRY_RUN:-false}"                 # true -> skip cluster mutations, render only

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for timeout_name in CSV_TIMEOUT CLUSTERPOLICY_TIMEOUT GPU_CAPACITY_TIMEOUT ROLLOUT_TIMEOUT; do
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
usage() { die "usage: $0 <http-url-to-recipe-folder> --register-url <https-url>"; }
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
RECIPE_URL="$BASE/recipe.yaml"

for tool in oc curl yq; do
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
yq -e '(.vars // {}) | keys | map(select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)) | length == 0' \
  "$RECIPE" >/dev/null 2>&1 \
  || die "recipe var names must be portable environment variable names"

RECIPE_NAME=$(yq -r '.name' "$RECIPE")
RECIPE_TYPE=$(yq -r '.type' "$RECIPE")
if ! [[ "$RECIPE_NAME" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] \
    || [ "${#RECIPE_NAME}" -gt 63 ]; then
  die "recipe name must be a valid Kubernetes label value of at most 63 characters"
fi
if ! [[ "$RECIPE_TYPE" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]]; then
  die "recipe type contains unsupported characters: $RECIPE_TYPE"
fi

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
  oc_apply <<EOF
apiVersion: nfd.openshift.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: llm-nvidia-gpu-detection
  namespace: $NFD_NS
spec:
  rules:
    - name: NVIDIA GPU detection
      labels:
        "pci-10de.present": "true"
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["10de"]}
            class: {op: InRegexp, value: ["^03"]}
EOF
}

install_gpu_operator() {
  log "Installing NVIDIA GPU Operator"
  local channel
  channel=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace \
    -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)
  [ -n "$channel" ] || { warn "could not read default channel for gpu-operator-certified; using 'stable'"; channel=stable; }

  oc_apply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $GPU_NS
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: $GPU_NS
spec:
  targetNamespaces:
    - $GPU_NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: $GPU_NS
spec:
  channel: "$channel"
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
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
      oc_apply <<EOF
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  driver:
    enabled: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "true"
EOF
    fi
  fi

  log "Waiting for ClusterPolicy to become ready (driver build can take a while)"
  wait_for "$CLUSTERPOLICY_TIMEOUT" "ClusterPolicy state=ready" \
    sh -c '[ "$(oc get clusterpolicy gpu-cluster-policy -o jsonpath="{.status.state}")" = ready ]'
}

configure_nfd_gpu_label
install_gpu_operator

# ----------------------------------------------------------------------------
# 4. Discover GPU nodes, arch, and capacity
# ----------------------------------------------------------------------------
gpu_nodes_json() {
  oc get nodes -l "$GPU_LABEL" -o json
}

if [ "$DRY_RUN" = true ]; then
  warn "DRY_RUN: assuming one amd64 GPU group with 1 GPU"
  ARCH_GROUPS="amd64 1"
else
  log "Discovering GPU nodes (label $GPU_LABEL)"
  wait_for 120 "at least one node labeled $GPU_LABEL" \
    sh -c "oc get nodes -l '$GPU_LABEL' -o name | grep -q ."

  # Device plugin may not have advertised capacity yet — wait for every GPU node to report >0.
  all_nodes_have_capacity() {
    local caps
    caps=$(gpu_nodes_json | yq -p json -oy -r '.items[] | .status.capacity."nvidia.com/gpu" // "0"')
    [ -n "$caps" ] && ! grep -qx '0' <<<"$caps"
  }
  wait_for "$GPU_CAPACITY_TIMEOUT" "nvidia.com/gpu capacity on all GPU nodes" all_nodes_have_capacity

  # lines: "<arch> <min-gpu-count> <number-of-distinct-counts>" per distinct arch
  ARCH_GROUPS=$(gpu_nodes_json | yq -p json -oy -r '
    .items
    | map({"arch": .status.nodeInfo.architecture,
           "gpus": (.status.capacity."nvidia.com/gpu" | tonumber)})
    | group_by(.arch)
    | .[]
    | (map(.gpus) | unique) as $counts
    | .[0].arch + " " + (($counts | min) | tostring) + " " + (($counts | length) | tostring)')
fi
[ -n "$ARCH_GROUPS" ] || die "no GPU nodes found"

log "GPU node groups:"
[ "$DRY_RUN" = true ] || oc get nodes -l "$GPU_LABEL" \
  -o custom-columns='NODE:.metadata.name,ARCH:.status.nodeInfo.architecture,GPUS:.status.capacity.nvidia\.com/gpu'

# ----------------------------------------------------------------------------
# 5. Render workloads
# ----------------------------------------------------------------------------
log "Creating namespace $NS and recipe ConfigMap"
oc_apply <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $WORKLOAD_SA
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: llm-recipe-use-hostnetwork-v2
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:hostnetwork-v2
subjects:
  - kind: ServiceAccount
    name: $WORKLOAD_SA
    namespace: $NS
EOF

# ConfigMap: recipe script — let oc do the multiline quoting
yq '.script' "$RECIPE" > "$WORKDIR/script.sh"
read -r script_crc script_bytes _ < <(cksum < "$WORKDIR/script.sh")
SCRIPT_CHECKSUM="${script_crc}-${script_bytes}"
oc create configmap llm-recipe-script -n "$NS" \
    --from-file=script.sh="$WORKDIR/script.sh" --dry-run=client -o yaml \
  | RECIPE_NAME="$RECIPE_NAME" yq '.metadata.labels = {"app":"llm-recipe","recipe": strenv(RECIPE_NAME)}' \
  | oc_apply

# Append the recipe's `vars` map to the container env of a DaemonSet read on stdin.
add_recipe_vars() {
  RECIPE="$RECIPE" yq '
    .spec.template.spec.containers[0].env +=
      (load(strenv(RECIPE)).vars // {} | to_entries | map({"name": .key, "value": (.value | tostring)}))'
}

render_daemonset() {
  local arch=$1 gpus=$2 image=$3 k8s_arch=$4
  cat <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: llm-recipe-$arch
  namespace: $NS
  labels:
    app: llm-recipe
    recipe: $RECIPE_NAME
    arch: $arch
spec:
  selector:
    matchLabels:
      app: llm-recipe
      arch: $arch
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: llm-recipe
        recipe: $RECIPE_NAME
        arch: $arch
      annotations:
        llm-recipes.openai.com/script-checksum: "$SCRIPT_CHECKSUM"
    spec:
      serviceAccountName: $WORKLOAD_SA
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        feature.node.kubernetes.io/pci-10de.present: "true"
        kubernetes.io/arch: $k8s_arch
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: llm
          image: $image
          imagePullPolicy: Always
          command: ["/usr/local/bin/entrypoint.sh"]
          env:
            - name: RECIPE_BASE_URL
              value: "$BASE"
            - name: PORT
              value: "$PORT"
            - name: REGISTER_URL
              value: "$REGISTER_URL"
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: NODE_HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
          ports:
            - name: https
              containerPort: $PORT
              hostPort: $PORT
              protocol: TCP
          startupProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - 'curl -ksf -H "Authorization: Bearer \${API_KEY}" "https://127.0.0.1:\${PORT}/health" >/dev/null'
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 360
          readinessProbe:
            exec:
              command:
                - /bin/bash
                - -c
                - 'curl -ksf -H "Authorization: Bearer \${API_KEY}" "https://127.0.0.1:\${PORT}/health" >/dev/null'
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          resources:
            limits:
              nvidia.com/gpu: "$gpus"
          volumeMounts:
            - name: recipe
              mountPath: /recipe
            - name: models
              mountPath: /models
            - name: certs
              mountPath: /certs
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: recipe
          configMap:
            name: llm-recipe-script
            defaultMode: 0755
        - name: models
          emptyDir: {}
        - name: certs
          emptyDir: {}
        - name: shm
          emptyDir:
            medium: Memory
EOF
}

DEPLOYED_ARCHES=
while read -r k8s_arch gpus ncounts; do
  [ -n "$k8s_arch" ] || continue
  case "$k8s_arch" in
    amd64) arch=x86 ;;
    arm64) arch=arm ;;
    *) die "unsupported node architecture: $k8s_arch" ;;
  esac
  [ "${ncounts:-1}" -gt 1 ] && warn "GPU nodes of arch $k8s_arch differ in GPU count; using minimum ($gpus)"

  key="${RECIPE_TYPE}-${arch}"
  image=$(image_for "$key") \
    || die "no image for '$key' (known: $KNOWN_IMAGES) — add an entry to image_for() in run-recipe.sh"

  log "Deploying DaemonSet llm-recipe-$arch (image=$image, gpus/node=$gpus)"
  render_daemonset "$arch" "$gpus" "$image" "$k8s_arch" | add_recipe_vars | oc_apply
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

for arch in $DEPLOYED_ARCHES; do
  log "Rollout status for DaemonSet llm-recipe-$arch"
  oc rollout status "ds/llm-recipe-$arch" -n "$NS" --timeout="${ROLLOUT_TIMEOUT}s" \
    || die "rollout failed or timed out for llm-recipe-$arch"
done

log "Recipe '$RECIPE_NAME' deployed. Servers (hostNetwork) will be reachable at:"
oc get nodes -l "$GPU_LABEL" -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  | sed "s|^|  https://|; s|\$|:$PORT|"
echo
log "Tail logs with:   oc logs -f -l app=llm-recipe -n $NS --all-containers --max-log-requests=20"
log "Pods:             oc get pods -n $NS -o wide"

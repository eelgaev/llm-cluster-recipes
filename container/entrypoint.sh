#!/usr/bin/env bash
# Container entrypoint for llm-cluster-recipes pods.
#
# Env provided by the DaemonSet: recipe vars, RECIPE_BASE_URL, REGISTER_URL,
# NODE_NAME, NODE_HOST_IP, PORT (defaults to 52395).
# Exports for the recipe script: TLS_KEY, TLS_CRT, PORT, API_KEY.
set -euo pipefail
umask 077

export PORT="${PORT:-52395}"
export TLS_KEY=/certs/key.pem TLS_CRT=/certs/cert.pem
mkdir -p /certs /models
rm -f /certs/registered

for tool in openssl curl bash; do
  command -v "$tool" >/dev/null || { echo "entrypoint: missing required tool: $tool" >&2; exit 1; }
done
[ -w /models ] || { echo "entrypoint: model cache is not writable" >&2; exit 1; }
[ -f /recipe/script.sh ] || { echo "entrypoint: no /recipe/script.sh mounted" >&2; exit 1; }

# per-pod API key for the server (llama.cpp --api-key, vllm/sglang equivalents)
API_KEY="$(openssl rand -hex 32)"
export API_KEY
printf '%s' "$API_KEY" > /certs/api-key

# self-signed cert (no host cert files)
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$TLS_KEY" -out "$TLS_CRT" -subj "/CN=llm-recipe" 2>/dev/null

: "${NODE_HOST_IP:?NODE_HOST_IP must be set}"
echo "entrypoint: node=${NODE_NAME:-<unset>} host=$NODE_HOST_IP port=$PORT base=${RECIPE_BASE_URL:-<unset>}"

# background: once the server is healthy, register this node with the router
: "${REGISTER_URL:?REGISTER_URL must be set}"
case "$REGISTER_URL" in
  https://*) ;;
  *) echo "entrypoint: REGISTER_URL must use https" >&2; exit 1 ;;
esac
(
  until curl --connect-timeout 2 --max-time 5 -ksf -H "Authorization: Bearer ${API_KEY}" \
    "https://127.0.0.1:${PORT}/health" >/dev/null; do sleep 5; done
  echo "entrypoint: server healthy, registering with $REGISTER_URL"
  while :; do
    status=$(curl --proto '=https' --connect-timeout 5 --max-time 30 -sS \
      -o /dev/null -w '%{http_code}' -X POST "$REGISTER_URL" -H 'Content-Type: application/json' \
      -d "{\"host\":\"${NODE_HOST_IP}\",\"port\":${PORT},\"api_key\":\"${API_KEY}\"}") || status=000
    case "$status" in
      2[0-9][0-9]) touch /certs/registered; break ;;
    esac
    echo "entrypoint: registration POST failed (HTTP $status); retrying" >&2
    sleep 5
  done
  echo "entrypoint: registration succeeded"
) &

# The recipe must remain in the foreground. If setup or the server fails, the
# container exits so Kubernetes reports the failure and restarts it.
exec bash /recipe/script.sh

#!/usr/bin/env bash
# MAINTAINER tool: stage weight files next to recipe.yaml so the HTTP server can serve them.
# NOT used by the cluster — run-recipe.sh never fetches or executes this.
# Requires HF_TOKEN in your environment. Run from inside this recipe folder.
set -euo pipefail
: "${HF_TOKEN:?set HF_TOKEN}"
cd "$(dirname "$0")"

GGUF="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main"

# local-name  source-url
FILES="
Qwen3.8-27B-UD-Q4_K_XL.gguf  $GGUF/Qwen3.8-27B-UD-Q4_K_XL.gguf
mtp-Qwen3.8-27B-Q4_0.gguf    $GGUF/MTP/mtp-Qwen3.8-27B-Q4_0.gguf
mmproj-BF16.gguf             $GGUF/mmproj-BF16.gguf
chat_template.jinja          https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates/resolve/main/chat_template.jinja
"

echo "$FILES" | while read -r name url; do
  [ -n "$name" ] || continue
  if [ -s "$name" ]; then
    echo "skip $name (already present)"
    continue
  fi
  echo "fetching $name"
  wget -c --header="Authorization: Bearer $HF_TOKEN" "$url" -O "$name"
done
echo "done — serve this folder over HTTP and pass its URL to run-recipe.sh"

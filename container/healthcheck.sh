#!/usr/bin/env bash
set -euo pipefail

# Exec probes have the container's original environment, not exports made by PID 1.
[ -s /certs/api-key ] || exit 1
if [ "${1:-ready}" = ready ]; then
  [ -f /certs/registered ] || exit 1
fi
curl --connect-timeout 2 --max-time 2 -ksf \
  -H "Authorization: Bearer $(cat /certs/api-key)" \
  "https://127.0.0.1:${PORT:-52395}/health" >/dev/null

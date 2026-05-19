#!/usr/bin/env bash
set -euo pipefail

API_URL="${1:-${API_URL:-http://13.206.255.84}}"
API_URL="${API_URL%/}"

payload='{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'

echo "Checking health endpoint: ${API_URL}/healthz"
curl -fsS "${API_URL}/healthz"
printf "\n\n"

echo "Calling inference endpoint: ${API_URL}/v1/chat/completions"
response="$(
  curl -fsS -m 180 -X POST "${API_URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "${payload}"
)"

printf '%s\n' "${response}"

printf '%s' "${response}" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
choices = data.get("choices")
if not choices:
    raise SystemExit("missing choices in response")
message = choices[0].get("message", {})
content = message.get("content", "")
if not isinstance(content, str) or not content.strip():
    raise SystemExit("missing assistant content in response")
print("\nSmoke test passed")
'

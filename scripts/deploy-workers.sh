#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  KEY_PATH=/path/key.pem \
  GATEWAY_HOST=13.206.255.84 \
  ENGINE_HOST=10.40.10.121 \
  CALLER_HOST=10.40.10.173 \
  INFERENCE_HOST=10.40.10.29 \
  ./scripts/deploy-workers.sh

Required environment:
  KEY_PATH        SSH private key path for the EC2 key pair
  GATEWAY_HOST    public IP/DNS of gateway VM
  ENGINE_HOST     private IP/DNS of engine VM
  CALLER_HOST     private IP/DNS of caller worker VM
  INFERENCE_HOST  private IP/DNS of inference worker VM

Optional environment:
  SSH_USER        default: ubuntu
  MAX_NEW_TOKENS  default: 64
USAGE
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env: ${name}" >&2
    usage >&2
    exit 2
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 2
  fi
}

require_env KEY_PATH
require_env GATEWAY_HOST
require_env ENGINE_HOST
require_env CALLER_HOST
require_env INFERENCE_HOST

SSH_USER="${SSH_USER:-ubuntu}"
MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-64}"
DEPLOY_ROOT="/opt/aws-distributed-inference"

require_cmd ssh
require_cmd scp
require_cmd tar

if [[ ! -f "${KEY_PATH}" ]]; then
  echo "KEY_PATH does not exist: ${KEY_PATH}" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$(mktemp -t alchemyst-devops.XXXXXX.tar.gz)"
REMOTE_ARCHIVE="/tmp/alchemyst-devops.tar.gz"

cleanup() {
  rm -f "${ARCHIVE}"
}
trap cleanup EXIT

SSH_COMMON=(
  -i "${KEY_PATH}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=30
)

PROXY_COMMAND="ssh -i ${KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p ${SSH_USER}@${GATEWAY_HOST}"

ssh_gateway() {
  ssh "${SSH_COMMON[@]}" "${SSH_USER}@${GATEWAY_HOST}" "$@"
}

ssh_private() {
  local host="$1"
  shift
  ssh "${SSH_COMMON[@]}" -o ProxyCommand="${PROXY_COMMAND}" "${SSH_USER}@${host}" "$@"
}

scp_gateway() {
  scp "${SSH_COMMON[@]}" "$@"
}

scp_private() {
  local src="$1"
  local host="$2"
  local dst="$3"
  scp "${SSH_COMMON[@]}" -o ProxyCommand="${PROXY_COMMAND}" "${src}" "${SSH_USER}@${host}:${dst}"
}

local_iii="$(command -v iii || true)"
local_iii_worker="$(command -v iii-worker || true)"
if [[ -z "${local_iii}" || -z "${local_iii_worker}" ]]; then
  echo "Local iii and iii-worker binaries must be installed before deploy." >&2
  echo "Install iii locally, then rerun this script." >&2
  exit 2
fi

echo "Building deployment archive from ${REPO_ROOT}"
tar \
  --exclude='.git' \
  --exclude='.terraform' \
  --exclude='terraform.tfvars' \
  --exclude='*.tfstate' \
  --exclude='tfplan*' \
  --exclude='node_modules' \
  --exclude='.venv' \
  --exclude='dist' \
  --exclude='__pycache__' \
  -czf "${ARCHIVE}" \
  -C "${REPO_ROOT}" \
  .

echo "Copying archive and iii binaries to gateway"
scp_gateway "${ARCHIVE}" "${local_iii}" "${local_iii_worker}" "${SSH_USER}@${GATEWAY_HOST}:/tmp/"

echo "Installing gateway nginx config"
ssh_gateway "set -euo pipefail
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
cat >/tmp/default.nginx <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location /v1/chat/completions {
        proxy_pass http://${ENGINE_HOST}:3111;
        proxy_http_version 1.1;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    location /healthz {
        return 200 \"ok\\n\";
    }
}
NGINX
sudo cp /tmp/default.nginx /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx"

for host in "${ENGINE_HOST}" "${CALLER_HOST}" "${INFERENCE_HOST}"; do
  echo "Copying archive and iii binaries to ${host}"
  scp_private "${ARCHIVE}" "${host}" "${REMOTE_ARCHIVE}"
  scp_private "${local_iii}" "${host}" "/tmp/iii"
  scp_private "${local_iii_worker}" "${host}" "/tmp/iii-worker"

  echo "Installing base files on ${host}"
  ssh_private "${host}" "set -euo pipefail
sudo rm -rf '${DEPLOY_ROOT}'
sudo mkdir -p '${DEPLOY_ROOT}' /usr/local/bin /etc/alchemyst
sudo tar -xzf '${REMOTE_ARCHIVE}' -C '${DEPLOY_ROOT}'
sudo install -m 0755 /tmp/iii /usr/local/bin/iii
sudo install -m 0755 /tmp/iii-worker /usr/local/bin/iii-worker
sudo chown -R ${SSH_USER}:${SSH_USER} '${DEPLOY_ROOT}'
rm -f '${REMOTE_ARCHIVE}' /tmp/iii /tmp/iii-worker
iii --version"
done

echo "Starting engine service"
ssh_private "${ENGINE_HOST}" "set -euo pipefail
mkdir -p '${DEPLOY_ROOT}/quickstart/data'
sudo cp '${DEPLOY_ROOT}/deploy/systemd/iii-engine.service' /etc/systemd/system/iii-engine.service
sudo systemctl daemon-reload
sudo systemctl enable --now iii-engine.service
sudo systemctl restart iii-engine.service"

echo "Installing caller worker dependencies and service"
ssh_private "${CALLER_HOST}" "set -euo pipefail
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
cd '${DEPLOY_ROOT}/quickstart/workers/caller-worker'
npm install
npm run build
{
  echo 'III_URL=ws://${ENGINE_HOST}:49134'
  echo 'MODEL_ID=ggml-org/gemma-3-270m-GGUF'
} | sudo tee /etc/alchemyst/caller-worker.env >/dev/null
sudo cp '${DEPLOY_ROOT}/deploy/systemd/caller-worker.service' /etc/systemd/system/caller-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now caller-worker.service
sudo systemctl restart caller-worker.service"

echo "Installing inference worker dependencies and service"
ssh_private "${INFERENCE_HOST}" "set -euo pipefail
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3.12 python3.12-venv curl
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
cd '${DEPLOY_ROOT}/quickstart/workers/inference-worker'
~/.local/bin/uv venv --python 3.12 --clear
. .venv/bin/activate
~/.local/bin/uv pip install -r requirements.txt
python -m compileall inference_worker.py
{
  echo 'III_URL=ws://${ENGINE_HOST}:49134'
  echo 'MAX_NEW_TOKENS=${MAX_NEW_TOKENS}'
  echo 'MODEL_ID=ggml-org/gemma-3-270m-GGUF'
  echo 'GGUF_FILE=gemma-3-270m-Q8_0.gguf'
} | sudo tee /etc/alchemyst/inference-worker.env >/dev/null
sudo cp '${PROJECT_DIR}/devops/deploy/systemd/inference-worker.service' /etc/systemd/system/inference-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now inference-worker.service
sudo systemctl restart inference-worker.service"

echo "Service status"
ssh_private "${ENGINE_HOST}" "systemctl is-active iii-engine.service"
ssh_private "${CALLER_HOST}" "systemctl is-active caller-worker.service"
ssh_private "${INFERENCE_HOST}" "systemctl is-active inference-worker.service"

echo "Waiting for registered functions on engine"
ssh_private "${ENGINE_HOST}" "set -euo pipefail
deadline=\$((SECONDS + 600))
while (( SECONDS < deadline )); do
  functions=\"\$(iii trigger engine::functions::list)\"
  if grep -q 'http::run_inference_over_http' <<<\"\${functions}\" &&
     grep -q 'inference::get_response' <<<\"\${functions}\" &&
     grep -q 'inference::run_inference' <<<\"\${functions}\"; then
    printf '%s\n' 'http::run_inference_over_http' 'inference::get_response' 'inference::run_inference'
    exit 0
  fi
  sleep 10
done
echo 'Timed out waiting for iii functions to register' >&2
iii trigger engine::functions::list | grep -E 'http::run_inference_over_http|inference::get_response|inference::run_inference' || true
exit 1"

echo "Deploy complete"

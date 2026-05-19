# Deployment Script Notes

`scripts/deploy-workers.sh` is intended to automate the post-Terraform deployment step:

```bash
KEY_PATH=/path/to/key.pem \
GATEWAY_HOST=<gateway-public-ip> \
ENGINE_HOST=<engine-private-ip> \
CALLER_HOST=<caller-private-ip> \
INFERENCE_HOST=<inference-private-ip> \
./scripts/deploy-workers.sh
```

The script was tested against the live AWS stack after the Terraform resources were created. It handles:

- nginx config on the gateway VM.
- iii and iii-worker binary installation.
- repo copy to private VMs through the gateway.
- Node dependencies and caller worker systemd service.
- Python 3.12 + uv dependencies and inference worker systemd service.
- engine/caller/inference service restarts.
- waiting for all iii functions to register.

## Important Constraints

The script assumes:

- Operator machine can SSH to the gateway.
- Gateway can SSH to private VMs through the VPC.
- Local machine has Linux x86_64 `iii` and `iii-worker` binaries installed.
- Remote VMs are Ubuntu 24.04 x86_64.
- Deployment path is `/opt/alchemyst-ai/may-2026/devops`, matching the systemd units.

If an evaluator runs from macOS/Windows/ARM, local `iii` binaries may not be compatible with the Linux x86_64 VMs. In that case, use the manual fallback below or install iii directly on each VM with the official installer.

## If The Script Fails

The most likely causes are:

- SSH key path or security group mismatch.
- Fresh model download taking several minutes.
- GitHub/HuggingFace rate limits.
- Local `iii` binary architecture differs from the EC2 architecture.
- Ubuntu package mirror temporarily slow.

Use these checks:

```bash
curl -fsS http://<gateway-public-ip>/healthz
ssh -i "$KEY_PATH" ubuntu@<gateway-public-ip>
```

Check private SSH through gateway:

```bash
ssh -i "$KEY_PATH" \
  -o ProxyCommand="ssh -i $KEY_PATH -W %h:%p ubuntu@<gateway-public-ip>" \
  ubuntu@<engine-private-ip>
```

Check services:

```bash
sudo systemctl status iii-engine.service --no-pager
sudo systemctl status caller-worker.service --no-pager
sudo systemctl status inference-worker.service --no-pager
```

Check registered functions on the engine VM:

```bash
iii trigger engine::functions::list | grep -E 'http::run_inference_over_http|inference::get_response|inference::run_inference'
```

## Manual Fallback

If `deploy-workers.sh` does not work in a fresh environment, use the same steps manually:

1. Copy the repo to all three private VMs under:

   ```text
   /opt/alchemyst-ai/may-2026/devops
   ```

2. Install `iii` and `iii-worker` on engine, caller, and inference VMs:

   ```bash
   curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
   sudo install -m 0755 ~/.local/bin/iii /usr/local/bin/iii
   sudo install -m 0755 ~/.local/bin/iii-worker /usr/local/bin/iii-worker
   ```

3. On the engine VM:

   ```bash
   cd /opt/alchemyst-ai/may-2026/devops/quickstart
   sudo cp /opt/alchemyst-ai/may-2026/devops/deploy/systemd/iii-engine.service /etc/systemd/system/iii-engine.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now iii-engine.service
   ```

4. On the caller VM:

   ```bash
   sudo apt-get update
   sudo apt-get install -y nodejs npm
   cd /opt/alchemyst-ai/may-2026/devops/quickstart/workers/caller-worker
   npm install
   npm run build
   printf 'III_URL=ws://<engine-private-ip>:49134\nMODEL_ID=ggml-org/gemma-3-270m-GGUF\n' | sudo tee /etc/alchemyst/caller-worker.env
   sudo cp /opt/alchemyst-ai/may-2026/devops/deploy/systemd/caller-worker.service /etc/systemd/system/caller-worker.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now caller-worker.service
   ```

5. On the inference VM:

   ```bash
   sudo apt-get update
   sudo apt-get install -y python3.12 python3.12-venv curl
   curl -LsSf https://astral.sh/uv/install.sh | sh
   cd /opt/alchemyst-ai/may-2026/devops/quickstart/workers/inference-worker
   ~/.local/bin/uv venv --python 3.12 --clear
   . .venv/bin/activate
   ~/.local/bin/uv pip install -r requirements.txt
   printf 'III_URL=ws://<engine-private-ip>:49134\nMAX_NEW_TOKENS=64\nMODEL_ID=ggml-org/gemma-3-270m-GGUF\nGGUF_FILE=gemma-3-270m-Q8_0.gguf\n' | sudo tee /etc/alchemyst/inference-worker.env
   sudo cp /opt/alchemyst-ai/may-2026/devops/deploy/systemd/inference-worker.service /etc/systemd/system/inference-worker.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now inference-worker.service
   ```

6. Verify:

   ```bash
   ./scripts/smoke-test.sh http://<gateway-public-ip>
   ```

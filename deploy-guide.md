# Deployment Guide

This guide starts after Terraform creates the AWS resources and `terraform output` has printed the gateway public IP plus private VM IPs.

Use placeholders below:

```text
<gateway-public-ip>   Gateway public IP or DNS
<engine-private-ip>   Engine private IP
<caller-private-ip>   Caller worker private IP
<inference-private-ip> Inference worker private IP
<key.pem>             EC2 SSH private key path
```

## Primary Deployment Method

Use this method for evaluator redeploys because each step is visible and debuggable.

### 1. Configure Gateway Nginx

SSH to the gateway:

```bash
ssh -i <key.pem> ubuntu@<gateway-public-ip>
```

Install nginx and write the reverse proxy config:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
cat >/tmp/default.nginx <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    location /v1/chat/completions {
        proxy_pass http://<engine-private-ip>:3111;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    location /healthz {
        return 200 "ok\n";
    }
}
NGINX
sudo cp /tmp/default.nginx /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx
```

### 2. Copy Repo To Private VMs

From local repo root:

```bash
tar \
  --exclude='.git' \
  --exclude='.terraform' \
  --exclude='terraform.tfvars' \
  --exclude='*.tfstate' \
  --exclude='node_modules' \
  --exclude='.venv' \
  --exclude='dist' \
  --exclude='__pycache__' \
  -czf /tmp/aws-distributed-inference.tar.gz .
```

Copy through gateway to each private VM:

```bash
for HOST in <engine-private-ip> <caller-private-ip> <inference-private-ip>; do
  scp -i <key.pem> \
    -o ProxyCommand="ssh -i <key.pem> -W %h:%p ubuntu@<gateway-public-ip>" \
    /tmp/aws-distributed-inference.tar.gz ubuntu@$HOST:/tmp/aws-distributed-inference.tar.gz

  ssh -i <key.pem> \
    -o ProxyCommand="ssh -i <key.pem> -W %h:%p ubuntu@<gateway-public-ip>" \
    ubuntu@$HOST \
    'sudo rm -rf /opt/aws-distributed-inference &&
     sudo mkdir -p /opt/aws-distributed-inference /etc/alchemyst &&
     sudo tar -xzf /tmp/aws-distributed-inference.tar.gz -C /opt/aws-distributed-inference &&
     sudo chown -R ubuntu:ubuntu /opt/aws-distributed-inference'
done
```

### 3. Install iii On Private VMs

Run on engine, caller, and inference VMs:

```bash
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
sudo install -m 0755 ~/.local/bin/iii /usr/local/bin/iii
sudo install -m 0755 ~/.local/bin/iii-worker /usr/local/bin/iii-worker
iii --version
```

### 4. Start Engine VM

Run on `<engine-private-ip>`:

```bash
cd /opt/aws-distributed-inference/quickstart
sudo cp /opt/aws-distributed-inference/deploy/systemd/iii-engine.service /etc/systemd/system/iii-engine.service
sudo systemctl daemon-reload
sudo systemctl enable --now iii-engine.service
sudo systemctl restart iii-engine.service
sudo systemctl status iii-engine.service --no-pager
```

### 5. Start Caller VM

Run on `<caller-private-ip>`:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
cd /opt/aws-distributed-inference/quickstart/workers/caller-worker
npm install
npm run build
printf 'III_URL=ws://<engine-private-ip>:49134\nMODEL_ID=ggml-org/gemma-3-270m-GGUF\n' | sudo tee /etc/alchemyst/caller-worker.env
sudo cp /opt/aws-distributed-inference/deploy/systemd/caller-worker.service /etc/systemd/system/caller-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now caller-worker.service
sudo systemctl restart caller-worker.service
sudo systemctl status caller-worker.service --no-pager
```

### 6. Start Inference VM

Run on `<inference-private-ip>`:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3.12 python3.12-venv curl
curl -LsSf https://astral.sh/uv/install.sh | sh
cd /opt/aws-distributed-inference/quickstart/workers/inference-worker
~/.local/bin/uv venv --python 3.12 --clear
. .venv/bin/activate
~/.local/bin/uv pip install -r requirements.txt
python -m compileall inference_worker.py
printf 'III_URL=ws://<engine-private-ip>:49134\nMAX_NEW_TOKENS=64\nMODEL_ID=ggml-org/gemma-3-270m-GGUF\nGGUF_FILE=gemma-3-270m-Q8_0.gguf\n' | sudo tee /etc/alchemyst/inference-worker.env
sudo cp /opt/aws-distributed-inference/deploy/systemd/inference-worker.service /etc/systemd/system/inference-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now inference-worker.service
sudo systemctl restart inference-worker.service
sudo systemctl status inference-worker.service --no-pager
```

First inference start can take several minutes while model files download/load.

### 7. Verify

On the engine VM:

```bash
iii trigger engine::functions::list | grep -E 'http::run_inference_over_http|inference::get_response|inference::run_inference'
```

From local repo root:

```bash
curl -fsS http://<gateway-public-ip>/healthz
./scripts/smoke-test.sh http://<gateway-public-ip>
```

## Secondary Automated Method

`scripts/deploy-workers.sh` automates gateway config, repo copy, iii binary install, dependency install, systemd setup, restarts, and function-registration wait.

```bash
KEY_PATH=/path/to/key.pem \
GATEWAY_HOST=<gateway-public-ip> \
ENGINE_HOST=<engine-private-ip> \
CALLER_HOST=<caller-private-ip> \
INFERENCE_HOST=<inference-private-ip> \
./scripts/deploy-workers.sh
```

### Automated Method Constraints

The script assumes:

- Operator machine can SSH to the gateway.
- Gateway can SSH to private VMs through the VPC.
- Local machine has Linux x86_64 `iii` and `iii-worker` binaries installed.
- Remote VMs are Ubuntu 24.04 x86_64.
- Deployment path is `/opt/aws-distributed-inference`, matching the systemd units.

If an evaluator runs from macOS/Windows/ARM, local `iii` binaries may not be compatible with the Linux x86_64 VMs. Use the primary method above because it installs iii directly on each VM.

## If The Script Fails

If the automated path fails, keep the Terraform stack and use the primary method above. Most failures are deployment-copy, package-install, or service-start issues, not infrastructure failures. Re-running Terraform is usually unnecessary unless the IPs, routes, or security groups are wrong.

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

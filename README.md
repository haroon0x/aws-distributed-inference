# AWS Distributed Inference

Private AWS worker mesh for the `quickstart` distributed inference prototype. A public gateway exposes a JSON API while TypeScript and Python workers communicate over iii RPC inside a private subnet.

## Architecture

```text
Internet
  |
  v
[api-gateway-vm: public subnet]
  nginx :80
  proxies /v1/chat/completions
  |
  v
[engine-vm: private subnet]
  iii engine :49134
  iii-http :3111
  |
  | iii RPC over private VPC
  v
[caller-worker-vm: private subnet]
  caller-worker TypeScript
  |
  | iii RPC over private VPC
  v
[inference-worker-vm: private subnet]
  Python Gemma GGUF inference worker
```

Only `api-gateway-vm` has a public endpoint. Worker and engine security groups only allow VPC-internal traffic.

## JSON API

Request:

```bash
curl -sS -X POST http://ec2-13-206-255-84.ap-south-1.compute.amazonaws.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Sample response shape:

```json
{
  "id": "chatcmpl-1779190000000",
  "object": "chat.completion",
  "model": "ggml-org/gemma-3-270m-GGUF",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello, I am ready to help."
      },
      "finish_reason": "stop"
    }
  ]
}
```

## Local Setup

Install iii:

```bash
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
iii --version
```

If GitHub rate limit blocks the installer:

```bash
curl -H "Authorization: Bearer $GITHUB_TOKEN" -fsSL https://install.iii.dev/iii/main/install.sh | sh
```

Install TypeScript worker dependencies:

```bash
cd quickstart/workers/caller-worker
npm install
npm run build
```

Install Python worker dependencies:

```bash
cd quickstart/workers/inference-worker
uv venv --python 3.12
. .venv/bin/activate
uv pip install -r requirements.txt
python -m compileall inference_worker.py
```

Run locally:

```bash
cd quickstart
iii --config config.yaml
```

In another terminal:

```bash
cd quickstart/workers/inference-worker
III_URL=ws://localhost:49134 MAX_NEW_TOKENS=64 python inference_worker.py
```

In another terminal:

```bash
cd quickstart/workers/caller-worker
III_URL=ws://localhost:49134 npm run dev
```

Then call:

```bash
curl -sS -X POST http://127.0.0.1:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Local verification completed with iii `0.12.0`, TypeScript build, Python 3.12 via `uv`, and an end-to-end curl response from the model path.

## AWS Verification

Deployment verified in `ap-south-1`:

```text
gateway public DNS: ec2-13-206-255-84.ap-south-1.compute.amazonaws.com
gateway public IP:  13.206.255.84
engine private IP:  10.40.10.121
caller private IP:  10.40.10.173
inference private IP: 10.40.10.29
```

The worker VMs have no public IPs. Public traffic enters only through the gateway VM on port 80.

Verified public curl:

```bash
curl -sS -X POST http://13.206.255.84/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Observed response shape:

```json
{
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "Say hlelo in oone short sentence.\nThe word \"hallel\" is used in the Bible to mean \"peace\" or \"joy.\" It is a\nHebrew word that means \"to be glad.\"\nThe word \"hallel\" is also used in the Old Testament to mean",
        "role": "assistant"
      }
    }
  ],
  "id": "chatcmpl-1779213923303",
  "model": "ggml-org/gemma-3-270m-GGUF",
  "object": "chat.completion"
}
```

Inference uses `c7i-flex.large` because this AWS account rejects `t3.medium` as not free-tier-eligible, while `t3.micro`/`t3.small` have too little memory headroom for the model load. Observed inference worker memory after load: about 1.8 GiB current, 2.7 GiB peak.

Quick verification commands:

```bash
make health
make smoke
make status
```

Operational docs:

```text
docs/runbook.md
docs/security.md
docs/implementation-plan.md
```

## AWS Redeploy From Scratch

1. Configure AWS credentials:

   ```bash
   aws sts get-caller-identity
   ```

2. Install Terraform.

3. Create `infra/terraform/terraform.tfvars`:

   ```hcl
   aws_region       = "us-east-1"
   project_name     = "alchemyst-devops"
   key_name         = "your-existing-ec2-keypair"
   allowed_ssh_cidr = "YOUR_PUBLIC_IP/32"
   ```

4. Provision:

   ```bash
   cd infra/terraform
   terraform init
   terraform validate
   terraform apply
   ```

5. On `engine-vm`, run iii with `quickstart/config.aws.yaml`.

6. On `caller-worker-vm` and `inference-worker-vm`, set:

   ```bash
   III_URL=ws://<engine-private-ip>:49134
   ```

7. Deploy app code to VMs and enable systemd units from `deploy/systemd`.

8. Use Terraform output `gateway_public_dns` in the curl command above.

## Production Hardening

Before production, add TLS with ACM or certbot, authentication on the API, request size limits, rate limiting, structured logs to CloudWatch, alarms, least-privilege IAM roles, SSM Session Manager instead of SSH, pinned AMIs, dependency lock verification, private artifact/model cache, and blue/green rollout. Replace NAT gateway package downloads with baked AMIs or container images to make deploys faster and more repeatable.

## If Model Were 100x Larger

Use GPU instances or managed inference instead of CPU EC2. Store model weights in S3/EFS or a model registry, preload on boot, and keep warm replicas behind a queue. Split API and inference scaling: many stateless caller workers, fewer expensive inference workers. Add batching, streaming responses, autoscaling on queue depth/GPU utilization, and possibly tensor/model parallelism if one model does not fit on one device.

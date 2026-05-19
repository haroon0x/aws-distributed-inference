# AWS Distributed Inference

Private AWS worker mesh for the `quickstart` distributed inference prototype. A public gateway exposes a JSON API, while TypeScript and Python workers communicate over iii RPC inside a private subnet.

## What This Includes

- Terraform for VPC, public/private subnets, NAT gateway, EC2 instances, routes, and security groups.
- A public API gateway VM running nginx.
- Private engine, caller-worker, and inference-worker VMs.
- systemd units for iii engine and both workers.
- Smoke tests, runbook, security notes, and redeploy instructions.

## Documentation Map

Start here, then use the supporting docs as needed:

| Document | Purpose |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Rendered Mermaid architecture diagram, request flow, and network boundaries. |
| [docs/runbook.md](docs/runbook.md) | Operational commands: smoke tests, SSH through gateway, service logs, restarts, common issues. |
| [docs/security.md](docs/security.md) | Public/private exposure, security group rules, NAT behavior, secrets policy, hardening notes. |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Detailed implementation notes, verified local/AWS smoke results, and rationale. |
| [deploy-guide.md](deploy-guide.md) | Full primary deployment steps, secondary automated deploy path, assumptions, failure modes, and IP-change behavior. |

## Live Deployment

The current stack is running in `ap-south-1`.

```text
API base URL:       http://13.206.255.84
API endpoint:       http://13.206.255.84/v1/chat/completions
Gateway DNS:        ec2-13-206-255-84.ap-south-1.compute.amazonaws.com
Gateway private IP: 10.40.1.194
Engine private IP:  10.40.10.121
Caller private IP:  10.40.10.173
Inference private:  10.40.10.29
```

Only the gateway has a public IP. The engine, caller worker, and inference worker are private-subnet instances with no public IPs.

## Architecture

Rendered diagram: [docs/architecture.md](docs/architecture.md)

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

## JSON API

Live request:

```bash
curl -sS -X POST http://13.206.255.84/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Sample response shape:

```json
{
  "id": "chatcmpl-1779213923303",
  "object": "chat.completion",
  "model": "ggml-org/gemma-3-270m-GGUF",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "..."
      },
      "finish_reason": "stop"
    }
  ]
}
```

## Quick Verification

```bash
make health
make smoke
make status
```

Equivalent direct smoke test:

```bash
./scripts/smoke-test.sh http://13.206.255.84
```

Verified during deployment:

```text
make health -> ok
make smoke  -> Smoke test passed
make status -> gateway public, engine/caller/inference private-only and running
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

Run local engine:

```bash
cd quickstart
iii --config config.yaml
```

Run local inference worker:

```bash
cd quickstart/workers/inference-worker
III_URL=ws://localhost:49134 MAX_NEW_TOKENS=64 python inference_worker.py
```

Run local caller worker:

```bash
cd quickstart/workers/caller-worker
III_URL=ws://localhost:49134 npm run dev
```

Local curl:

```bash
curl -sS -X POST http://127.0.0.1:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Local verification completed with iii `0.12.0`, TypeScript build, Python 3.12 via `uv`, and an end-to-end curl response from the model path.

## Redeploy From Scratch

Use Terraform for infrastructure, then use [deploy-guide.md](deploy-guide.md) for the deployment steps. The guide contains the full manual deployment flow and a secondary automated script option.

1. Configure AWS credentials:

   ```bash
   aws sts get-caller-identity
   ```

2. Install Terraform.

3. Create `infra/terraform/terraform.tfvars` from the example:

   ```bash
   cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars
   ```

   Fill in values for your AWS account:

   ```hcl
   aws_region       = "ap-south-1"
   project_name     = "alchemyst-devops"
   key_name         = "your-existing-ec2-keypair"
   allowed_ssh_cidr = "YOUR_PUBLIC_IP/32"
   ```

4. Provision infrastructure:

   ```bash
   cd infra/terraform
   terraform init
   terraform validate
   terraform apply
   terraform output
   ```

5. Deploy the application:

   ```bash
   cd ../..
   ```

   Primary method: follow [deploy-guide.md](deploy-guide.md). It documents gateway nginx setup, repo copy, iii installation, service env files, systemd units, restarts, and verification.

   Secondary method: run `scripts/deploy-workers.sh`. It automates the same post-Terraform work, but it depends on local Linux x86_64 `iii` binaries and SSH copy behavior.

6. Verify the deployment:

   ```bash
   ./scripts/smoke-test.sh http://<gateway-public-ip>
   ```

## IP Address Stability

The current live endpoint stays valid while the current gateway EC2 instance is running:

```text
http://13.206.255.84/v1/chat/completions
```

If `terraform destroy` and a fresh `terraform apply` are run, AWS may assign new public and private IPs. Always run:

```bash
cd infra/terraform
terraform output
```

Use those output values for `GATEWAY_HOST`, `ENGINE_HOST`, `CALLER_HOST`, `INFERENCE_HOST`, and the public curl command. For a longer-lived deployment, attach an Elastic IP or Route 53 DNS record to the gateway.

## Instance Choices

```text
gateway:   t3.micro
engine:    t3.micro
caller:    t3.micro
inference: c7i-flex.large
```

The inference worker uses `c7i-flex.large` because this AWS account rejected `t3.medium` as not free-tier-eligible, while `t3.micro`/`t3.small` have too little memory headroom for model loading. Observed inference worker memory after load: about 1.8 GiB current, 2.7 GiB peak.

## Production Hardening

Before production, add TLS with ACM or certbot, authentication on the API, request size limits, rate limiting, structured logs to CloudWatch, alarms, least-privilege IAM roles, SSM Session Manager instead of SSH, pinned AMIs, dependency lock verification, private artifact/model cache, and blue/green rollout. Replace NAT gateway package downloads with baked AMIs or container images to make deploys faster and more repeatable.

## If Model Were 100x Larger

Use GPU instances or managed inference instead of CPU EC2. Store model weights in S3/EFS or a model registry, preload on boot, and keep warm replicas behind a queue. Split API and inference scaling: many stateless caller workers, fewer expensive inference workers. Add batching, streaming responses, autoscaling on queue depth/GPU utilization, and possibly tensor/model parallelism if one model does not fit on one device.

## Teardown

Destroy the stack when evaluation is complete to stop AWS costs:

```bash
cd infra/terraform
terraform destroy
```

# DevOps AWS Implementation Plan

Goal: deploy `quickstart` on AWS with private worker VMs, RPC over private VPC traffic, and one public JSON API endpoint.

## Current Local Findings

- Assignment requires AWS or GCP; we are using AWS.
- `quickstart` contains two app workers:
  - `inference-worker`: Python, registers `inference::run_inference`, loads GGUF Gemma model.
  - `caller-worker`: TypeScript, registers `inference::get_response` and HTTP trigger `POST /v1/chat/completions`.
- iii engine modules in `config.yaml` provide HTTP/state/queue/observability.
- iii docs say engine and SDKs should stay on same minor version. Local `iii.lock` uses `0.12.0`, so SDK pins are set to `0.12.0`.

## Architecture

```text
Internet
  |
  | HTTP POST /v1/chat/completions
  v
Public subnet
  [api-gateway-vm]
    - nginx listens on :80
    - proxies to engine private IP:3111

Private subnet
  [engine-vm]
    - iii engine listens on ws://ENGINE_PRIVATE_IP:49134
    - iii-http listens on :3111 for gateway traffic

  [caller-worker-vm]
    - TypeScript caller-worker
    - registers HTTP trigger and inference::get_response
    - connects to engine over III_URL=ws://ENGINE_PRIVATE_IP:49134

  [inference-worker-vm]
    - Python inference-worker
    - registers inference::run_inference
    - connects to engine over III_URL=ws://ENGINE_PRIVATE_IP:49134
```

RPC flow:

```text
curl -> nginx gateway -> iii-http trigger -> caller-worker -> iii engine RPC -> inference-worker -> iii engine -> caller-worker -> HTTP JSON
```

## Work Done

- Fixed Python worker name from `math-worker` to `inference-worker`.
- Changed inference response from raw string to `{ "text": "..." }`.
- Added `MODEL_ID`, `GGUF_FILE`, and `MAX_NEW_TOKENS` env config.
- Reduced default `MAX_NEW_TOKENS` to `256` for CPU smoke tests.
- Changed TypeScript worker to return OpenAI-like JSON response.
- Added request validation for missing `messages`.
- Aligned Python and npm `iii-sdk` pins to `0.12.0`.
- Installed and verified iii CLI `0.12.0`.
- Verified local end-to-end HTTP call through iii engine, caller worker, and inference worker.

## Next Tasks

1. Run local dependency checks.
   ```bash
   cd may-2026/devops/quickstart/workers/caller-worker
   npm install
   npm run build

   cd ../inference-worker
   uv venv --python 3.12
   . .venv/bin/activate
   uv pip install -r requirements.txt
   python -m compileall inference_worker.py
   ```

2. Local smoke test.
   Terminal 1:
   ```bash
   cd may-2026/devops/quickstart
   iii --config config.yaml
   ```
   Terminal 2:
   ```bash
   cd may-2026/devops/quickstart/workers/inference-worker
   III_URL=ws://localhost:49134 MAX_NEW_TOKENS=64 python inference_worker.py
   ```
   Terminal 3:
   ```bash
   cd may-2026/devops/quickstart/workers/caller-worker
   III_URL=ws://localhost:49134 npm run dev
   ```
   Terminal 4:
   ```bash
   curl -sS -X POST http://127.0.0.1:3111/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
   ```

3. AWS deploy.
   - Install Terraform locally.
   - Fill `infra/terraform/terraform.tfvars`.
   - Run `terraform init && terraform apply`.
   - Copy repo to VMs or use a public/private Git URL in cloud-init.
   - Enable systemd services from `deploy/systemd`.
   - Hit gateway public DNS with curl.

## Verified Local Smoke Test

Command:

```bash
curl -sS -X POST http://127.0.0.1:3111/v1/chat/completions \
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
        "content": "Say hlelo in oone short sentence.\nThe word \"hallel\" is used in the Bible to mean \"peace\" or \"",
        "role": "assistant"
      }
    }
  ],
  "id": "chatcmpl-1779198491886",
  "model": "ggml-org/gemma-3-270m-GGUF",
  "object": "chat.completion"
}
```

The content quality is weak because this is a tiny CPU-friendly model and the smoke test used `MAX_NEW_TOKENS=32`; the important requirement verified here is end-to-end RPC/HTTP flow.

## Verified AWS Smoke Test

Terraform created:

```text
gateway public DNS: ec2-13-206-255-84.ap-south-1.compute.amazonaws.com
gateway public IP:  13.206.255.84
engine private IP:  10.40.10.121
caller private IP:  10.40.10.173
inference private IP: 10.40.10.29
```

Services:

```text
engine-vm: iii-engine.service active
caller-worker-vm: caller-worker.service active
inference-worker-vm: inference-worker.service active
```

Registered functions:

```text
http::run_inference_over_http
inference::get_response
inference::run_inference
```

Public curl:

```bash
curl -sS -X POST http://13.206.255.84/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in one short sentence."}]}'
```

Observed response:

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

## Risks

- Inference VM likely needs more RAM than `t3.micro`. `t3.medium` was attempted first but rejected by this AWS account policy because it is not free-tier-eligible. Current AWS test uses `c7i-flex.large`, the smallest x86_64 free-tier-eligible type reported by this account with 4 GiB RAM.
- Private workers need outbound internet for package/model download. Terraform includes NAT path; can be replaced by prebuilt AMI to reduce cost.
- Current `config.yaml` has local absolute worker paths from original assignment. For AWS systemd deployment, workers are started directly on their own VMs and use `III_URL`; engine config should not depend on local worker paths.
- Use `quickstart/config.aws.yaml` on `engine-vm`; it binds `iii-http` to `0.0.0.0:3111` and excludes local app worker paths.

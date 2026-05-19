# Operations Runbook

This runbook assumes the AWS stack is deployed in `ap-south-1` and SSH access goes through the public gateway VM.

## Live Endpoints

```text
API base URL: http://13.206.255.84
Gateway DNS:  ec2-13-206-255-84.ap-south-1.compute.amazonaws.com
```

## Smoke Test

```bash
make smoke
```

Or directly:

```bash
./scripts/smoke-test.sh http://13.206.255.84
```

## Instance Status

```bash
make status
```

Expected:

```text
alchemyst-devops-gateway    public IP, running
alchemyst-devops-engine     private IP only, running
alchemyst-devops-caller     private IP only, running
alchemyst-devops-inference  private IP only, running
```

## SSH Access

Set the local key path:

```bash
KEY=/path/to/key.pem
GATEWAY=13.206.255.84
```

Gateway:

```bash
ssh -i "$KEY" ubuntu@"$GATEWAY"
```

Private VMs through gateway:

```bash
ssh -i "$KEY" \
  -o ProxyCommand="ssh -i $KEY -W %h:%p ubuntu@$GATEWAY" \
  ubuntu@10.40.10.121
```

Replace the private IP with:

```text
engine:    10.40.10.121
caller:    10.40.10.173
inference: 10.40.10.29
```

## Services

For redeploys, use [../deploy-guide.md](../deploy-guide.md). It documents the full primary deployment flow plus the secondary automated script.

Engine VM:

```bash
sudo systemctl status iii-engine.service --no-pager
sudo journalctl -u iii-engine.service -n 100 --no-pager
sudo systemctl restart iii-engine.service
```

Caller VM:

```bash
sudo systemctl status caller-worker.service --no-pager
sudo journalctl -u caller-worker.service -n 100 --no-pager
sudo systemctl restart caller-worker.service
```

Inference VM:

```bash
sudo systemctl status inference-worker.service --no-pager
sudo journalctl -u inference-worker.service -n 100 --no-pager
sudo systemctl restart inference-worker.service
```

## Check Registered Functions

Run on the engine VM:

```bash
iii trigger engine::functions::list | grep -E 'http::run_inference_over_http|inference::get_response|inference::run_inference'
```

Expected functions:

```text
http::run_inference_over_http
inference::get_response
inference::run_inference
```

## Common Issues

Model load is slow:

The inference worker downloads and converts the GGUF model on first boot. Wait several minutes and check:

```bash
sudo journalctl -u inference-worker.service -f
```

Caller worker fails with `crypto is not defined`:

The TypeScript worker includes a Node 18 webcrypto polyfill. Pull the latest repo code and restart `caller-worker.service`.

API returns 502:

Check that nginx on the gateway can reach `engine-vm:3111`, then check engine and worker registrations:

```bash
curl -fsS http://10.40.10.121:3111/healthz
sudo systemctl status iii-engine.service --no-pager
```

No inference function registered:

The Python model worker is not ready yet or failed. Check memory and logs:

```bash
free -h
sudo systemctl status inference-worker.service --no-pager
sudo journalctl -u inference-worker.service -n 100 --no-pager
```

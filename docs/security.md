# Security And Network Hygiene

## Public Exposure

Only the gateway VM has a public IP:

```text
gateway:   13.206.255.84
engine:    private IP only
caller:    private IP only
inference: private IP only
```

The public security group allows:

```text
80/tcp from 0.0.0.0/0
22/tcp from operator CIDR only
```

## Private Worker Network

The engine, caller worker, and inference worker live in the private subnet.

Private security group allows:

```text
49134/tcp from VPC CIDR for iii RPC
3111/tcp from gateway security group for iii HTTP
22/tcp from gateway security group for SSH administration
```

Workers are not reachable directly from the internet because:

```text
no public IPs
private subnet route goes through NAT for outbound only
security group ingress does not allow public worker access
```

## NAT Gateway

The NAT gateway is used only so private VMs can download OS packages, npm packages, Python wheels, and the HuggingFace model. It does not expose inbound access to private workers.

## Secrets

No AWS credentials, SSH private keys, `.env` files, Terraform state, or `terraform.tfvars` files are committed. `.gitignore` excludes these paths.

Terraform inputs are documented in:

```text
infra/terraform/terraform.tfvars.example
```

## Production Hardening

Before production:

```text
add TLS on gateway
add API authentication
replace SSH with SSM Session Manager
ship logs/metrics to CloudWatch
add rate limits and request size limits
pin AMI IDs or bake app AMIs
store Terraform state in encrypted remote backend
add CI secret scanning
use private model/artifact cache
```

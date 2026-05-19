# Architecture

```mermaid
flowchart TB
    user[Client / evaluator] -->|HTTP POST /v1/chat/completions| gw

    subgraph aws[AWS ap-south-1]
        subgraph public[Public subnet 10.40.1.0/24]
            gw[api-gateway-vm<br/>t3.micro<br/>nginx :80<br/>public IP 13.206.255.84]
            nat[NAT Gateway<br/>outbound package/model downloads]
        end

        subgraph private[Private subnet 10.40.10.0/24]
            engine[engine-vm<br/>t3.micro<br/>iii engine :49134<br/>iii-http :3111]
            caller[caller-worker-vm<br/>t3.micro<br/>TypeScript worker<br/>inference::get_response]
            inference[inference-worker-vm<br/>c7i-flex.large<br/>Python worker<br/>inference::run_inference<br/>Gemma GGUF model]
        end

        gw -->|proxy_pass :3111| engine
        caller <-->|iii RPC ws://engine:49134| engine
        inference <-->|iii RPC ws://engine:49134| engine
        private -->|outbound only| nat
    end

    engine -->|HTTP trigger dispatch| caller
    caller -->|RPC trigger| inference

    classDef publicNode fill:#e8f4ff,stroke:#2970ff,stroke-width:1px,color:#111827;
    classDef privateNode fill:#eefdf3,stroke:#1f9d55,stroke-width:1px,color:#111827;
    classDef network fill:#f8fafc,stroke:#94a3b8,stroke-width:1px,color:#111827;
    class gw,nat publicNode;
    class engine,caller,inference privateNode;
    class public,private,aws network;
```

## Request Flow

```text
Client
  -> api-gateway-vm nginx :80
  -> engine-vm iii-http :3111
  -> caller-worker-vm inference::get_response
  -> inference-worker-vm inference::run_inference
  -> caller-worker-vm formats JSON
  -> api-gateway-vm returns HTTP response
```

## Network Boundaries

```text
Public internet can reach only:
- api-gateway-vm:80
- api-gateway-vm:22 from operator CIDR

Private subnet contains:
- engine-vm, no public IP
- caller-worker-vm, no public IP
- inference-worker-vm, no public IP

Private VMs use NAT gateway only for outbound package/model downloads.
```

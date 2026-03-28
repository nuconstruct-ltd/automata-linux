# toolkit

CLI tool for deploying Confidential VMs (CVMs) to cloud providers. Single binary, single config file.

## Quickstart

```bash
# Build
cargo build -p toolkit --release

# Generate config template
toolkit init --csp gcp -o cvm.yaml

# Edit with your parameters
vim cvm.yaml

# Deploy
toolkit deploy --config cvm.yaml

# Check logs
toolkit logs --config cvm.yaml

# Fetch attestation measurements
toolkit measurements --config cvm.yaml

# Update workload
toolkit update --config cvm.yaml

# Tear down
toolkit destroy --config cvm.yaml
```

## Prerequisites

- **Rust** (for building)
- **Docker** (for disk operations)
- **GCP Application Default Credentials** (`gcloud auth application-default login`)

## Configuration

All deployment parameters live in a single `cvm.yaml`. Generate a template with `toolkit init`.

```yaml
# Cloud
csp: gcp
project_id: my-project
region: europe-west4-a
vm_type: c3-standard-8
vm_name: my-cvm

# Storage
bucket: my-cvm-disk
boot_disk_size: 50

# Networking — firewall ports for all services
ports: [80, 443, 2200, 8080, 8545, 8546, 8551, 9000, 9100, 5052, 5054, 6060, 30303]

# Operator ports — custom ports exposed via controller network
# operator_ports: [3000, 3001]

# SSH
ssh_public_key_file: ~/.ssh/id_ed25519.pub

# Private container images (local tar archives)
image_tars:
  - path/to/tool-node.tar

# Secret files copied to workload/secrets/
secret_files:
  nodekey: path/to/nodekey
  leaders: path/to/leaders

# Environment variables — grouped by service, flattened into .env
env:
  tool_node:
    NETWORK: mainnet
    RELAY_SECRET_KEY: ""
  lighthouse:
    CHECKPOINT_SYNC_URL: https://mainnet.checkpoint.sigp.io
  # logging:
  #   LOKI_HOST: ""
  #   LOKI_USER: ""
  #   LOKI_PASSWORD: ""
  # metrics:
  #   METRICS_HOST: ""
  #   METRICS_USER: ""
  #   METRICS_PASSWORD: ""
  # caddy:
  #   CADDY_RPC_DOMAIN: ""
  #   CADDY_CVM_DOMAIN: ""
  #   CADDY_CONTROLLER_DOMAIN: ""
```

The `env:` sections are grouped by service for clarity but flattened into a single `.env` file at deploy time. Changing `.env` values does **not** affect PCR 23 measurements.

## How it works

1. **Workload resolution** -- CLI has embedded docker-compose.yml and config templates. Override with `workload_dir:` in config.
2. **Disk preparation** -- Downloads base disk image from GitHub releases, expands partition to `boot_disk_size`, injects workload via Docker container (`disktools`).
3. **Cloud deployment** -- Creates GCS bucket, uploads disk, creates VM image with Secure Boot certs, configures firewall, launches Confidential VM (TDX/SEV-SNP).
4. **State management** -- Deployment state saved to `~/.toolkit/state/<vm_name>.yaml`. Used by `update`, `logs`, `measurements`, `destroy`.

## Commands

| Command | Description |
|---------|-------------|
| `deploy` | Full deploy pipeline: disk prep, upload, create VM |
| `update` | Push workload update to running CVM |
| `logs` | Fetch container logs |
| `measurements` | Fetch golden measurements (PCR values) |
| `destroy` | Delete VM and all cloud resources |
| `init` | Generate config template |
| `sim-agent` | Start mock CVM agent for local development |

## Architecture

```
crates/toolkit/      Rust CLI binary
disktools/           Docker image for disk operations (mount, partition, token)
controller/          Network isolation controller (Rust, separate service)
operator/            SSH operator container (Dockerfile)
scripts/             Legacy bash scripts (reference)
docs/                Documentation
```

## Disk operations

Disk mounting and partition manipulation run inside a Docker container (`ghcr.io/nuconstruct-ltd/toolkit-disktools`). This works identically on Linux and macOS -- no Multipass needed.

Build locally:
```bash
docker build -t ghcr.io/nuconstruct-ltd/toolkit-disktools:latest ./disktools/
```

## Supported platforms

| CSP | VM Types | TEE |
|-----|----------|-----|
| GCP | c3-standard-* | TDX |
| GCP | n2d-standard-* | SEV-SNP |
| AWS | (planned) | SEV-SNP |
| Azure | (planned) | TDX / SEV-SNP |

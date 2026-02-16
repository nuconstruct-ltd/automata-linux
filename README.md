<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_Black%20Text%20with%20Color%20Logo.png">
    <img src="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png" width="50%">
  </picture>
</div>

# automata-linux
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/automata-network/automata-linux)](https://github.com/automata-network/automata-linux/releases)

A command-line tool for deploying and managing Confidential Virtual Machines (CVMs) across AWS, GCP, and Azure.

## Installation

**Ubuntu/Debian:**
```bash
LATEST=$(curl -sL https://api.github.com/repos/automata-network/automata-linux/releases/latest | jq -r .tag_name)
VERSION=${LATEST#v}
wget "https://github.com/automata-network/automata-linux/releases/download/${LATEST}/atakit_${VERSION}-1_all.deb"
sudo dpkg -i atakit_${VERSION}-1_all.deb && sudo apt-get install -f
```

**macOS (Homebrew):**
```bash
brew tap automata-network/automata-linux https://github.com/automata-network/automata-linux.git
brew install atakit
```

**From source:**
```bash
git clone --recurse-submodules https://github.com/automata-network/automata-linux
cd automata-linux && sudo make install
```

See [INSTALL.md](INSTALL.md) for full details.

## Prerequisites

- Cloud provider account (GCP, AWS, or Azure) with permissions to create VMs, disks, networks, firewall rules, buckets/storage, and service roles.
- `gcloud`, `aws`, or `az` CLI installed and authenticated for your target provider.

## Full Example (GCP)

This example walks through a complete lifecycle: configure, deploy with a static IP and data disk, manage, and clean up.

### 1. Configure the workload

Copy the example config and customize:

```bash
cp workload/.env.example workload/.env
```

Edit `workload/.env` to set your values:
```bash
RELAY_SECRET_KEY=<your-relay-key>
TEE_VERIFIER_ADDRESS=<your-verifier-address>
TOOL_NODE_IMAGE=gcr.io/your-project/tool-node:your-tag
LOKI_HOST=loki.your-domain.com
```

All variables have sensible defaults. The `.env` file is optional -- without it, the docker-compose uses built-in defaults.

### 2. Deploy

```bash
atakit deploy-gcp \
  --vm_name my-cvm \
  --region europe-west4-a \
  --vm_type c3-standard-8 \
  --project_id my-gcp-project \
  --create-ip my-cvm-ip \
  --add-workload \
  --attach-disk my-cvm-data \
  --disk-size 50
```

This will:
- Reserve a static IP named `my-cvm-ip` (reuses if it already exists)
- Bundle the `workload/` directory into the disk image
- Create a 50 GB persistent data disk named `my-cvm-data`
- Deploy a confidential VM with all components

At the end, you'll see:
```
✅ Golden measurements saved to _artifacts/golden-measurements/gcp-my-cvm.json
✨ Deployment complete! Your VM Name: my-cvm
```

### 3. Get logs

```bash
atakit get-logs gcp my-cvm
```

### 4. Update workload

After changing containers or config in `workload/`:

```bash
atakit update-workload gcp my-cvm
```

### 5. Maintenance mode

Enable SSH access for debugging:

```bash
atakit maintenance gcp my-cvm enable
ssh -p 2222 root@<vm-ip>
```

Disable when done:

```bash
atakit maintenance gcp my-cvm disable
```

### 6. Cleanup

```bash
atakit cleanup gcp my-cvm
```

This deletes the VM, firewall rules, image, bucket, static IP, and all local artifacts.

## Commands

| Command | Description |
|---|---|
| `deploy-gcp` | Deploy a CVM to GCP |
| `deploy-aws` | Deploy a CVM to AWS |
| `deploy-azure` | Deploy a CVM to Azure |
| `get-logs` | Retrieve logs from a deployed CVM |
| `update-workload` | Update workload on a running CVM |
| `maintenance` | Enable or disable maintenance mode (SSH access) |
| `cleanup` | Delete all cloud resources for a CVM |
| `cleanup-local` | Remove local disk images and artifacts |
| `get-disk` | Download pre-built disk image for a provider |
| `update-disk` | Update workload on a local disk file |
| `livepatch` | Deploy a kernel livepatch to a CVM |
| `sign-image` | Sign a container image with Cosign |

Run `atakit` with no arguments to see all options and flags.

## Deploy Flags

Common flags for all deploy commands:

| Flag | Description | Default |
|---|---|---|
| `--vm_name <name>` | VM name | `cvm-test` |
| `--region <region>` | Deployment region/zone | Provider-specific |
| `--vm_type <type>` | Instance type | Provider-specific |
| `--add-workload [path]` | Bundle workload into disk | `./workload` |
| `--attach-disk <name>` | Attach or create a persistent data disk | None |
| `--disk-size <GB>` | Data disk size (for new disks) | `10` |
| `--create-ip <name>` | Auto-create a static IP (idempotent) | None |
| `--additional_ports <ports>` | Open extra firewall ports (e.g., `"80,443"`) | None |

Provider-specific flags:

| Flag | Provider | Description |
|---|---|---|
| `--project_id <id>` | GCP | GCP project ID |
| `--bucket <name>` | GCP, AWS | Storage bucket name |
| `--ip <ip>` | GCP | Pre-existing static IP to attach |
| `--eip <alloc_id>` | AWS | Pre-existing Elastic IP allocation ID |
| `--resource_group <group>` | Azure | Azure resource group |
| `--storage_account <name>` | Azure | Storage account name |
| `--gallery_name <name>` | Azure | Shared image gallery name |

## Configuration

The `workload/.env.example` file documents all configurable parameters. Copy it to `workload/.env` to override defaults:

```bash
cp workload/.env.example workload/.env
```

Key configuration areas:

- **Container images** -- tool-node, lighthouse, node-exporter, fluent-bit, controller, operator
- **Tool node** -- relay key, verifier address, DNS endpoint, history settings
- **Lighthouse** -- checkpoint sync URL, network, fee recipient
- **Logging** -- Loki host, port, TLS setting

The `docker-compose.yml` uses `${VAR:-default}` syntax. Without a `.env` file, all defaults match the standard deployment. The `.env` file is git-ignored.

## Workload Structure

```
workload/
  docker-compose.yml    # Service definitions (parameterized)
  .env.example          # Configuration template
  .env                  # Your overrides (git-ignored)
  config/               # Measured config files (mounted into containers)
    cvm_agent/
      cvm_agent_policy.json   # Security policy
  secrets/              # Unmeasured secrets (certs, keys)
```

Edit `cvm_agent_policy.json` to configure:
- `firewall.allowed_ports` -- ports open through nftables
- `workload_config.services.allow_update` -- services updatable via API
- `workload_config.services.skip_measurement` -- services excluded from measurement

See [cvm-agent-policy.md](docs/cvm-agent-policy.md) for all policy options.

## Disk Image Verification

All disk images include SLSA Build Level 2 provenance attestations:

```bash
atakit get-disk gcp
atakit download-build-provenance
atakit verify-build-provenance gcp_disk.tar.gz
```

See [ATTESTATION_VERIFICATION.md](docs/ATTESTATION_VERIFICATION.md) for details.

## More

- [Detailed walkthrough](docs/detailed-cvm-walkthrough.md)
- [Architecture](docs/architecture.md)
- [Kernel livepatching](docs/livepatching.md)
- [Troubleshooting](docs/troubleshooting.md)

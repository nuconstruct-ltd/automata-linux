<p align="center">
  <img src="assets/logo.png" width="40%" align="middle">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_Black%20Text%20with%20Color%20Logo.png">
    <img src="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png" width="40%" align="middle">
  </picture>
</p>

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/automata-network/automata-linux)](https://github.com/nuconstruct-ltd/automata-linux/releases)

A command-line tool for deploying and managing Confidential Virtual Machines (CVMs) across AWS, GCP, and Azure.

## 📑 Table of Contents <!-- omit in toc -->

- [Getting Started](#getting-started)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Deploying the CVM with your Workload](#deploying-the-cvm-with-your-workload)
- [Live Demo](#live-demo)
- [Detailed Walkthrough](#detailed-walkthrough)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Getting Started

Clone the repository and use `./toolkit` directly:

```bash
git clone --recurse-submodules https://github.com/nuconstruct-ltd/automata-linux
cd automata-linux
./toolkit --help
```

The `./toolkit` script automatically installs missing dependencies (`curl`, `jq`, `unzip`, `openssl`) on first run.

## Prerequisites

- Ensure that you have enough permissions on your account on either GCP, AWS or Azure to create virtual machines, disks, networks, firewall rules, buckets/storage accounts and service roles.

### Downloading and Verifying Disk Images <!-- omit in toc -->

The deployment scripts automatically download pre-built disk images from [GitHub Releases](https://github.com/nuconstruct-ltd/automata-linux/releases). By default, the latest release is used. To use a specific release, set `RELEASE_TAG` (e.g., `export RELEASE_TAG=v1.0.0`).

All disk images include **SLSA Build Level 2** provenance attestations. To verify:

```bash
./toolkit get-disk aws
./toolkit download-build-provenance
./toolkit verify-build-provenance aws_disk.vmdk
```

For complete verification instructions, see [docs/ATTESTATION_VERIFICATION.md](docs/ATTESTATION_VERIFICATION.md).

## Quickstart

### 1. Deploying the CVM <!-- omit in toc -->

To quickly deploy the CVM with the example workload:

```bash
# Deploy to GCP
./toolkit deploy-gcp workload-example

# Deploy to AWS
./toolkit deploy-aws workload-example

# Deploy to Azure
./toolkit deploy-azure workload-example
```

> [!Note]
> The script will automatically download the latest disk image from [GitHub Releases](https://github.com/nuconstruct-ltd/automata-linux/releases). <br/>
> If you want to use a specific release version, set the `RELEASE_TAG` environment variable (see [Prerequisites](#prerequisites)). <br/>
> If another developer has given you a custom disk, you can use it instead by:
>
> - Placing the custom disk file in the root of this folder.
> - Making sure the file is named exactly as follows, depending on which cloud provider you plan to deploy on:
>   - GCP: gcp_disk.tar.gz
>   - AWS: aws_disk.vmdk
>   - Azure: azure_disk.vhd

### 2. Get logs from the CVM <!-- omit in toc -->

At the end of the previous step, you should have the following output:

```bash
✅ Golden measurements saved to _artifacts/golden-measurements/gcp-cvm-test.json
✨ Deployment complete! Your VM Name: cvm-test
```

Using the provided VM name, you can retrieve logs from the VM like this:

```bash
# ./toolkit get-logs <cloud-provider> <vm-name> [service-names...]
# <cloud-provider> = "aws" or "gcp" or "azure"
./toolkit get-logs gcp cvm-test

# Get logs for specific services only
./toolkit get-logs gcp cvm-test prometheus node-exporter
```

### 3. Destroy the VM <!-- omit in toc -->

Finally, when you're ready to delete the VM and remove all the components that are deployed with it, you can run the following command:

```bash
# ./toolkit cleanup <cloud-provider> <vm-name>
# <cloud-provider> = "aws" or "gcp" or "azure"
./toolkit cleanup gcp cvm-test
```

## Deploying the CVM with your Workload

### Workload Directory Structure <!-- omit in toc -->

This repository includes **`workload-example/`** — a full tool-node stack with Ethereum execution and consensus clients, network isolation controller, and supporting services. Use it as a template for your own workload repositories.

Workloads can be sourced from **local directories** or **git repositories**:

```bash
# Local directory
./toolkit deploy-gcp ./my-workload

# Git repository (with optional ref and subdirectory path)
./toolkit deploy-gcp https://github.com/org/my-workload.git
./toolkit deploy-gcp https://github.com/org/repo.git?ref=v1.0&path=workload
./toolkit deploy-gcp git@github.com:org/repo.git?ref=main
```

Each workload directory contains:

```
workload/
  docker-compose.yml    # Service definitions using ${VAR} substitution
  .env                  # All config: images, credentials, domains (NOT measured)
  config/               # Measured by cvm-agent into TPM PCR
    scripts/            # Entrypoint scripts for containers
    promtail/           # Promtail config
    vmagent/            # Victoria Metrics agent config
    cvm_agent/          # CVM agent security policy
  secrets/              # NOT measured (private keys, toolkit params, etc.)
    toolkit.env         # Toolkit deployment params (CSP, REGION, etc.)
    images.json         # Image archive download manifest
    identity.env        # Auto-generated by toolkit
```

Key directories:
- **`.env`** (at workload root) — All workload configuration. Read by podman-compose for `${VAR}` substitution and injected into containers via `env_file:`. Does NOT affect CVM measurements.
- **`config/`** — Measured by the cvm-agent into TPM PCR before containers run.
- **`secrets/`** — NOT measured. Contains credentials, private keys, toolkit params.

> [!CAUTION]
> **Never commit `secrets/*` to git.** This directory contains sensitive credentials and private keys. The `.env` file at workload root is safe to commit as a template with empty values.

> [!Caution]
> Remember to build your container images for X86_64, especially if you're using an ARM64 machine!

> [!Note]
> **Loading private images:** If you have container images not published to a registry, you can either:
> - Put `.tar` files directly in the workload directory — they are auto-loaded at runtime.
> - List download URLs in `secrets/images.json` — the toolkit downloads them before deployment.
>
> Example `secrets/images.json`:
> ```json
> { "images": [{ "name": "my-image.tar", "url": "https://...", "sha256": "abc123..." }] }
> ```

### 1. Configure your workload <!-- omit in toc -->

Copy and edit the `.env` file at the workload root:

```bash
cp workload-example/.env my-workload/.env
# Edit .env with your image versions, credentials, domains, etc.

cp workload-example/secrets/toolkit.env.example my-workload/secrets/toolkit.env
# Edit toolkit.env with your CSP, region, VM name, etc.
```

### 2. Edit the Security Policy <!-- omit in toc -->

The CVM agent runs inside the CVM and is responsible for VM management, workload measurement, and related tasks. The tasks that it is allowed to perform depends on a security policy, which can be configured by the user.

By default, the CVM will use the default security policy found in your workload's `config/cvm_agent/cvm_agent_policy.json`. There are 3 settings that you **must** configure:

- `firewall.allowed_ports`: By default, all incoming traffic on all ports are blocked by nftables, except for CVM agent ports 7999 and 8000. If your workload requires incoming traffic on other ports (eg. you need a p2p port on 30000), please follow the given example and add the ports you require.
- `workload_config.services.allow_update`: This list specifies which services in your docker-compose.yml are allowed to be updated remotely via the cvm-agent API `/update-workload`. **You must list the names of your services in your docker-compose.yml if you wish to allow remote updates. Otherwise, set it to an empty list `[]` to disallow remote updates.**
- `workload_config.services.skip_measurement`: This list specifies which services the CVM agent will avoid measuring. This includes skipping its image signature checking, if it is enabled. Set it to an empty list `[]` to measure all services.

The other settings not mentioned can be left as its default values. If you wish to modify the other settings, a detailed description of each policy option can be found in [this document](docs/cvm-agent-policy.md).

### 3. Deploy the CVM <!-- omit in toc -->

In this example, we assume that you're deploying a workload that requires opening a peer‑to‑peer port on 30000 and attaching an additional 20 GB persistent data disk. If your workload does not need either of these resources, you can omit both `--additional_ports "30000"` and `--attach-disk mydisk --disk-size 20`.

The --additional_ports option configures the cloud provider's firewall to allow inbound traffic on port 30000; it does not modify the nftables firewall inside the CVM, which is managed by the security policy you defined earlier.

The `--attach-disk mydisk` flag instructs the CLI to attach (or create, if it does not already exist) a persistent data disk named `mydisk` to the CVM. When used with `--disk-size 20`, the CLI creates a 20 GB disk if mydisk is not already present. This disk is independent of the VM's boot volume, so data written to it is preserved across reboots, redeployments, and VM replacements.

> [!NOTE]
> After cvm is launched, the cvm will automatically detect the unmounted disk and setup the filesystem if the disk is not initialized and mount the disk at `/data/datadisk-1`.

```bash
# Deploy from a local workload directory
./toolkit deploy-gcp workload-example --additional_ports "30000" --attach-disk mydisk --disk-size 20

# Deploy from a git repository
./toolkit deploy-gcp https://github.com/org/my-workload.git --additional_ports "30000" --attach-disk mydisk --disk-size 20

# Deploy from a specific branch/tag and subdirectory
./toolkit deploy-gcp git@github.com:org/repo.git?ref=v1.0&path=workload --attach-disk mydisk --disk-size 20
```

At the end of the deployment, you should be able to see the name of the deployed CVM in the shell, and the location where the golden measurement of this CVM is stored:

```bash
✅ Golden measurements saved to _artifacts/golden-measurements/gcp-cvm-test.json
✨ Deployment complete! Your VM Name: cvm-test
```

> [!Note]
> Please see the [detailed walkthrough](#detailed-walkthrough) if you wish to do the following:
>
> - Customise other settings, like the vm name, or where the vm is deployed.
> - Check on best practices regarding the golden measurement, or how to use it in remote attestation.
> - If you only want to build a disk with your workload and distribute it to others.
> - If you wish to enable kernel livepatching.

### 4. Managing the CVM <!-- omit in toc -->

We've scripted some convenience commands that you can run to manage your CVM.

#### Get Logs <!-- omit in toc -->

Use this command to get all logs from all running containers in the CVM.

```bash
# ./toolkit get-logs <cloud-provider> <vm-name>
./toolkit get-logs gcp cvm-test
```

#### Update the workload <!-- omit in toc -->

In the scenario where you have updated your app version and made a new container image for it, you can update your workload directory and upload it onto the existing CVM using this command:

```bash
# ./toolkit update-workload <workload-dir|git-url> <cloud-provider> <vm-name>
./toolkit update-workload workload-example gcp cvm-test

# Or from a git repository:
./toolkit update-workload https://github.com/org/my-workload.git gcp cvm-test
```

When the script is finished, the golden measurements will be automatically regenerated for you.

> [!Note]
> If you are having troubles updating the workload, you might have forgotten to set the `workload_config.services.allow_update`. Please see the above section on [editing the security policy](#2-edit-the-security-policy).

#### Deleting the VM: <!-- omit in toc -->

Use this command to delete the VM once you no longer need it.

```bash
# ./toolkit cleanup <cloud-provider> <vm-name>
./toolkit cleanup gcp cvm-test
```

#### Cleaning Up Local Artifacts <!-- omit in toc -->

Use this command to remove all locally downloaded disk images, build provenance, and other artifacts.

```bash
./toolkit cleanup-local
```

#### (Advanced) Kernel Livepatching <!-- omit in toc -->

Use this command to deploy a livepatch onto the CVM. Please checkout our [kernel livepatch guide](./docs/livepatching.md) for more details.

```bash
# ./toolkit livepatch <cloud-provider> <vm-name> <path-to-livepatch>
./toolkit livepatch gcp cvm-test /path/to/livepatch.ko
```

## Workload Stack

The `workload-example/` directory provides a full tool-node stack with the following services:

| Service | Description |
|---------|-------------|
| `tool-node` | Ethereum execution client with TEE relay support |
| `lighthouse` | Ethereum beacon chain (consensus) client |
| `controller` | Network isolation controller — enforces mutual exclusion between WAN and Tool Node access using nftables |
| `operator` | SSH-accessible management container sharing the controller's network namespace |
| `caddy` | Reverse proxy with automatic HTTPS via Let's Encrypt |
| `promtail` | Log shipper — collects podman container logs and forwards to a remote Loki instance |
| `vmagent` | Victoria Metrics agent — scrapes and forwards Prometheus metrics |
| `node-exporter` | Prometheus node metrics exporter |

### Configuration

All workload configuration lives in the `.env` file at the workload root. Key variables:

```bash
# Container images
TOOL_NODE_IMAGE=gcr.io/constellation-458212/tool-node:latest
LIGHTHOUSE_IMAGE=docker.io/sigp/lighthouse:latest

# Network and node config
NETWORK=mainnet                            # Ethereum network (mainnet, hoodi, etc.)
RELAY_SECRET_KEY=                          # Tool node relay secret key

# Logging and metrics
LOKI_HOST=loki.example.com                 # Remote Loki host for log collection
METRICS_HOST=prometheus.example.com        # Remote Prometheus write endpoint

# Domains (optional — leave empty for self-signed certs)
CADDY_RPC_DOMAIN=rpc.example.com
CADDY_CVM_DOMAIN=cvm.example.com
CADDY_CONTROLLER_DOMAIN=controller.example.com

# SSH access
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."
```

Toolkit deployment parameters (CSP, region, VM name, etc.) go in `secrets/toolkit.env`.

### Network Isolation (Controller)

The controller enforces two mutually exclusive network modes:

- **Tool-Node mode** *(default)*: Operator can reach the Tool Node. WAN and inbound SSH are blocked.
- **Internet mode** *(maintenance)*: Operator has WAN access and SSH is allowed. Tool Node access is blocked.

Switch to Internet mode via the controller API (uses the CVM API token generated during deployment):

```bash
VM_IP=$(cat _artifacts/gcp_<vm-name>_ip)
API_TOKEN=$(cat _artifacts/gcp_<vm-name>_token)

curl -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"enable"}' \
  http://$VM_IP:8080/maintenance
```

To restore Tool-Node mode:

```bash
curl -X POST \
  -H "Authorization: Bearer $CONTROLLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action":"disable"}' \
  http://$VM_IP:8080/maintenance
```

See [controller/README.md](controller/README.md) for the full API reference, nftables rules, and security details.

### SSH Access

SSH into the operator container is only available in **Internet mode** (maintenance enabled):

```bash
ssh -p 2200 root@$VM_IP
```

The authorized key is configured via `SSH_PUBLIC_KEY_FILE` in `.env` and auto-populated by `./toolkit` at deploy time.

### Log Collection (Promtail → Loki → Grafana)

Promtail automatically discovers all running podman containers and ships their logs to a remote Loki instance with a `container` label (e.g. `tool-node`, `lighthouse`, `controller`). Set `LOKI_HOST`, `LOKI_USER`, and `LOKI_PASSWORD` in `.env`.

---

## Live Demo

Here is a short demo video showing how to deploy workload using our cvm-image on AZURE in action.

[![Watch the demo](https://img.youtube.com/vi/KaLyJbeHUzk/0.jpg)](https://www.youtube.com/watch?v=KaLyJbeHUzk)

Instructions to recreate the demo setup in your own environment are available here:

```bash
git clone https://github.com/nuconstruct-ltd/automata-linux.git

cd automata-linux

cat workload-example/docker-compose.yml

cat workload-example/config/cvm_agent/cvm_agent_policy.json

./toolkit deploy-azure workload-example --additional_ports "30000"

./toolkit get-logs azure cvm-test

./toolkit update-workload workload-example azure cvm-test

./toolkit cleanup azure cvm-test

```

## Detailed Walkthrough

A detailed walkthrough of what can be customized and any other features available can be found in [this doc](docs/detailed-cvm-walkthrough.md).

## Architecture

Details of our CVM trust chain and attestation architecture can be found in [this doc](docs/architecture.md).

## Troubleshooting

Running into trouble deploying the CVM? We have some common Q&A in [this doc](docs/troubleshooting.md).

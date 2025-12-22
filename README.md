<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_Black%20Text%20with%20Color%20Logo.png">
    <img src="https://raw.githubusercontent.com/automata-network/automata-brand-kit/main/PNG/ATA_White%20Text%20with%20Color%20Logo.png" width="50%">
  </picture>
</div>

# cvm-base-image
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)


## 📑 Table of Contents <!-- omit in toc -->
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Deploying the CVM with your workload](#deploying-the-cvm-with-your-workload)
- [Live Demo](#live-demo)
- [Detailed Walkthrough](#detailed-walkthrough)
- [Architecture](#architecture)
- [Security & Attestations](#security--attestations)
- [Troubleshooting](#troubleshooting)


## Prerequisites

- Ensure that you have enough permissions on your account on either GCP, AWS or Azure to create virtual machines, disks, networks, firewall rules, buckets/storage accounts and service roles.

```bash
git clone --recurse-submodules https://github.com/automata-network/cvm-base-image
```

### Downloading Disk Images <!-- omit in toc -->

The deployment scripts automatically download pre-built disk images from [GitHub Releases](https://github.com/automata-network/cvm-base-image/releases). By default, the latest release is used.

**For Private Repositories:**
If the repository is private, you need to set a GitHub token:

```bash
export GITHUB_TOKEN=your_github_token_here
```

**To use a specific release version:**

```bash
export RELEASE_TAG=v1.0.0  # or any specific tag like manual-20251218-211704-3f4bc00
```

**Example with both environment variables:**

```bash
# For private repos with a specific version
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
export RELEASE_TAG=v1.0.0
./cvm-cli deploy-gcp
```

> [!Note]
> If these environment variables are not set:
> - `RELEASE_TAG` defaults to `latest`
> - `GITHUB_TOKEN` is only required for private repositories

### Verifying Disk Image Attestations <!-- omit in toc -->

All disk images built through the CI pipeline include **SLSA Build Level 2** provenance attestations that cryptographically verify the build process. These attestations provide transparency into what was built, when, and by whom.

**Quick Verification:**

```bash
# Install cosign (if not already installed)
# See: https://docs.sigstore.dev/cosign/installation/

# Download attestations from release
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/attestations.zip
unzip attestations.zip

# Verify AWS VMDK attestation
cosign verify-blob-attestation \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --signature aws_disk.vmdk.att \
  aws_disk.vmdk
```

**What's Attested:**
- Source commit SHA and repository
- Binary checksums (cvm-agent, kernel, libraries)
- Secure boot key fingerprints
- dm-verity root hash for rootfs integrity
- Build tool versions and environment
- Build timestamp and builder identity

For complete verification instructions and security details, see [docs/ATTESTATION_VERIFICATION.md](docs/ATTESTATION_VERIFICATION.md).

## Quickstart

### 1. Deploying the CVM <!-- omit in toc -->
To quickly deploy the CVM with the **default** workload, you can run the following command:

```bash
# Option 1. Deploy to GCP
./cvm-cli deploy-gcp

# Option 2. Deploy to AWS
./cvm-cli deploy-aws

# Option 3. Deploy to Azure
./cvm-cli deploy-azure
```

> [!Note]
> The script will automatically download the latest disk image from [GitHub Releases](https://github.com/automata-network/cvm-base-image/releases). <br/>
> If you want to use a specific release version, set the `RELEASE_TAG` environment variable (see [Prerequisites](#prerequisites)). <br/>
> If another developer has given you a custom disk, you can use it instead by:
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
# ./cvm-cli get-logs <cloud-provider> <vm-name>
# <cloud-provider> = "aws" or "gcp" or "azure"
./cvm-cli get-logs gcp cvm-test
```

### 3. Destroy the VM <!-- omit in toc -->
Finally, when you're ready to delete the VM and remove all the components that are deployed with it, you can run the following command:
```bash
# ./cvm-cli cleanup <cloud-provider> <vm-name>
# <cloud-provider> = "aws" or "gcp" or "azure"
./cvm-cli cleanup gcp cvm-test
```

## Deploying the CVM with your Workload

### 1. Add your workload to `workload/` <!-- omit in toc -->

In this folder, you will see 3 things - a file called `docker-compose.yml`, and 2 folders called `config/` and `secrets/`.

- `docker-compose.yml` : This is a standard docker compose file that can be used to specify your workload. Most standard docker compose files will work fine and you do not need to do anything special. However, as podman-compose will be used to run this file, do take note of the following caveats:
  - Container images that are hosted on docker's official registry must be prefixed with `docker.io/`.
  - Podman does not support `depends_on.condition = service_completed_successfully`.
- `config/` : Use this folder to store any files that will be mounted and used by the container. All the files in this folder will be measured by the cvm-agent into the TPM PCR before the container runs.
- `secrets/`: Use this folder to store any files that will be mounted and used by the container, but should not be measured. Examples include cert private keys, or database credentials.

> [!Caution]
> Remember to build your container images for X86_64, especially if you're using an ARM64 machine!

> [!Note]
> If you wish to load container images that are not published to any container registry, simply put the `.tar` files for the container images into the `workload/` directory itself. This will be automatically detected and loaded at runtime.

### 2. Edit the Security Policy <!-- omit in toc -->
The CVM agent runs inside the CVM and is responsible for VM management, workload measurement, and related tasks. The tasks that it is allowed to perform depends on a security policy, which can be configured by the user.

By default, the CVM will use the default security policy found in [workload/config/cvm_agent/cvm_agent_policy.json](workload/config/cvm_agent/cvm_agent_policy.json). There are 3 settings that you **must** configure:

- `firewall.allowed_ports`: By default, all incoming traffic on all ports are blocked by nftables, except for CVM agent ports 7999 and 8000. If your workload requires incoming traffic on other ports (eg. you need a p2p port on 30000), please follow the given example and add the ports you require.
- `workload_config.services.allow_update`: This list specifies which services in your docker-compose.yml are allowed to be updated remotely via the cvm-agent API `/update-workload`. **You must list the names of your services in your docker-compose.yml if you wish to allow remote updates. Otherwise, set it to an empty list `[]` to disallow remote updates.**
- `workload_config.services.skip_measurement`: This list specifies which services the CVM agent will avoid measuring. This includes skipping its image signature checking, if it is enabled.Set it to an empty list `[]` to measure all services.

The other settings not mentioned can be left as its default values. If you wish to modify the other settings, a detailed description of each policy option can be found in [this document](docs/cvm-agent-policy.md).

### 3. Deploy the CVM <!-- omit in toc -->
In this example, we assume that you're deploying a workload that requires opening a peer‑to‑peer port on 30000 and attaching an additional 20 GB persistent data disk. If your workload does not need either of these resources, you can omit both `--additional_ports "30000"` and `--attach-disk mydisk --disk-size 20`.

The --additional_ports option configures the cloud provider’s firewall to allow inbound traffic on port 30000; it does not modify the nftables firewall inside the CVM, which is managed by the security policy you defined earlier.

The `--attach-disk mydisk` flag instructs cvm‑cli to attach (or create, if it does not already exist) a persistent data disk named `mydisk` to the CVM. When used with `--disk-size 20`, the CLI creates a 20 GB disk if mydisk is not already present. This disk is independent of the VM’s boot volume, so data written to it is preserved across reboots, redeployments, and VM replacements.

> [!NOTE]
>  After cvm is launched, the cvm will automatically detect the unmounted disk and setup the filesystem if the disk is not initialized and mount the disk at `/data/datadisk-1`.

```bash
# Option 1. Deploy to GCP
./cvm-cli deploy-gcp --add-workload --additional_ports "30000"  --attach-disk mydisk --disk-size 20

# Option 2. Deploy to AWS
./cvm-cli deploy-aws --add-workload --additional_ports "30000"  --attach-disk mydisk --disk-size 20

# Option 3. Deploy to Azure
./cvm-cli deploy-azure --add-workload --additional_ports "30000"  --attach-disk mydisk --disk-size 20
```

At the end of the deployment, you should be able to see the name of the deployed CVM in the shell, and the location where the golden measurement of this CVM is stored:

```bash
✅ Golden measurements saved to _artifacts/golden-measurements/gcp-cvm-test.json
✨ Deployment complete! Your VM Name: cvm-test
```

> [!Note]
> Please see the [detailed walkthrough](#detailed-walkthrough) if you wish to do the following:
> - Customise other settings, like the vm name, or where the vm is deployed.
> - Check on best practices regarding the golden measurement, or how to use it in remote attestation.
> - If you only want to build a disk with your workload and distribute it to others.
> - If you wish to enable kernel livepatching.

### 4. Managing the CVM <!-- omit in toc -->
We've scripted some convenience commands that you can run to manage your CVM.

#### Get Logs <!-- omit in toc -->
Use this command to get all logs from all running containers in the CVM.

```bash
# ./cvm-cli get-logs <vm-name>
./cvm-cli get-logs cvm-test
```

#### Update the workload <!-- omit in toc -->
In the scenario where you have updated the your app version and made a new container image for it, you can update your workload in the `workload/` folder, and upload this folder onto the existing CVM using this command:

```bash
# ./cvm-cli update-workload <cloud-provider> <vm-name>
# <cloud-provider> = "aws" or "gcp" or "azure"
./cvm-cli update-workload gcp cvm-test
```

When the script is finished, the golden measurements will be automatically regenerated for you.

> [!Note]
> If you are having troubles updating the workload, you might have forgotten to set the `workload_config.services.allow_update`. Please see the above section on [editing the security policy](#2-edit-the-security-policy).

#### Deleting the VM: <!-- omit in toc -->
Use this command to delete the VM once you no longer need it.

```bash
# ./cvm-cli cleanup <cloud-provider> <vm-name>
# <cloud-provider> = "aws" or "gcp" or "azure"
./cvm-cli cleanup gcp cvm-test
```

#### (Advanced) Kernel Livepatching <!-- omit in toc -->
Use this command to deploy a livepatch onto the CVM. Please checkout our [kernel livepatch guide](./docs/livepatching.md) for more details.

```bash
# ./cvm-cli livepatch <cloud-provider> <vm-name> <path-to-livepatch>
# <cloud-provider> = "aws" or "gcp" or "azure"
./cvm-cli livepatch gcp cvm-test /path/to/livepatch.ko
```

## Live Demo
Here is a short demo video showing how to deploy workload using our cvm-image on AZURE in action.

[![Watch the demo](https://img.youtube.com/vi/KaLyJbeHUzk/0.jpg)](https://www.youtube.com/watch?v=KaLyJbeHUzk)

Instructions to recreate the demo setup in your own environment are available here:
```bash
git clone https://github.com/automata-network/cvm-base-image.git

cd cvm-base-image

cat workload/docker-compose.yml

cat workload/config/cvm_agent/cvm_agent_policy.json

./cvm-cli deploy-azure --add-workload --additional_ports "30000"

./cvm-cli get-logs azure cvm-test

./cvm-cli update-workload azure cvm-test

./cvm-cli cleanup azure cvm-test

```

## Detailed Walkthrough
A detailed walkthrough of what can be customized and any other features available can be found in [this doc](docs/detailed-cvm-walkthrough.md).

## Architecture
Details of our CVM trust chain and attestation architecture can be found in [this doc](docs/architecture.md).

## Security & Attestations

All disk images released through this repository include cryptographically signed **SLSA Build Level 2** provenance attestations. These attestations provide verifiable proof of the build process and contents.

### What's Attested

Each disk image includes a signed attestation containing:

- **Build Provenance**: Exact source commit, submodule versions, and repository
- **Binary Integrity**: SHA256 checksums of all binaries (cvm-agent, kernel, libraries)
- **Security Configuration**: Secure boot key fingerprints and dm-verity root hashes
- **Build Environment**: Complete build tool versions and parameters
- **Builder Identity**: GitHub Actions runner and workflow information

### Verifying Attestations

```bash
# Install cosign
# See: https://docs.sigstore.dev/cosign/installation/

# Download attestations from any release
wget https://github.com/automata-network/cvm-base-image/releases/download/latest/attestations.zip
unzip attestations.zip

# Verify any disk image (example: AWS VMDK)
cosign verify-blob-attestation \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --signature aws_disk.vmdk.att \
  aws_disk.vmdk
```

### Why Verify Attestations?

- **Supply Chain Security**: Ensure disk images haven't been tampered with
- **Compliance**: Meet regulatory requirements for software provenance
- **Transparency**: Understand exactly what's included in each disk image
- **Reproducibility**: Verify builds match the claimed source code

For detailed verification instructions, security considerations, and troubleshooting, see [docs/ATTESTATION_VERIFICATION.md](docs/ATTESTATION_VERIFICATION.md).

## Troubleshooting
Running into trouble deploying the CVM? We have some common Q&A in [this doc](docs/troubleshooting.md).

# SLSA Build Provenance Attestation Verification Guide

This guide explains how to verify the cryptographic build provenance attestations for CVM disk images.

## Table of Contents

- [Overview](#overview)
- [Why Verify Attestations?](#why-verify-attestations)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Recommended: Verification Using cvm-cli](#recommended-verification-using-cvm-cli)
  - [Alternative: GitHub CLI (Public Repos Only)](#alternative-github-cli-public-repos-only---not-supported-yet)
- [Verification for All Cloud Providers](#verification-for-all-cloud-providers)
  - [AWS VMDK](#aws-vmdk)
  - [Azure VHD](#azure-vhd)
  - [GCP tar.gz](#gcp-targz)
- [How Verification Works for Large Disk Images](#how-verification-works-for-large-disk-images)
- [Understanding Certificate Verification](#understanding-certificate-verification)
- [What's Included in Attestations](#whats-included-in-attestations)
- [Inspecting Attestation Contents](#inspecting-attestation-contents)
- [Integration with Deployment Pipelines](#integration-with-deployment-pipelines)
- [Troubleshooting](#troubleshooting)
- [Verifying Binary Checksums](#verifying-binary-checksums)
- [Security Considerations](#security-considerations)
- [Linking Build Attestation to Runtime Attestation](#linking-build-attestation-to-runtime-attestation)
- [Additional Resources](#additional-resources)
- [Getting Help](#getting-help)

## Overview

All CVM disk images released from the [cvm-image-builder](https://github.com/automata-network/cvm-image-builder) CI/CD pipeline include **SLSA Build Level 2** provenance attestations. These attestations cryptographically prove:

- ✅ The disk images were built by the official GitHub Actions workflow
- ✅ The exact source code (commit SHA) used to build the images
- ✅ The build environment, tools, and configuration
- ✅ The images haven't been tampered with since the build

## Why Verify Attestations?

Attestation verification protects against:

| Attack Scenario | Protection |
|-----------------|------------|
| **Compromised release maintainer** | ❌ Verification fails - not built by GitHub Actions |
| **Mirror/CDN compromise** | ❌ Verification fails - digest mismatch |
| **Supply chain injection** | ✅ Attestation shows exact source commit for auditing |
| **Typosquatting/phishing** | ❌ Certificate identity shows wrong repository |
| **Post-build modification** | ❌ SHA256 digest mismatch detected |

## Quick Start

### Prerequisites

Install required tools:

```bash
# Install jq for JSON processing (required)
sudo apt-get install jq  # Debian/Ubuntu
brew install jq          # macOS

# Install openssl (usually pre-installed)
openssl version

# Optional: Install cosign for additional verification
# See: https://docs.sigstore.dev/cosign/installation/
brew install sigstore/tap/cosign  # macOS
```

### Recommended: Verification Using cvm-cli

The easiest way to verify disk images (works with large files >128MB):

```bash
# Using the automata-linux repository
cd automata-linux

# Download disk image and attestations
cvm-cli get-disk aws
cvm-cli get-attestations

# Verify the disk image
cvm-cli verify-attestation aws_disk.vmdk
```

This method handles large disk images (>128MB) that exceed cosign's size limits by:
1. Verifying the SHA256 hash matches the attestation
2. Cryptographically verifying the certificate chain
3. Checking the Rekor transparency log
4. Displaying build metadata including source commit, binaries, and security configuration

### Alternative: GitHub CLI (Public Repos Only - Not Supported Yet)

```bash
# Download disk image from release
wget https://github.com/automata-network/automata-linux/releases/download/v1.0.0/aws_disk.vmdk

# Verify using GitHub Attestations API
gh attestation verify aws_disk.vmdk \
  --owner automata-network \
  --repo automata-linux
```

**Note:** GitHub CLI verification requires the repository to be public or GitHub Enterprise Cloud with repo access. Bundle-based verification is recommended for all scenarios.

## Verification for All Cloud Providers

### AWS VMDK

```bash
# Using cvm-cli (recommended)
cvm-cli get-disk aws
cvm-cli get-attestations
cvm-cli verify-attestation aws_disk.vmdk
```

### Azure VHD

```bash
# Using cvm-cli (recommended)
cvm-cli get-disk azure
cvm-cli get-attestations
cvm-cli verify-attestation azure_disk.vhd
```

### GCP tar.gz

```bash
# Using cvm-cli (recommended)
cvm-cli get-disk gcp
cvm-cli get-attestations
cvm-cli verify-attestation gcp_disk.tar.gz
```

## How Verification Works for Large Disk Images

CVM disk images (~200MB) exceed cosign's 128MB size limit for `verify-blob-attestation`. The verification process works around this by:

### Step 1: Hash Verification
```bash
# Extract expected hash from attestation bundle
EXPECTED_HASH=$(cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq -r '.subject[0].digest.sha256')

# Calculate actual hash of disk image
ACTUAL_HASH=$(sha256sum aws_disk.vmdk | awk '{print $1}')

# Compare hashes
if [ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]; then
  echo "✅ Hash matches - disk image integrity verified"
fi
```

### Step 2: Certificate Verification
```bash
# Extract and verify certificate from GitHub Actions OIDC
CERT=$(cat aws_disk.vmdk.bundle | jq -r '.cert' | base64 -d)

# Verify issuer is GitHub Actions
openssl x509 -in <(echo "$CERT") -noout -text | \
  grep "token.actions.githubusercontent.com"

# Verify workflow identity matches expected repository
openssl x509 -in <(echo "$CERT") -noout -text | \
  grep -A1 "Subject Alternative Name" | \
  grep "https://github.com/automata-network/"
```

### Step 3: Rekor Transparency Log
```bash
# Verify Rekor transparency log entry exists
cat aws_disk.vmdk.bundle | jq -e '.rekorBundle' > /dev/null
echo "✅ Rekor transparency log entry present"
```

This approach provides the same security guarantees as cosign verification:
- ✅ **Integrity**: Hash proves disk image hasn't been modified
- ✅ **Authenticity**: Certificate proves attestation came from GitHub Actions
- ✅ **Non-repudiation**: Rekor log provides immutable public record
- ✅ **Identity**: Certificate identity proves it was built by the correct workflow

## Understanding Certificate Verification

The verification process checks the cryptographic certificate embedded in the attestation bundle to ensure it was issued by GitHub Actions and matches the expected workflow identity.

### Certificate Identity

The certificate contains a "Subject Alternative Name" that identifies which GitHub workflow created the attestation:

```
https://github.com/automata-network/cvm-image-builder/.github/workflows/build-and-release.yml@refs/tags/v1.0.0
```

This includes:
- Organization: `automata-network`
- Repository: `cvm-image-builder`
- Workflow: `.github/workflows/build-and-release.yml`
- Git ref: `refs/tags/v1.0.0`

The verification script checks that this identity matches the pattern `^https://github.com/automata-network/.*` to prevent accepting attestations from:
- ❌ Forked repositories
- ❌ Different organizations
- ❌ Malicious actors impersonating the workflow

### Certificate Issuer

The certificate is issued by GitHub Actions OIDC provider through Sigstore's Fulcio CA:

**How it works:**
1. GitHub Actions requests an OIDC token from `https://token.actions.githubusercontent.com`
2. Sigstore's Fulcio CA verifies the token and issues a short-lived signing certificate
3. The certificate contains the OIDC issuer in its metadata
4. During verification, the script confirms the issuer is `https://token.actions.githubusercontent.com`

This ensures the signature came from GitHub Actions, not an impersonator.

## What's Included in Attestations

Each attestation contains comprehensive build metadata:

### Repository Information
- Main repository commit SHA
- Submodule commit SHAs (python-uefivars)
- Git ref (tag/branch that triggered the build)
- Workflow name and run ID

### Binary Checksums
- **cvm-agent binary:** SHA256 of `attestation_agent`
- **cvm-agent library:** SHA256 of `libcvm.so`
- **Kernel image:** SHA256 of `kernel.img`
- **Kernel certificate:** SHA256 of `kernel.crt`

These checksums can be cross-referenced with official builds from [cvm-components-builder](https://github.com/automata-network/cvm-components-builder) releases.

### Security Artifacts
- **Secure Boot key fingerprints:** SHA256 fingerprints of PK, KEK, db, and kernel certificates
- **dm-verity root hash:** Root hash for rootfs partition integrity
- **dm-verity hash file:** SHA256 of the verity hash file

### Build Environment
- Kernel version (e.g., `6.15.11-automata`)
- Tool versions: QEMU, sbsign, Python, Make, GCC
- Build timestamp (ISO 8601 UTC)
- Runner OS and architecture
- Builder identity (GitHub Actions run URL)

### Disk Images
- AWS VMDK SHA256 checksum
- Azure VHD SHA256 checksum
- GCP tar.gz SHA256 checksum

## Inspecting Attestation Contents

### View Full Build Metadata

The `verify-attestation` command automatically displays key build metadata. To view the complete metadata:

```bash
# Extract full build metadata from bundle
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq '.predicate'
```

Or save it to a file:
```bash
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq '.predicate' > build-metadata.json
```

### Extract Specific Information

**Get source repository and commit:**
```bash
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq -r '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit'
```

**Get build timestamp:**
```bash
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq -r '.predicate.runDetails.metadata.startedOn'
```

**Get binary checksums:**
```bash
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq '.predicate.buildDefinition.internalParameters.binary_checksums'
```

**Get security configuration (secure boot, dm-verity):**
```bash
cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | jq '{secure_boot, dm_verity: .buildDefinition.internalParameters | {secure_boot, dm_verity}}'
```

### View Sigstore Certificate

```bash
# Extract and inspect the signing certificate
cat aws_disk.vmdk.bundle | jq -r '.cert' | base64 -d | openssl x509 -text -noout
```

Look for the "Subject Alternative Name" extension which contains the workflow identity.


## Security Considerations

### What Attestations Protect Against

| Attack Type | Protection |
|------------|------------|
| ✅ **Binary substitution attacks** | Prevents swapping disk images with malicious versions |
| ✅ **Supply chain attacks** | Verifies the build came from the official source |
| ✅ **Tampering** | Detects any modifications to disk images after build |
| ✅ **Provenance tracking** | Links images to specific source code commits |

### What Attestations Don't Protect Against

| Limitation | Mitigation |
|-----------|------------|
| ❌ **Compromised source code** | Attestations verify "what was built," not "what should be built" - review source code changes |
| ❌ **Malicious workflow changes** | Review workflow changes in pull requests before merging |
| ❌ **Compromised dependencies** | Verify submodule SHAs and binary sources against known good values |
| ❌ **Runtime attacks** | Use runtime attestation (TPM PCRs/RTMRs) for deployed VMs |

### Best Practices

1. **Always verify attestations** before deploying disk images
2. **Check binary checksums** against known good values from official releases
3. **Verify secure boot key fingerprints** match your trusted keys
4. **Review build metadata** for unexpected tool versions or parameters
5. **Automate verification** in your deployment pipelines
6. **Store bundle files** with your disk images for offline verification
7. **Restrict certificate identity** to specific repositories/workflows in production

## Linking Build Attestation to Runtime Attestation

The build attestation captures the **dm-verity root hash** which is measured into TPM PCRs at boot. This creates a chain of trust from build to runtime:

```
Source Code (git commit)
  ↓ (attested by GitHub Actions)
Disk Image Build (attestation)
  ↓ (includes dm-verity root hash)
Boot Process (measures rootfs)
  ↓ (extends TPM PCR)
Runtime Attestation (TPM quote)
```

To verify the chain:

1. **Verify build attestation** (this guide)
2. **Extract dm-verity root hash** from attestation
3. **Get runtime TPM quote** from deployed VM
4. **Verify root hash in PCR** matches attestation

```bash
# The verify-attestation command displays the dm-verity root hash
cvm-cli verify-attestation aws_disk.vmdk

# Or extract it manually
DM_VERITY_HASH=$(cat aws_disk.vmdk.bundle | jq -r '.base64Signature' | base64 -d | \
  jq -r '.payload' | base64 -d | \
  jq -r '.predicate.buildDefinition.internalParameters.dm_verity.root_hash')

echo "Build attestation dm-verity hash: $DM_VERITY_HASH"

# Get runtime measurements from deployed VM
# (Commands depend on CSP and TEE type - TDX vs SEV-SNP)
# Compare with runtime PCR values to ensure integrity
```

## Additional Resources

- [SLSA Framework](https://slsa.dev/)
- [Sigstore Documentation](https://docs.sigstore.dev/)
- [in-toto Attestation Specification](https://github.com/in-toto/attestation)
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [CVM Architecture Documentation](https://github.com/automata-network/cvm-image-builder/blob/main/docs/architecture.md)

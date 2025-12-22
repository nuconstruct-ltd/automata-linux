# SLSA Build Provenance Attestation Verification Guide

This guide explains how to verify the cryptographic build provenance attestations for CVM disk images.

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

Install [cosign](https://docs.sigstore.dev/cosign/installation/):

```bash
# macOS
brew install sigstore/tap/cosign

# Linux (amd64)
wget https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign

# Verify installation
cosign version
```

### Recommended: Verification with Bundle Files

For maximum compatibility (works with private repos, no authentication needed):

```bash
# Download disk image and attestation bundle
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/aws_disk.vmdk
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/attestations.zip

# Extract attestations
unzip attestations.zip

# Verify with cosign using bundle file
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle aws_disk.vmdk.intoto.jsonl \
  aws_disk.vmdk
```

### Alternative: GitHub CLI (Public Repos Only)

```bash
# Download disk image from release
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/aws_disk.vmdk

# Verify using GitHub Attestations API
gh attestation verify aws_disk.vmdk \
  --owner automata-network \
  --repo cvm-base-image
```

**Note:** GitHub CLI verification requires the repository to be public or GitHub Enterprise Cloud with repo access. Bundle-based verification is recommended for all scenarios.

## Verification for All Cloud Providers

### AWS VMDK

```bash
# Download
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/aws_disk.vmdk
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/attestations.zip
unzip attestations.zip

# Verify
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle aws_disk.vmdk.intoto.jsonl \
  aws_disk.vmdk
```

### Azure VHD

```bash
# Download and decompress
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/azure_disk.vhd.xz
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/attestations.zip
unzip attestations.zip
xz -d azure_disk.vhd.xz

# Verify
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle azure_disk.vhd.intoto.jsonl \
  azure_disk.vhd
```

### GCP tar.gz

```bash
# Download
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/gcp_disk.tar.gz
wget https://github.com/automata-network/cvm-base-image/releases/download/v1.0.0/attestations.zip
unzip attestations.zip

# Verify
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle gcp_disk.tar.gz.intoto.jsonl \
  gcp_disk.tar.gz
```

## Understanding the Verification Parameters

### `--certificate-identity-regexp`

```bash
--certificate-identity-regexp="^https://github.com/automata-network/.*"
```

**What it does:** Verifies the attestation was signed by a workflow from the `automata-network` GitHub organization.

**Why it matters:** Prevents accepting attestations from forked repositories or malicious actors.

**The certificate identity format:**
```
https://github.com/automata-network/cvm-image-builder/.github/workflows/build-and-release.yml@refs/tags/v1.0.0
```

This includes:
- Organization: `automata-network`
- Repository: `cvm-image-builder`
- Workflow: `.github/workflows/build-and-release.yml`
- Git ref: `refs/tags/v1.0.0`

### `--certificate-oidc-issuer`

```bash
--certificate-oidc-issuer="https://token.actions.githubusercontent.com"
```

**What it does:** Verifies the signing certificate was issued by GitHub Actions OIDC provider.

**Why it matters:** Ensures the signature came from GitHub Actions, not an impersonator.

**How it works:**
1. GitHub Actions requests an OIDC token from `https://token.actions.githubusercontent.com`
2. Sigstore's Fulcio CA verifies the token and issues a short-lived signing certificate
3. The certificate contains the OIDC issuer in its metadata
4. During verification, cosign confirms the issuer is GitHub Actions

### More Restrictive Verification

**Only specific repository:**
```bash
--certificate-identity-regexp="^https://github.com/automata-network/cvm-image-builder/.*"
```

**Only specific workflow:**
```bash
--certificate-identity="https://github.com/automata-network/cvm-image-builder/.github/workflows/build-and-release.yml@refs/tags/v1.0.0"
```

**Only version tags (not branches):**
```bash
--certificate-identity-regexp="^https://github.com/automata-network/cvm-image-builder/.*@refs/tags/v.*"
```

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

### View Full Attestation

```bash
# Install jq if not already installed
sudo apt-get install jq  # Debian/Ubuntu
brew install jq          # macOS

# Pretty-print the entire attestation
cat aws_disk.vmdk.intoto.jsonl | jq .
```

### Extract Specific Information

**Get builder identity:**
```bash
cat aws_disk.vmdk.intoto.jsonl | jq -r '.payload | @base64d | fromjson | .predicate.builder.id'
```

**Get source commit SHA:**
```bash
cat aws_disk.vmdk.intoto.jsonl | jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.resolvedDependencies[] | select(.uri | contains("git+")) | .digest.sha1'
```

**Get build timestamp:**
```bash
cat aws_disk.vmdk.intoto.jsonl | jq -r '.payload | @base64d | fromjson | .predicate.metadata.buildStartedOn'
```

**Get all build metadata:**
```bash
cat aws_disk.vmdk.intoto.jsonl | jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.externalParameters'
```

### View Sigstore Certificate

```bash
# Extract and inspect the signing certificate
cat aws_disk.vmdk.intoto.jsonl | \
  jq -r '.dsseEnvelope.signatures[0].verificationMaterial.certificate' | \
  base64 -d | \
  openssl x509 -text -noout
```

Look for the "Subject Alternative Name" extension which contains the workflow identity.

## Automated Verification Script

Create a reusable verification script:

```bash
#!/bin/bash
# verify-cvm-image.sh
set -euo pipefail

IMAGE_FILE="$1"
BUNDLE_FILE="${IMAGE_FILE}.intoto.jsonl"

if [ ! -f "$IMAGE_FILE" ]; then
  echo "Error: Image file not found: $IMAGE_FILE"
  exit 1
fi

if [ ! -f "$BUNDLE_FILE" ]; then
  echo "Error: Attestation bundle not found: $BUNDLE_FILE"
  exit 1
fi

echo "Verifying $IMAGE_FILE..."

# Verify attestation
if cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/automata-network/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle "$BUNDLE_FILE" \
  "$IMAGE_FILE" > /dev/null 2>&1; then

  echo "✅ Attestation verified successfully!"

  # Extract and display key metadata
  echo ""
  echo "Build Information:"
  cat "$BUNDLE_FILE" | jq -r '.payload | @base64d | fromjson | .predicate.metadata | "  Started: \(.buildStartedOn)\n  Finished: \(.buildFinishedOn)"'

  echo ""
  echo "Builder:"
  cat "$BUNDLE_FILE" | jq -r '.payload | @base64d | fromjson | .predicate.builder.id | "  \(.)"'

  echo ""
  echo "Source Repository:"
  cat "$BUNDLE_FILE" | jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.resolvedDependencies[] | select(.uri | contains("git+")) | "  Commit: \(.digest.sha1)\n  URI: \(.uri)"'

else
  echo "❌ Attestation verification failed!"
  exit 1
fi
```

Usage:
```bash
chmod +x verify-cvm-image.sh
./verify-cvm-image.sh aws_disk.vmdk
```

## Integration with Deployment Pipelines

### Terraform Example

```hcl
resource "null_resource" "verify_image" {
  provisioner "local-exec" {
    command = <<-EOT
      cosign verify-attestation --type slsaprovenance \
        --certificate-identity-regexp="^https://github.com/automata-network/.*" \
        --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
        --bundle aws_disk.vmdk.intoto.jsonl \
        aws_disk.vmdk
    EOT
  }
}

resource "aws_ami" "cvm" {
  depends_on = [null_resource.verify_image]
  # ... AMI configuration
}
```

### GitHub Actions Example

```yaml
- name: Verify CVM disk image
  run: |
    cosign verify-attestation --type slsaprovenance \
      --certificate-identity-regexp="^https://github.com/automata-network/.*" \
      --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
      --bundle aws_disk.vmdk.intoto.jsonl \
      aws_disk.vmdk

- name: Deploy only if verified
  if: success()
  run: |
    ./deploy-to-aws.sh
```

### CI/CD Policy Enforcement

```bash
#!/bin/bash
# deployment-gate.sh
set -euo pipefail

REQUIRED_ORG="automata-network"
IMAGE="$1"

# Verify attestation
if ! cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp="^https://github.com/${REQUIRED_ORG}/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --bundle "${IMAGE}.intoto.jsonl" \
  "$IMAGE"; then
  echo "❌ POLICY VIOLATION: Image failed attestation verification"
  exit 1
fi

# Additional checks: verify it's from a version tag
WORKFLOW_REF=$(cat "${IMAGE}.intoto.jsonl" | jq -r '.payload | @base64d | fromjson | .predicate.builder.id')
if [[ ! "$WORKFLOW_REF" =~ @refs/tags/v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "❌ POLICY VIOLATION: Image not built from version tag"
  exit 1
fi

echo "✅ All policy checks passed"
```

## Troubleshooting

### Error: "No attestations found"

**Cause:** Using GitHub CLI with a private repository without GitHub Enterprise Cloud.

**Solution:** Use cosign with bundle files instead (see [Recommended verification](#recommended-verification-with-bundle-files) above).

### Error: "Certificate verification failed"

**Cause:** The certificate identity doesn't match the expected pattern.

**Solution:** Check what identity the certificate actually contains:
```bash
cat aws_disk.vmdk.intoto.jsonl | \
  jq -r '.dsseEnvelope.signatures[0].verificationMaterial.certificate' | \
  base64 -d | \
  openssl x509 -text -noout | \
  grep -A 5 "Subject Alternative Name"
```

### Error: "Transparency log entry not found"

**Cause:** The attestation may have been generated very recently (Rekor indexing delay).

**Solution:** Wait a few minutes and try again. The Rekor transparency log is eventually consistent.

### Error: "Digest mismatch"

**Cause:** The disk image file has been modified after attestation was created.

**Solution:** Re-download the disk image from the official release. This is a **security-critical error** - do not deploy the image.

### Verification takes a long time

**Cause:** Cosign is downloading and verifying the Sigstore root certificates and Rekor transparency log.

**Solution:** This is normal for the first verification. Subsequent verifications will use cached data and be faster.

## Verifying Binary Checksums

The attestation includes SHA256 checksums of the binaries packaged into the disk image. You can verify these match official builds:

### Extract Binary from Disk Image

```bash
# Mount the disk image (requires loop device)
sudo losetup -fP disk.raw
LOOP_DEV=$(losetup -j disk.raw | awk -F: '{print $1}')
sudo mount ${LOOP_DEV}p2 /mnt

# Compute checksum of cvm-agent binary
sha256sum /mnt/usr/bin/attestation_agent

# Compare with attestation
cat aws_disk.vmdk.intoto.jsonl | \
  jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.externalParameters.binary_checksums.cvm_agent_binary_sha256'

# Cleanup
sudo umount /mnt
sudo losetup -d $LOOP_DEV
```

### Cross-reference with Official Builds

If available, download the official cvm-agent binary from [cvm-components-builder releases](https://github.com/automata-network/cvm-components-builder/releases) and compare checksums.

## Security Considerations

### What Attestations Protect Against

✅ **Binary substitution attacks** - Prevents swapping disk images with malicious versions
✅ **Supply chain attacks** - Verifies the build came from the official source
✅ **Tampering** - Detects any modifications to disk images after build
✅ **Provenance tracking** - Links images to specific source code commits

### What Attestations Don't Protect Against

❌ **Compromised source code** - Attestations verify "what was built," not "what should be built"
❌ **Malicious workflow changes** - Review workflow changes in pull requests
❌ **Compromised dependencies** - Verify submodule SHAs and binary sources
❌ **Runtime attacks** - Use runtime attestation (TPM PCRs/RTMRs) for deployed VMs

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
# Extract dm-verity root hash from attestation
DM_VERITY_HASH=$(cat aws_disk.vmdk.intoto.jsonl | \
  jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.externalParameters.dm_verity.root_hash')

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

## Getting Help

If you encounter issues verifying attestations:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Search [existing issues](https://github.com/automata-network/cvm-base-image/issues)
3. Open a new issue with:
   - The exact error message
   - The verification command you ran
   - The release version you're verifying
   - Output of `cosign version` and `jq --version`

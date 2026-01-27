# Installation Guide for atakit

This guide provides instructions for installing `atakit` on various operating systems.

## Quick Install

### Ubuntu / Debian

```bash
# Get the latest release tag (requires jq: sudo apt-get install jq)
LATEST=$(curl -sL https://api.github.com/repos/automata-network/automata-linux/releases/latest | jq -r .tag_name)
if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then echo "Failed to fetch latest release"; exit 1; fi
VERSION=${LATEST#v}

# Download and install
wget "https://github.com/automata-network/automata-linux/releases/download/${LATEST}/atakit_${VERSION}-1_all.deb"
sudo dpkg -i atakit_${VERSION}-1_all.deb
sudo apt-get install -f
```

### macOS (Homebrew)

```bash
# Add the tap
brew tap automata-network/automata-linux https://github.com/automata-network/automata-linux.git

# Install atakit
brew install atakit
```

### From Source (All Platforms)

```bash
# Clone the repository
git clone --recurse-submodules https://github.com/automata-network/automata-linux.git
cd automata-linux

# Install to /usr/local (requires sudo)
sudo make install

# Or install to custom location
make install PREFIX=$HOME/.local
```

## Post-Installation

After installing `atakit`, you need to set up credentials for the cloud providers you plan to use:

### AWS Setup

Install AWS CLI v2 if not already installed:

**Linux (x86_64):**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Linux (ARM):**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**macOS:**
```bash
# Download and run the official installer
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

**Configure AWS credentials:**
```bash
aws configure
```

For more installation options, see: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

### Google Cloud Platform Setup

```bash
# Install gcloud CLI (if not already installed)
# Ubuntu/Debian:
# Follow: https://cloud.google.com/sdk/docs/install#deb

# macOS:
brew install --cask google-cloud-sdk

# Initialize and authenticate
gcloud init
gcloud auth login
```

### Azure Setup

```bash
# Install Azure CLI (if not already installed)
# Ubuntu/Debian:
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# macOS:
brew install azure-cli

# Login to Azure
az login
```

## Verification

Verify that `atakit` is installed correctly:

```bash
# Check installation
atakit --help

# Should work from any directory (like git!)
cd /tmp
atakit --help
```

## User Data Location

When installed via package manager, `atakit` stores user data in:
```
~/.atakit/
  ├── artifacts/     # VM metadata and artifacts
  └── disks/         # Downloaded disk images
```

## Uninstallation

### Ubuntu / Debian
```bash
sudo apt-get remove atakit
```

### macOS
```bash
brew uninstall atakit
brew untap automata-network/automata-linux
```

### From Source
```bash
cd automata-linux
sudo make uninstall
```

**Note:** User data in `~/.atakit/` is preserved during uninstallation. To remove it:
```bash
rm -rf ~/.atakit
```

## Upgrading

### Ubuntu / Debian
```bash
# Set VERSION to the desired version (e.g., 0.1.4)
VERSION=0.1.4
wget https://github.com/automata-network/automata-linux/releases/download/v${VERSION}/atakit_${VERSION}-1_all.deb
sudo dpkg -i atakit_${VERSION}-1_all.deb
```

### macOS
```bash
brew update
brew upgrade atakit
```

## Troubleshooting

### Command not found

If `atakit` is not found after installation:

1. **Check if it's installed:**
   ```bash
   which atakit
   ```

2. **Check your PATH:**
   ```bash
   echo $PATH
   ```
   Should include `/usr/local/bin` or `/usr/bin`

3. **Try with full path:**
   ```bash
   /usr/local/bin/atakit --help
   ```

### Permission denied

If you get permission errors:

```bash
# Check file permissions
ls -l /usr/local/bin/atakit

# Should be executable (755)
sudo chmod +x /usr/local/bin/atakit
```

### Missing dependencies

If you get errors about missing commands:

**Ubuntu/Debian:**
```bash
sudo apt-get install jq curl openssl qemu-utils python3
```

**macOS:**
```bash
brew install jq curl openssl qemu python3
```

## Support

For issues and questions:
- GitHub Issues: https://github.com/automata-network/automata-linux/issues
- Documentation: https://github.com/automata-network/automata-linux#readme

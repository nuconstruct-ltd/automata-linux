# Installation Guide for cvm-cli

This guide provides instructions for installing `cvm-cli` on various operating systems.

## Quick Install

### Ubuntu / Debian

```bash
# Download the latest .deb package
wget https://github.com/automata-network/cvm-base-image/releases/latest/download/cvm-cli_0.1.0-1_all.deb

# Install the package
sudo dpkg -i cvm-cli_0.1.0-1_all.deb

# Install dependencies (if any are missing)
sudo apt-get install -f
```

### macOS (Homebrew)

```bash
# Add the cvm-cli tap
brew tap automata-network/cvm-cli https://github.com/automata-network/cvm-base-image

# Install cvm-cli
brew install cvm-cli
```

### From Source (All Platforms)

```bash
# Clone the repository
git clone --recurse-submodules https://github.com/automata-network/cvm-base-image.git
cd cvm-base-image

# Install to /usr/local (requires sudo)
sudo make install

# Or install to custom location
make install PREFIX=$HOME/.local
```

## Post-Installation

After installing `cvm-cli`, you need to set up credentials for the cloud providers you plan to use:

### AWS Setup

```bash
# Install AWS CLI v2 (if not already installed)
# Linux (x86_64):
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Linux (ARM):
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Or using snap (Ubuntu):
sudo snap install aws-cli --classic

# macOS:
brew install awscli

# Configure AWS credentials
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

Verify that `cvm-cli` is installed correctly:

```bash
# Check installation
cvm-cli --help

# Should work from any directory (like git!)
cd /tmp
cvm-cli --help
```

## User Data Location

When installed via package manager, `cvm-cli` stores user data in:
```
~/.cvm-cli/
  ├── artifacts/     # VM metadata and artifacts
  └── disks/         # Downloaded disk images
```

## Uninstallation

### Ubuntu / Debian
```bash
sudo apt-get remove cvm-cli
```

### macOS
```bash
brew uninstall cvm-cli
brew untap automata-network/cvm-cli
```

### From Source
```bash
cd cvm-base-image
sudo make uninstall
```

**Note:** User data in `~/.cvm-cli/` is preserved during uninstallation. To remove it:
```bash
rm -rf ~/.cvm-cli
```

## Upgrading

### Ubuntu / Debian
```bash
wget https://github.com/automata-network/cvm-base-image/releases/latest/download/cvm-cli_VERSION_all.deb
sudo dpkg -i cvm-cli_VERSION_all.deb
```

### macOS
```bash
brew update
brew upgrade cvm-cli
```

## Troubleshooting

### Command not found

If `cvm-cli` is not found after installation:

1. **Check if it's installed:**
   ```bash
   which cvm-cli
   ```

2. **Check your PATH:**
   ```bash
   echo $PATH
   ```
   Should include `/usr/local/bin` or `/usr/bin`

3. **Try with full path:**
   ```bash
   /usr/local/bin/cvm-cli --help
   ```

### Permission denied

If you get permission errors:

```bash
# Check file permissions
ls -l /usr/local/bin/cvm-cli

# Should be executable (755)
sudo chmod +x /usr/local/bin/cvm-cli
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
- GitHub Issues: https://github.com/automata-network/cvm-base-image/issues
- Documentation: https://github.com/automata-network/cvm-base-image#readme

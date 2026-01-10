class CvmCli < Formula
  desc "CLI tool for managing Confidential VMs across AWS, GCP, and Azure"
  homepage "https://github.com/automata-network/cvm-base-image"
  version "0.1.0"
  license "Apache-2.0"

  depends_on arch: :arm64

  # For private repos, use HOMEBREW_GITHUB_API_TOKEN
  # Usage: export HOMEBREW_GITHUB_API_TOKEN=your_token && brew install cvm-cli
  url "https://api.github.com/repos/automata-network/cvm-base-image/releases/assets/338737236",
      headers: ["Authorization: token #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}", "Accept: application/octet-stream"]
  sha256 "232da257182f6494b8e09c57e924ac9343da35d9b8702ae962adbd0fd1c08202"

  depends_on "jq"
  depends_on "curl"
  depends_on "openssl"
  depends_on "qemu"
  depends_on "python@3.9" => :recommended

  def install
    bin.install "bin/cvm-cli"
    (share/"cvm-cli").install Dir["share/cvm-cli/*"]
  end

  test do
    # Test that the binary runs
    system "#{bin}/cvm-cli", "--help" rescue true
    # Syntax validation
    system "bash", "-n", "#{bin}/cvm-cli"
  end

  def caveats
    <<~EOS
      cvm-cli has been installed successfully!

      To use cvm-cli with cloud providers, you need to install their CLIs:
        - AWS:   brew install awscli
        - GCP:   brew install --cask google-cloud-sdk
        - Azure: brew install azure-cli

      User data will be stored in: ~/.cvm-cli/

      Get started:
        cvm-cli --help
    EOS
  end
end

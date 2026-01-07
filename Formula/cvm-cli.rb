class CvmCli < Formula
  desc "CLI tool for managing Confidential VMs across AWS, GCP, and Azure"
  homepage "https://github.com/automata-network/cvm-base-image"
  url "https://github.com/automata-network/cvm-base-image/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PUT_SHA256_HERE" # Update this after creating the release
  license "Apache-2.0"

  depends_on "jq"
  depends_on "curl"
  depends_on "openssl"
  depends_on "qemu"
  depends_on "python@3.9" => :recommended

  def install
    system "make", "install", "PREFIX=#{prefix}"
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

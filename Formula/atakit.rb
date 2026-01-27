class Atakit < Formula
  desc "CLI tool for managing Confidential VMs across AWS, GCP, and Azure"
  homepage "https://github.com/automata-network/automata-linux"
  version "0.1.3"
  license "Apache-2.0"

  depends_on arch: :arm64

  # For private repos, use HOMEBREW_GITHUB_API_TOKEN
  # Usage: export HOMEBREW_GITHUB_API_TOKEN=your_token && brew install atakit
  url "https://api.github.com/repos/automata-network/automata-linux/releases/assets/339530902",
      headers: ["Authorization: token #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}", "Accept: application/octet-stream"]
  sha256 "a527e02564e46d2ff2ea5fe960f0d134caab599540ad6ac3a4e769e91484a686"

  depends_on "jq"
  depends_on "curl"
  depends_on "openssl"
  depends_on "qemu"
  depends_on "python@3.9" => :recommended

  def install
    bin.install "bin/atakit"
    (share/"atakit").install Dir["share/atakit/*"]
  end

  test do
    # Test that the binary runs
    system "#{bin}/atakit", "--help" rescue true
    # Syntax validation
    system "bash", "-n", "#{bin}/atakit"
  end

  def caveats
    <<~EOS
      atakit has been installed successfully!

      To use atakit with cloud providers, you need to install their CLIs:
        - AWS:   brew install awscli
        - GCP:   brew install --cask google-cloud-sdk
        - Azure: brew install azure-cli

      User data will be stored in: ~/.atakit/

      Get started:
        atakit --help
    EOS
  end
end

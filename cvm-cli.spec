Name:           cvm-cli
Version:        0.1.0
Release:        1%{?dist}
Summary:        CLI tool for managing Confidential VMs

License:        Apache-2.0
URL:            https://github.com/automata-network/cvm-base-image
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
Requires:       bash >= 4.0
Requires:       jq
Requires:       curl
Requires:       openssl
Requires:       qemu-img
Requires:       python3 >= 3.9
Suggests:       awscli
Suggests:       google-cloud-sdk
Suggests:       azure-cli
Suggests:       docker
Suggests:       podman

%description
cvm-cli is a command-line interface for deploying and managing
Confidential Virtual Machines (CVMs) across multiple cloud platforms
including AWS, Google Cloud Platform (GCP), and Microsoft Azure.

Features:
* Deploy CVMs to AWS, GCP, and Azure
* Update workloads on running CVMs
* Download and verify disk images with SLSA attestations
* Manage VM resources and retrieve logs
* Sign container images and kernel livepatches
* Support for secure boot and attestation

%prep
%autosetup

%build
# Nothing to build - shell scripts

%install
make install PREFIX=%{buildroot}/usr

%check
make test

%files
%license LICENSE
%doc README.md
/usr/bin/cvm-cli
/usr/share/cvm-cli/
/usr/share/doc/cvm-cli/

%changelog
* Tue Jan 07 2026 Yaoxin Jin <yaoxin.j@ata.network> - 0.1.0-1
- Initial release
- Support for AWS, GCP, and Azure deployments
- SLSA attestation verification
- Git-like installation - works from any directory
- User data stored in ~/.cvm-cli/

# Makefile for cvm-cli installation
# Supports installation on Linux and macOS

DESTDIR ?=
PREFIX ?= /usr/local
BINDIR = $(DESTDIR)$(PREFIX)/bin
SHAREDIR = $(DESTDIR)$(PREFIX)/share/cvm-cli
DOCDIR = $(DESTDIR)$(PREFIX)/share/doc/cvm-cli

VERSION = 0.1.0

.PHONY: all install uninstall clean test help

all:
	@echo "Run 'make install' to install cvm-cli"
	@echo "Run 'make uninstall' to remove cvm-cli"

help:
	@echo "Available targets:"
	@echo "  install    - Install cvm-cli to $(PREFIX)"
	@echo "  uninstall  - Remove cvm-cli from $(PREFIX)"
	@echo "  clean      - Remove build artifacts and downloaded images"
	@echo "  test       - Run syntax validation on all scripts"

install:
	@echo "Installing cvm-cli $(VERSION) to $(PREFIX)..."

	# Initialize git submodules if needed
	@if [ -d .git ] && [ -z "$$(ls -A tools/python-uefivars 2>/dev/null)" ]; then \
		echo "Initializing git submodules..."; \
		git submodule update --init --recursive; \
	fi

	# Create installation directories
	mkdir -p $(BINDIR)
	mkdir -p $(SHAREDIR)/scripts
	mkdir -p $(SHAREDIR)/tools
	mkdir -p $(SHAREDIR)/workload/config/cvm_agent
	mkdir -p $(SHAREDIR)/workload/config
	mkdir -p $(SHAREDIR)/workload/secrets
	mkdir -p $(SHAREDIR)/secure_boot
	mkdir -p $(DOCDIR)

	# Install main CLI
	install -m 0755 cvm-cli $(BINDIR)/cvm-cli

	# Install scripts
	install -m 0755 scripts/*.sh $(SHAREDIR)/scripts/

	# Install tools
	install -m 0755 tools/json_sig_tool.py $(SHAREDIR)/tools/
	@if [ -d tools/python-uefivars ]; then \
		cp -r tools/python-uefivars $(SHAREDIR)/tools/; \
		chmod -R 755 $(SHAREDIR)/tools/python-uefivars; \
	fi

	# Install workload templates
	install -m 0644 workload/docker-compose.yml $(SHAREDIR)/workload/
	install -m 0644 workload/config/cvm_agent/*.json $(SHAREDIR)/workload/config/cvm_agent/
	install -m 0644 workload/config/*.yml $(SHAREDIR)/workload/config/
	install -m 0644 workload/config/*.conf $(SHAREDIR)/workload/config/
	@if [ -d workload/secrets ] && [ -n "$$(ls -A workload/secrets 2>/dev/null)" ]; then \
		install -m 0600 workload/secrets/* $(SHAREDIR)/workload/secrets/ 2>/dev/null || true; \
	fi

	# Install secure boot certs if they exist
	@if [ -d secure_boot ] && [ -n "$$(ls -A secure_boot 2>/dev/null)" ]; then \
		install -m 0644 secure_boot/* $(SHAREDIR)/secure_boot/ 2>/dev/null || true; \
	fi

	# Install documentation
	install -m 0644 README.md $(DOCDIR)/
	install -m 0644 LICENSE $(DOCDIR)/
	@if [ -f INSTALL.md ]; then install -m 0644 INSTALL.md $(DOCDIR)/; fi
	@if [ -d docs ]; then \
		cp -r docs $(DOCDIR)/; \
		chmod -R 644 $(DOCDIR)/docs/*; \
	fi

	@echo ""
	@echo "✅ Installation complete!"
	@echo "Run 'cvm-cli' to get started."
	@echo ""
	@echo "First-time setup:"
	@echo "  - AWS: Run 'aws configure' to set up credentials"
	@echo "  - GCP: Run 'gcloud init' to set up credentials"
	@echo "  - Azure: Run 'az login' to set up credentials"

uninstall:
	@echo "Uninstalling cvm-cli..."
	rm -f $(BINDIR)/cvm-cli
	rm -rf $(SHAREDIR)
	rm -rf $(DOCDIR)
	@echo "✅ Uninstall complete!"
	@echo ""
	@echo "Note: User data in ~/.cvm-cli was preserved."
	@echo "To remove it: rm -rf ~/.cvm-cli"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf _artifacts/
	rm -f *.vmdk *.vhd *.vhd.xz *.tar.gz
	rm -f *.deb *.rpm *.pkg
	rm -f secure-boot-certs.zip
	@echo "✅ Clean complete!"

test:
	@echo "Running syntax validation..."
	@bash -n cvm-cli && echo "✓ cvm-cli syntax OK" || (echo "✗ cvm-cli syntax error" && exit 1)
	@for script in scripts/*.sh; do \
		bash -n $$script && echo "✓ $$script syntax OK" || (echo "✗ $$script syntax error" && exit 1); \
	done
	@echo ""
	@echo "✅ All tests passed!"

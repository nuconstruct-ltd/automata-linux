FROM debian:bookworm-slim
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl zlib1g zstd libzstd1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV UV_INSTALL_DIR=/usr/bin/
RUN curl -LSf https://astral.sh/uv/install.sh | sh
RUN uv python install 3.14.3t

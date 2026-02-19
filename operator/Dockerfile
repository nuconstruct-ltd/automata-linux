FROM debian:bookworm-slim
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get clean && \
    apt-get install -y --no-install-recommends \
      build-essential libffi-dev curl wget cmake \
      lsb-release gnupg software-properties-common \
      ca-certificates zlib1g zlib1g-dev zstd libzstd-dev \
    && apt-get clean
RUN bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)" 20
ENV UV_INSTALL_DIR=/usr/bin/
RUN curl -LSf https://astral.sh/uv/install.sh | sh
RUN uv python install 3.14.3t

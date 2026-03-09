FROM debian:bookworm-slim
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl \
      build-essential libffi-dev wget cmake \
      lsb-release gnupg software-properties-common \
      zlib1g zlib1g-dev zstd libzstd-dev \
      tmux vim htop tcptraceroute git \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && sed -i 's/^#\?Port .*/Port 2200/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Install llvm@20
RUN bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)" 20

# Install uv manually
ENV UV_INSTALL_DIR=/usr/bin/
RUN curl -LSf https://astral.sh/uv/install.sh | sh
# Install free-threaded python
RUN uv python install 3.14.3t

WORKDIR /root/app

EXPOSE 2200
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]

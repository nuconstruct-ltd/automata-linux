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
      locales \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && mkdir -p /run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && sed -i 's/^#\?Port .*/Port 2200/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install llvm@20
RUN bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)" 20

# Install uv manually
RUN curl -LSf https://astral.sh/uv/install.sh | sh \
      && sed -i '/\.local\/bin\/env/d' /root/.bashrc
ENV PATH="/root/.local/bin:$PATH"

# Install free-threaded python
RUN uv python install 3.14.3t
ENV PYTHON_GIL=0

WORKDIR /root/app

EXPOSE 2200
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]

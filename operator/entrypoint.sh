#!/bin/bash
set -e

# Set up SSH authorized keys from environment or mounted file
if [ -n "$SSH_PUBLIC_KEY" ]; then
  echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
elif [ -f /config/authorized_keys ]; then
  cp /config/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# Generate host keys if missing
ssh-keygen -A

exec /usr/sbin/sshd -D -e -p 2200

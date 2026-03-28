#!/bin/sh
# Generate Caddyfile from env vars. Uses domains with auto-TLS if set,
# otherwise falls back to port-based with self-signed certs.

RPC="${CADDY_RPC_DOMAIN:-}"
CVM="${CADDY_CVM_DOMAIN:-}"
CTRL="${CADDY_CONTROLLER_DOMAIN:-}"

if [ -z "$RPC" ] && [ -z "$CVM" ] && [ -z "$CTRL" ]; then
  # No domains — use self-signed certs on ports
  cat > /tmp/Caddyfile <<'NODOMAINS'
{
  local_certs
}

:80 {
  tls internal
  reverse_proxy tool-node:8545
}

:443 {
  tls internal
  reverse_proxy https://host.docker.internal:8000 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}

:8081 {
  tls internal
  reverse_proxy controller:8080
}
NODOMAINS
else
  # Domains set — auto-TLS via Let's Encrypt
  cat > /tmp/Caddyfile <<EOF
${RPC} {
  reverse_proxy tool-node:8545
}

${CVM} {
  reverse_proxy https://host.docker.internal:8000 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}

${CTRL} {
  reverse_proxy controller:8080
}
EOF
fi

exec caddy run --config /tmp/Caddyfile --adapter caddyfile

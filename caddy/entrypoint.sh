#!/bin/sh
set -e

envsubst < /etc/caddy/Caddyfile.template > /etc/caddy/Caddyfile

# Append agent block only if CADDY_AGENT_HOSTNAME is set
if [ -n "${CADDY_AGENT_HOSTNAME}" ]; then
  cat >> /etc/caddy/Caddyfile <<EOF

# Internal agent endpoint — on-LAN agents connect here to preserve real IPs
${CADDY_AGENT_HOSTNAME} {
    reverse_proxy backend:8080
}
EOF
fi

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

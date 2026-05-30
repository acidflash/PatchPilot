FROM caddy:2-alpine
RUN apk add --no-cache gettext
COPY Caddyfile.template /etc/caddy/Caddyfile.template
ENTRYPOINT ["sh", "-c", "envsubst < /etc/caddy/Caddyfile.template > /etc/caddy/Caddyfile && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"]

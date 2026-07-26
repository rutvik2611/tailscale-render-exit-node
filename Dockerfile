# =============================================================================
# Tailscale Exit Node - Dockerfile
# =============================================================================
# Minimal production image that runs Tailscale and advertises as an exit node.
# Includes a lightweight HTTP health endpoint for Render wake-up + monitoring.
# =============================================================================

FROM alpine:3.20

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
RUN apk add --no-cache \
    tailscale \
    iptables \
    ip6tables \
    iproute2 \
    curl \
    ca-certificates \
    bash \
    tzdata \
    python3

# ---------------------------------------------------------------------------
# Create tailscale data directory
# ---------------------------------------------------------------------------
RUN mkdir -p /var/lib/tailscale /var/run/tailscale && \
    chmod 755 /var/lib/tailscale /var/run/tailscale

# ---------------------------------------------------------------------------
# Copy scripts
# ---------------------------------------------------------------------------
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# ---------------------------------------------------------------------------
# Copy entrypoint
# ---------------------------------------------------------------------------
COPY start.sh /start.sh
RUN chmod +x /start.sh

# ---------------------------------------------------------------------------
# Expose health check metrics (optional HTTP endpoint)
# ---------------------------------------------------------------------------
EXPOSE 8080

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
ENV TAILSCALE_AUTHKEY=""
ENV HOSTNAME="render-exit-node"
ENV PORT=8080

# The container needs NET_ADMIN and SYS_MODULE capabilities
# Add these in render.yaml or your docker-compose.yml

ENTRYPOINT ["/start.sh"]
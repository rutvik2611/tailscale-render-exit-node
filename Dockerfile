# =============================================================================
# Tailscale Exit Node - Dockerfile
# =============================================================================
# Installs latest Tailscale from official static build and provides HTTP
# health endpoint with pretty HTML status page.
# =============================================================================

FROM alpine:3.20

# ---------------------------------------------------------------------------
# Install base dependencies
# ---------------------------------------------------------------------------
RUN apk add --no-cache \
    iptables \
    ip6tables \
    iproute2 \
    curl \
    ca-certificates \
    bash \
    tzdata \
    python3

# ---------------------------------------------------------------------------
# Install latest Tailscale from official tarball (avoids Alpine repo lag)
# ---------------------------------------------------------------------------
RUN ARCH=$(uname -m); \
    case "$ARCH" in \
        aarch64|arm64) URL="https://pkgs.tailscale.com/stable/tailscale_1.98.9_arm64.tgz" ;; \
        x86_64|amd64)  URL="https://pkgs.tailscale.com/stable/tailscale_1.98.9_amd64.tgz" ;; \
        *) echo "Unsupported arch: $ARCH"; exit 1 ;; \
    esac && \
    curl -fsSL "$URL" -o /tmp/tailscale.tgz && \
    tar xzf /tmp/tailscale.tgz -C /tmp && \
    cp /tmp/tailscale_*/tailscale /usr/local/bin/ && \
    cp /tmp/tailscale_*/tailscaled /usr/local/bin/ && \
    rm -rf /tmp/tailscale*

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

COPY scripts/health_server.py /usr/local/bin/health_server.py

COPY start.sh /start.sh
RUN chmod +x /start.sh

# ---------------------------------------------------------------------------
# Expose health check port
# ---------------------------------------------------------------------------
EXPOSE 8080

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
ENV TAILSCALE_AUTHKEY=""
ENV HOSTNAME="renderfn-exit"
ENV PORT=8080

ENTRYPOINT ["/start.sh"]
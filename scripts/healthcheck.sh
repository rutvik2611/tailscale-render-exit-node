#!/bin/bash
# =============================================================================
# healthcheck.sh - Tailscale Exit Node Health Monitor
# =============================================================================
# Verifies:
#   1. tailscaled process is running
#   2. Tailscale is connected to the tailnet
#   3. Exit node is being advertised
#   4. Has a valid IPv4 address
#
# Exit codes:
#   0 - Healthy
#   1 - Unhealthy (details printed to stderr)
# =============================================================================

set -euo pipefail

ERRORS=()

# ---------------------------------------------------------------------------
# Check 1: tailscaled process running
# ---------------------------------------------------------------------------
if ! pgrep -x tailscaled > /dev/null 2>&1; then
    ERRORS+=("tailscaled process is NOT running")
fi

# ---------------------------------------------------------------------------
# Check 2: tailscale binary is reachable and status works
# ---------------------------------------------------------------------------
if ! command -v tailscale &> /dev/null; then
    ERRORS+=("tailscale binary not found")
else
    # -----------------------------------------------------------------------
    # Check 3: Connected to tailnet
    # -----------------------------------------------------------------------
    if ! tailscale status --json 2>/dev/null | grep -q '"Online":true'; then
        # Fallback: check non-JSON status
        if ! tailscale status 2>/dev/null | grep -q "$(hostname 2>/dev/null || echo "")"; then
            ERRORS+=("Tailscale does not appear to be connected to the tailnet")
        fi
    fi

    # -----------------------------------------------------------------------
    # Check 4: Has IP address
    # -----------------------------------------------------------------------
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -z "${TS_IP}" ]; then
        ERRORS+=("No Tailscale IPv4 address assigned")
    fi

    # -----------------------------------------------------------------------
    # Check 5: Exit node enabled
    # -----------------------------------------------------------------------
    if ! tailscale status --json 2>/dev/null | grep -q '"ExitNode":true'; then
        # Check via self status
        SELF_STATUS=$(tailscale status 2>/dev/null | grep "$(hostname 2>/dev/null)" || true)
        if echo "${SELF_STATUS}" | grep -qv "exit node"; then
            ERRORS+=("Exit node advertisement may not be enabled (check tailscale status output)")
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "UNHEALTHY - ${#ERRORS[@]} issue(s) found:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  ✗ ${err}" >&2
    done

    # Debug info
    echo "---" >&2
    echo "tailscale status output:" >&2
    tailscale status 2>&1 || echo "  (unavailable)" >&2
    echo "---" >&2
    echo "tailscale ip output:" >&2
    tailscale ip 2>&1 || echo "  (unavailable)" >&2

    exit 1
fi

echo "HEALTHY - Tailscale exit node is running correctly"
echo "  IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
exit 0
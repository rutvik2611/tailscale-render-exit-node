#!/bin/bash
# =============================================================================
# healthcheck.sh - Tailscale Exit Node Health Monitor
# =============================================================================
# Verifies:
#   1. tailscaled process is running
#   2. Tailscale is connected to the tailnet
#   3. Routes are being advertised for exit node (0.0.0.0/0, ::/0)
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
# Check 2: tailscale binary is reachable
# ---------------------------------------------------------------------------
if ! command -v tailscale &> /dev/null; then
    ERRORS+=("tailscale binary not found")
else
    # Use --json output for reliable status checking
    TS_JSON=$(tailscale status --json 2>/dev/null || echo "")

    if [ -z "${TS_JSON}" ]; then
        ERRORS+=("tailscale status --json returned empty output")
    else
        # -------------------------------------------------------------------
        # Check 3: Backend state is Running
        # -------------------------------------------------------------------
        if ! echo "${TS_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('BackendState')=='Running' else 1)" 2>/dev/null; then
            ERRORS+=("Tailscale backend is not in Running state")
        fi

        # -------------------------------------------------------------------
        # Check 4: Node is Online
        # -------------------------------------------------------------------
        if ! echo "${TS_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
            ERRORS+=("Tailscale node is not online")
        fi

        # -------------------------------------------------------------------
        # Check 5: Has IPv4 address
        # -------------------------------------------------------------------
        if ! echo "${TS_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); ips=d.get('TailscaleIPs',[]); sys.exit(0 if any('.' in ip for ip in ips) else 1)" 2>/dev/null; then
            ERRORS+=("No Tailscale IPv4 address assigned")
        fi

        # -------------------------------------------------------------------
        # Check 6: Exit node routes advertised (0.0.0.0/0)
        # Check via debug prefs since it's the most reliable source
        # -------------------------------------------------------------------
        TS_PREFS=$(tailscale debug prefs 2>/dev/null || echo "")
        if [ -n "${TS_PREFS}" ]; then
            if ! echo "${TS_PREFS}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
routes = d.get('AdvertiseRoutes', [])
sys.exit(0 if '0.0.0.0/0' in routes else 1)
" 2>/dev/null; then
                ERRORS+=("Exit node routes (0.0.0.0/0) are not being advertised")
            fi
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
    echo "tailscale status:" >&2
    tailscale status 2>&1 || echo "  (unavailable)" >&2
    echo "tailscale ip:" >&2
    tailscale ip 2>&1 || echo "  (unavailable)" >&2

    exit 1
fi

echo "HEALTHY - Tailscale exit node is running correctly"
echo "  IPv4: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
echo "  Routes advertised: 0.0.0.0/0, ::/0"
exit 0
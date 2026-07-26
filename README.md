# Tailscale Render Exit Node

A secure, self-healing **Tailscale exit node** designed for containerized deployment on Render (or any Docker host). Routes all internet traffic from your Tailscale devices through this node, masking your IP and securing connections on untrusted networks.

---

## Architecture

```
┌──────────────────┐     ┌────────────────────────────┐
│  Your Device      │     │  Container (Render/Docker) │
│  (Laptop/Phone)   │     │                            │
│                   │     │  ┌──────────────────────┐  │
│  Tailscale Client │────▶│  │   start.sh            │  │
│  "Use Exit Node"  │     │  │   │                   │  │
│                   │     │  │   ▼                   │  │
│                   │     │  │  tailscaled (daemon)  │  │
│                   │     │  │   │                   │  │
│                   │     │  │   ▼                   │  │
│                   │     │  │  tailscale up         │  │
│                   │     │  │  --advertise-exit-node│  │
│                   │     │  └──────────────────────┘  │
│                   │     │                            │
│                   │     │  ┌──────────────────────┐  │
│                   │     │  │ healthcheck.sh        │  │
│                   │     │  │ (every 60s loop)      │  │
│                   │     │  └──────────────────────┘  │
└──────────────────┘     └────────────────────────────┘
         │                          │
         └─────────WireGuard────────┘
                    (encrypted)
```

### How it works

1. Container starts → `start.sh` launches **tailscaled** in userspace networking mode
2. Authenticates to your Tailnet using a **pre-shared auth key**
3. Advertises itself as an **exit node** to route traffic
4. Runs a **self-healing loop** — if Tailscale disconnects, it re-authenticates automatically
5. **healthcheck.sh** validates node status for monitoring

---

## Prerequisites

| Requirement | How to Get |
|------------|------------|
| **Tailscale account** | [Sign up (free)](https://login.tailscale.com) |
| **Tailscale auth key** | [Admin Console → Settings → Keys](https://login.tailscale.com/admin/settings/authkeys) |
| **Docker host** | Render, Fly.io, Oracle Cloud, AWS EC2, or any Linux server |
| **Domain (optional)** | For Tailscale Funnel/Serve features |
| **GitHub account** | To host and deploy from this repository |

---

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/rutvik2611/tailscale-render-exit-node.git
cd tailscale-render-exit-node

# Copy the example env file
cp auth/secrets.example.env .env
```

### 2. Set your Tailscale auth key

```bash
# Edit .env and replace the placeholder
# TAILSCALE_AUTHKEY=tskey-auth-xxxxxxxxxxxxxxxxx
```

### 3. Run locally with Docker

```bash
# Build the image
docker build -t tailscale-exit-node .

# Run with required capabilities
docker run -d \
  --name tailscale-exit-node \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --env-file .env \
  tailscale-exit-node
```

### 4. Approve the exit node in Tailscale Admin

1. Go to [Tailscale Admin Console → Machines](https://login.tailscale.com/admin/machines)
2. Find your new node (`render-exit-node`)
3. Click the **...** menu → **Edit route settings**
4. Toggle **"Use as exit node"** → **Approve**

### 5. Use the exit node from your devices

#### macOS / Windows / Linux (Tailscale GUI)
- Click the Tailscale icon → **Exit node** → select `render-exit-node`

#### iOS / Android
- Open Tailscale → **Exit node** → select `render-exit-node`

#### CLI
```bash
tailscale set --exit-node=render-exit-node
```

---

## Render Deployment

### Method 1: Blueprint (render.yaml)

1. Push this repo to GitHub
2. Go to [Render Dashboard](https://dashboard.render.com)
3. Click **New +** → **Blueprint**
4. Connect your GitHub repository
5. Render reads `render.yaml` and creates the service
6. **Set `TAILSCALE_AUTHKEY`** in Render Dashboard → Environment

### Method 2: Manual Docker Service

1. In Render Dashboard → **New +** → **Web Service**
2. Connect your GitHub repo
3. Set:
   - **Name:** `tailscale-exit-node`
   - **Environment:** `Docker`
   - **Plan:** Starter (minimum — free tier **does not** support `NET_ADMIN`)
4. Add environment variables:
   - `TAILSCALE_AUTHKEY` (your actual key)
   - `HOSTNAME` = `render-exit-node`
5. Deploy

### ⚠️ Render Free Tier Limitations

| Feature | Free Tier | Starter+ |
|---------|-----------|----------|
| Docker support | ✅ | ✅ |
| `NET_ADMIN` capability | ❌ | ✅ |
| `SYS_MODULE` capability | ❌ | ✅ |
| Persistent disk | ❌ (ephemeral) | ❌ (ephemeral) |
| Always-on | ❌ (spins down) | ✅ |
| Cost | $0/mo | ~$7/mo |

**Conclusion:** Render free tier **cannot** run Tailscale as an exit node because it lacks `NET_ADMIN` capability support. You need at least the **Starter** plan ($7/mo).

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TAILSCALE_AUTHKEY` | ✅ | Tailscale auth key from admin console |
| `HOSTNAME` | ❌ | Node name in tailnet (default: `render-exit-node`) |
| `TAILSCALE_EXTRA_ARGS` | ❌ | Extra `tailscale up` flags |

### Auth Key Best Practices

- ✅ Generate a **reusable** key (same key works after container recycle)
- ✅ Use **ephemeral** mode (node auto-leaves tailnet when container stops)
- ✅ **Tag** the key (e.g. `tag:render-exit`) for ACL-based access control
- ❌ Never commit the key to Git
- ❌ Never log the full key

---

## Security

### Secret Handling

```
tailscale-render-exit-node/
├── auth/              ← Authentication files (NEVER commit real secrets!)
│   ├── .gitkeep
│   ├── README.md
│   └── secrets.example.env  ← Placeholders only
├── .env.example       ← Public template
└── .gitignore         ← Excludes `auth/*`, `.env`, `*.key`
```

**Rules enforced by `.gitignore`:**
- `auth/*` is excluded (except `.gitkeep` and `README.md`)
- `.env` and `.env.*` are excluded
- `*.key`, `*.token`, `*.secret` are excluded
- No secrets can be committed to version control

### Key Rotation

1. Generate a new auth key in Tailscale Admin Console
2. Update `TAILSCALE_AUTHKEY` in Render Dashboard
3. Restart the service
4. Revoke the old key in Tailscale Admin Console

### Least Privilege

- Container runs as non-root (after initial setup)
- Auth key scoped to specific node tags
- ACL rules in Tailscale control what this node can do
- No unnecessary ports exposed

---

## Health Monitoring

### Built-in health check

```bash
# Run inside the container
docker exec tailscale-exit-node /usr/local/bin/healthcheck.sh
```

Checks:
- ✅ `tailscaled` process is running
- ✅ Tailscale is connected to the tailnet
- ✅ Has a valid IPv4 address
- ✅ Exit node advertisement is active

### Render health checks

Render automatically runs HTTP health checks. The container's self-healing loop:
- Reports status every 60 seconds
- Automatically reconnects if Tailscale disconnects
- Logs warnings on connection issues

---

## Troubleshooting

### Authentication Failures

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `tailscale up` fails | Expired auth key | Generate a new key |
| Node shows as offline | Key already used (non-reusable) | Use a reusable key |
| "No capabilities" error | Missing `NET_ADMIN` | Add to docker run or Render plan |

### Container Crashes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Container loops on start | Missing `TAILSCALE_AUTHKEY` | Set the env var |
| Exit code 137 (OOM) | Insufficient memory | Upgrade Render plan |
| Permission denied | Missing capabilities | Check `--cap-add=NET_ADMIN` |

### Tailscale Connection Issues

```bash
# Check container logs
docker logs tailscale-exit-node

# Check Tailscale status
docker exec tailscale-exit-node tailscale status

# Check assigned IP
docker exec tailscale-exit-node tailscale ip -4

# View connection info
docker exec tailscale-exit-node tailscale netcheck
```

### Firewall / ACL Issues

If the node connects but devices can't use it as exit node:
1. Approve the exit node in [Tailscale Admin → Machines](https://login.tailscale.com/admin/machines)
2. Check ACL rules allow traffic routing
3. Verify the node tag is correct in ACL policy

---

## Free Alternatives to Render

Since Render free tier lacks `NET_ADMIN` support, consider these:

| Platform | Free Tier | `NET_ADMIN` | Exit Node Possible |
|----------|-----------|-------------|-------------------|
| **Oracle Cloud Free Tier** | 4 ARM cores, 24GB RAM | ✅ via custom boot script | ✅ **Yes** |
| **Fly.io** | 3 shared VMs, 256MB each | ✅ | ✅ **Yes** |
| **AWS EC2 Free Tier** | t2.micro, 750hrs/month | ✅ | ✅ **Yes** |
| **GitHub Codespaces** | 120 core-hours/month | ✅ | ✅ **Yes** |
| **Home Server** | Unlimited (power cost) | ✅ | ✅ **Yes** |
| **Render Free** | 512MB RAM, 1 CPU | ❌ | ❌ **No** |

---

## Self-Healing

The container automatically:
- **Reconnects** if Tailscale daemon crashes → restart loop
- **Re-authenticates** if connection is lost → health monitor re-runs `tailscale up`
- **Logs** all failures with timestamps
- **Exits cleanly** with `SIGTERM` handling (logs out of tailnet)

For full HA, run multiple instances and configure failover via Tailscale ACLs.

---

## Development

```bash
# Lint shell scripts
shellcheck start.sh scripts/healthcheck.sh

# Build locally
docker build -t tailscale-exit-node .

# Run with test mode
docker run -it --rm \
  --cap-add=NET_ADMIN \
  --env TAILSCALE_AUTHKEY=tskey-auth-... \
  --name test-exit-node \
  tailscale-exit-node
```

---

## License

MIT

---

## Repository

[github.com/rutvik2611/tailscale-render-exit-node](https://github.com/rutvik2611/tailscale-render-exit-node)
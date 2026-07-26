# Authentication Directory

This directory is for authentication-related configuration ONLY.

## Security Rules

- **NEVER** commit real secrets to version control
- **NEVER** hardcode API keys or tokens in source files
- **NEVER** print secrets in logs
- **NEVER** expose credentials in GitHub
- **ALWAYS** use environment variables or a secure secrets manager

## Files

| File | Purpose |
|------|---------|
| `.gitkeep` | Ensures the auth directory exists in Git |
| `secrets.example.env` | Template with placeholder values only |

## Production Secrets

For production deployments, set secrets via:

1. **Render Dashboard** → Environment Variables (preferred)
2. A secure `.env` file outside version control
3. An external secrets manager (HashiCorp Vault, AWS Secrets Manager, etc.)

## Environment Variables Required

````
TAILSCALE_AUTHKEY=  # Required. Obtain from Tailscale Admin Console
HOSTNAME=           # Optional. Defaults to hostname if not set
````
# AltoSec Stress Tester — Server Setup Script

> **One command** to provision any Linux server: installs Docker, registers a GitHub Actions self-hosted runner, and connects it to the main repo so every merge to `main` automatically deploys.

Environment variables are stored as **GitHub Secrets** — no `.env` file is kept on disk. The workflow writes a fresh `.env` from secrets on every deploy.

---

## How It Works

```
Your Laptop                GitHub                     Your Server
──────────               ──────────                  ──────────────
 git push main  ──────►  workflow triggers  ──────►  self-hosted runner
                          writes .env                 from GitHub Secrets
                                                      docker compose up
```

1. **`setup.sh`** — run **once** on a new server to install Docker and register the server as a GitHub Actions self-hosted runner.
2. **GitHub Secrets** — store all environment variables (DB password, JWT secret, ports) in the repo. No secrets on disk.
3. **GitHub Actions workflow** (`production.yml`) — on every push to `main`, writes `.env` from secrets, then rebuilds and restarts containers.

---

## Requirements

| Requirement | Notes |
|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 (amd64 or arm64) | Debian-based distros also work |
| Root access | Required for Docker install and systemd registration |
| Outbound internet access | To download Docker and the runner binary |
| A GitHub Actions **runner registration token** | See step 1 below |

---

## Setup (3 steps)

### Step 1 — Run setup.sh on the server

Get a runner registration token first:
> GitHub → main repo → **Settings** → **Actions** → **Runners** → **New self-hosted runner** → copy the `--token` value (valid for 1 hour)

SSH into the server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/altosecteam-org/AltoSec-Stress-Tester-Script/main/setup.sh \
  | sudo bash -s -- --runner-token YOUR_REGISTRATION_TOKEN
```

The script installs Docker, clones the app repo to `/opt/altosec`, and registers this server as a GitHub Actions self-hosted runner (systemd service, starts on reboot).

### Step 2 — Add GitHub Secrets

Go to: **GitHub → main repo → Settings → Secrets and variables → Actions → New repository secret**

Add these 5 secrets:

| Secret name | Example value | Description |
|---|---|---|
| `SERVER_DOMAIN` | `192.74.225.3` | Server IP or domain |
| `BACKEND_PORT` | `8080` | Backend API port |
| `FRONTEND_PORT` | `3000` | Frontend HTTP port |
| `DB_PASSWORD` | *(random strong password)* | PostgreSQL password |
| `JWT_SECRET` | *(random 32+ char string)* | JWT signing key |

To generate strong random values:
```bash
# DB_PASSWORD
openssl rand -hex 16

# JWT_SECRET
openssl rand -hex 32
```

### Step 3 — Push to main to deploy

Merge or push anything to `main`. The workflow will:
1. Write `.env` on the server from GitHub Secrets
2. Pull the latest code
3. Run `docker compose -f docker-compose.prod.yml up -d --build`

Check GitHub → **Actions** tab to watch the deploy.

---

## What setup.sh Does

```
install git, curl, jq
install Docker (via get.docker.com)
clone main repo → /opt/altosec
download GitHub Actions runner binary
configure runner (self-hosted, linux, production)
install runner as systemd service
start runner
```

No `.env` is written. No initial deploy is run. Everything is driven by the GitHub workflow.

---

## Options

```
Usage:
  sudo bash setup.sh [OPTIONS]

Required:
  --runner-token   GitHub Actions runner registration token

Optional:
  --deploy-dir     App directory             (default: /opt/altosec)
  --runner-dir     Runner install directory  (default: /opt/actions-runner)
  --runner-name    Runner label/name         (default: server hostname)
  --runner-version GitHub runner version     (default: 2.321.0)
  --repo-url       Main repo to clone        (default: https://github.com/altosecteam-org/Altosec-stress-tester)
  --access-token   GitHub PAT for private repo clone
```

### Multiple servers

Each server needs its own runner registration token (single-use, 1-hour expiry):

```bash
# Server 1
sudo bash setup.sh --runner-token TOKEN1 --runner-name prod-server-1

# Server 2
sudo bash setup.sh --runner-token TOKEN2 --runner-name prod-server-2
```

All registered runners will receive the deploy job. To target a specific server, add a unique label and update `runs-on` in the workflow.

---

## Managing the Runner

```bash
# Check status
sudo systemctl status actions.runner.*

# Restart
sudo systemctl restart actions.runner.*

# View live logs
sudo journalctl -u actions.runner.* -f
```

---

## Troubleshooting

### Runner shows "Offline" in GitHub
```bash
sudo systemctl restart actions.runner.*
sudo journalctl -u actions.runner.* -n 50
```

### "Token has already been used"
Runner tokens expire after 1 hour and are single-use. Get a new token and re-run setup.sh.

### "No runner matching labels [self-hosted, linux, production]"
Runner is offline or not registered. Check `systemctl status` and GitHub → Settings → Actions → Runners.

### Docker permission denied
```bash
sudo usermod -aG docker runner
sudo systemctl restart actions.runner.*
```

### Workflow fails: secrets are empty
Confirm all 5 secrets are set in GitHub → Settings → Secrets → Actions. Secret names are case-sensitive.

---

## Security Notes

- No credentials are stored on disk between deploys. The `.env` is written at the start of each workflow run and contains only what GitHub Secrets holds.
- The runner runs as the `runner` user (not root), with Docker group access.
- Registration tokens are single-use and expire in 1 hour.

---

## License

MIT

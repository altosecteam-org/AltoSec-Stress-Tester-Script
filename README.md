# AltoSec Stress Tester — Server Setup Script

> **One command** to provision any Linux server: installs Docker, deploys the application, and registers a GitHub Actions self-hosted runner so every merge to `main` automatically redeploys.

---

## How It Works

```
Your Laptop                GitHub                  Your Server
──────────               ──────────               ──────────────
 git push main  ──────►  workflow triggers  ──►  self-hosted runner
                                                  runs deploy.sh
                                                  docker compose up
```

1. **`setup.sh`** — run once on a new server; it installs Docker, clones the app, writes `.env`, does the first deploy, and registers this server as a GitHub Actions runner.
2. **GitHub Actions workflow** (`production.yml` in the main repo) — on every push to `main`, the workflow is dispatched and the registered runner pulls the latest code and rebuilds the containers.

---

## Requirements

| Requirement | Notes |
|---|---|
| Ubuntu 20.04 / 22.04 / 24.04 (amd64 or arm64) | Debian-based distros also work |
| Root access (or `sudo`) | Required for Docker install and systemd registration |
| Outbound internet access | To download Docker and the runner binary |
| A GitHub Actions **runner registration token** | See [How to get a token](#how-to-get-a-runner-registration-token) |

---

## Quick Start

### 1. Get a runner registration token

1. Go to the **main repo** → **Settings** → **Actions** → **Runners**
2. Click **New self-hosted runner**
3. Copy the token shown in the `--token` line (looks like `ABCDEFGH1234...`, valid for **1 hour**)

### 2. Run setup.sh on the server

SSH into your server, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/altosecteam-org/AltoSec-Stress-Tester-Script/main/setup.sh \
  | sudo bash -s -- \
      --domain YOUR_SERVER_IP_OR_DOMAIN \
      --runner-token YOUR_REGISTRATION_TOKEN
```

That's it. The script will:
- Install `git`, `curl`, `jq`, `openssl`
- Install **Docker** (via `get.docker.com`)
- Clone the main application repo to `/opt/altosec`
- Generate a random DB password and JWT secret, write `/opt/altosec/.env`
- Run `docker compose -f docker-compose.prod.yml up -d --build` (first deploy)
- Download, configure, and register the GitHub Actions runner
- Install the runner as a **systemd service** (auto-starts on reboot)

### 3. Verify

Open GitHub → repo → **Settings** → **Actions** → **Runners**.  
Your server should appear with a green **Idle** badge.

```
✓ your-server-hostname    self-hosted, linux, production    Idle
```

### 4. Auto-deploy on merge

From now on, every merge (or direct push) to `main` triggers the workflow and your server redeploys automatically — no SSH needed.

---

## All Options

```
Usage:
  sudo bash setup.sh [OPTIONS]

Required:
  --domain         Server public IP or domain  (e.g. 192.74.225.3 or app.example.com)
  --runner-token   GitHub Actions runner registration token

Optional:
  --backend-port   Backend API port          (default: 8080)
  --frontend-port  Frontend HTTP port        (default: 3000)
  --db-password    PostgreSQL password       (default: auto-generated)
  --jwt-secret     JWT signing secret        (default: auto-generated)
  --access-token   GitHub PAT for private repo clone (omit for public repos)
  --deploy-dir     Application directory     (default: /opt/altosec)
  --runner-dir     GitHub Actions runner dir (default: /opt/actions-runner)
  --runner-name    Runner name in GitHub UI  (default: server hostname)
  --runner-version GitHub runner version     (default: 2.321.0)
  --repo-url       Main repo to clone        (default: https://github.com/altosecteam-org/Altosec-stress-tester)
```

### Examples

**Custom ports:**
```bash
sudo bash setup.sh \
  --domain 192.74.225.3 \
  --runner-token ABCD1234 \
  --backend-port 9000 \
  --frontend-port 4000
```

**Private repo with PAT:**
```bash
sudo bash setup.sh \
  --domain my.server.com \
  --runner-token ABCD1234 \
  --access-token ghp_xxxxxxxxxxxxxxxxxxxx
```

**Multiple servers (different runner names):**
```bash
# Server 1
sudo bash setup.sh --domain 10.0.0.1 --runner-token TOKEN1 --runner-name prod-server-1

# Server 2
sudo bash setup.sh --domain 10.0.0.2 --runner-token TOKEN2 --runner-name prod-server-2
```
> Each server needs its **own** registration token.

---

## What Gets Installed

| Component | Version | Location |
|---|---|---|
| Docker Engine | latest stable | system |
| docker compose | v2 (bundled) | system |
| GitHub Actions runner | 2.321.0 | `/opt/actions-runner` |
| App (cloned repo) | latest `main` | `/opt/altosec` |
| App config | — | `/opt/altosec/.env` |

---

## Generated Files

| File | Description |
|---|---|
| `/opt/altosec/.env` | Environment variables (DB password, JWT secret, ports). **Not committed to git.** |
| `/opt/altosec/.env.production` | Copy of `.env` used by the workflow on each deploy. |

---

## Managing the Runner Service

The runner is installed as a `systemd` service. Useful commands:

```bash
# Check status
sudo systemctl status actions.runner.*

# Restart
sudo systemctl restart actions.runner.*

# View logs
sudo journalctl -u actions.runner.* -f

# Stop
sudo systemctl stop actions.runner.*
```

---

## Re-running setup.sh

`setup.sh` is **idempotent** for most steps:
- Docker: skipped if already installed
- Repo: skipped if `/opt/altosec/.git` exists
- `.env`: skipped if file exists (delete it to regenerate)
- Runner: re-registers (existing runner is replaced with `--replace`)

---

## Troubleshooting

### Runner shows "Offline" in GitHub

```bash
# Restart the service
sudo systemctl restart actions.runner.*

# Check logs
sudo journalctl -u actions.runner.* -n 50
```

### "Token has already been used" error

Runner registration tokens expire after **1 hour** and can only be used once. Get a new token from GitHub and re-run setup.sh.

### Docker permission denied

```bash
# The 'runner' user may not be in the docker group yet
sudo usermod -aG docker runner
sudo systemctl restart actions.runner.*
```

### Workflow fails: "No runner matching labels [self-hosted, linux, production]"

The runner is either offline or not registered. Check:
1. `sudo systemctl status actions.runner.*` — must be `active (running)`
2. GitHub → Settings → Actions → Runners — must show **Idle**

---

## Security Notes

- The `.env` file contains database credentials and JWT secrets. It is excluded from git via `.gitignore`.
- The runner runs as the dedicated `runner` user (not root), with access to Docker via group membership.
- Runner registration tokens are single-use and expire after 1 hour.
- For production, use a domain with HTTPS (the app includes a reverse-proxy config for this).

---

## License

MIT

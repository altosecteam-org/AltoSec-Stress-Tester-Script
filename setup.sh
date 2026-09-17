#!/usr/bin/env bash
# setup.sh — Provision a production server for Altosec Stress Tester
#
# Installs Docker, registers a GitHub Actions self-hosted runner, and writes
# the persistent .env so every future push to main auto-deploys to this server.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/altosecteam-org/AltoSec-Stress-Tester-Script/main/setup.sh \
#     | sudo bash -s -- --domain <IP_OR_DOMAIN> --runner-token <TOKEN> [options]
#
# Required:
#   --domain         Server public IP or domain (e.g. 192.74.225.3 or app.example.com)
#   --runner-token   GitHub Actions runner registration token
#                    → GitHub repo → Settings → Actions → Runners → New self-hosted runner → copy token
#
# Optional:
#   --backend-port   Backend API port          (default: 8080)
#   --frontend-port  Frontend port             (default: 3000)
#   --db-password    Postgres password         (default: random)
#   --jwt-secret     JWT signing secret        (default: random)
#   --access-token   GitHub PAT for private repo clone (omit for public repos)
#   --deploy-dir     App directory             (default: /opt/altosec)
#   --runner-dir     Runner install directory  (default: /opt/actions-runner)
#   --runner-name    Runner label/name         (default: hostname)
#   --runner-version GitHub Actions runner ver (default: 2.321.0)
#   --repo-url       Repo to clone             (default: https://github.com/altosecteam-org/Altosec-stress-tester)

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/altosecteam-org/Altosec-stress-tester"
DEPLOY_DIR="/opt/altosec"
RUNNER_DIR="/opt/actions-runner"
RUNNER_VERSION="2.321.0"
BACKEND_PORT="8080"
FRONTEND_PORT="3000"
DB_PASSWORD=""
JWT_SECRET=""
ACCESS_TOKEN=""
RUNNER_TOKEN=""
DOMAIN=""
RUNNER_NAME="${HOSTNAME:-$(hostname)}"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)         DOMAIN="$2";         shift 2 ;;
        --runner-token)   RUNNER_TOKEN="$2";   shift 2 ;;
        --backend-port)   BACKEND_PORT="$2";   shift 2 ;;
        --frontend-port)  FRONTEND_PORT="$2";  shift 2 ;;
        --db-password)    DB_PASSWORD="$2";    shift 2 ;;
        --jwt-secret)     JWT_SECRET="$2";     shift 2 ;;
        --access-token)   ACCESS_TOKEN="$2";   shift 2 ;;
        --deploy-dir)     DEPLOY_DIR="$2";     shift 2 ;;
        --runner-dir)     RUNNER_DIR="$2";     shift 2 ;;
        --runner-name)    RUNNER_NAME="$2";    shift 2 ;;
        --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
        --repo-url)       REPO_URL="$2";       shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[setup]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[setup] ✓\033[0m $*"; }
err()  { echo -e "\033[1;31m[setup] ERROR:\033[0m $*" >&2; exit 1; }
warn() { echo -e "\033[1;33m[setup] WARN:\033[0m $*"; }

# ─── Validation ───────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || err "Run as root: sudo bash setup.sh ..."
[[ -z "$DOMAIN" ]]       && err "--domain is required"
[[ -z "$RUNNER_TOKEN" ]] && err "--runner-token is required"

# Generate secrets if not provided
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="$(openssl rand -hex 16)"
[[ -z "$JWT_SECRET"  ]] && JWT_SECRET="$(openssl rand -hex 32)"

# ─── Install dependencies ─────────────────────────────────────────────────────
install_deps() {
    log "Installing system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local pkgs=()
    command -v git    &>/dev/null || pkgs+=(git)
    command -v curl   &>/dev/null || pkgs+=(curl)
    command -v jq     &>/dev/null || pkgs+=(jq)
    command -v openssl &>/dev/null || pkgs+=(openssl)

    [[ ${#pkgs[@]} -gt 0 ]] && apt-get install -y -qq "${pkgs[@]}"
    ok "System dependencies ready"
}

install_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker already installed: $(docker --version)"
        return
    fi
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed: $(docker --version)"
}

# ─── Clone or update repo ─────────────────────────────────────────────────────
setup_repo() {
    # Build clone URL (embed PAT for private repos)
    local clone_url="$REPO_URL"
    if [[ -n "$ACCESS_TOKEN" ]]; then
        clone_url="${REPO_URL/https:\/\//https://$ACCESS_TOKEN@}"
    fi

    if [[ -d "$DEPLOY_DIR/.git" ]]; then
        ok "Repo already present at $DEPLOY_DIR"
        return
    fi

    if [[ -d "$DEPLOY_DIR" ]] && [[ -n "$(ls -A "$DEPLOY_DIR" 2>/dev/null)" ]]; then
        warn "$DEPLOY_DIR exists but is not a git repo — moving to ${DEPLOY_DIR}.bak"
        mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak"
    fi

    log "Cloning repo → $DEPLOY_DIR"
    git clone "$clone_url" "$DEPLOY_DIR"
    ok "Repo cloned"
}

# ─── Write persistent .env ────────────────────────────────────────────────────
write_env() {
    local env_file="$DEPLOY_DIR/.env"

    if [[ -f "$env_file" ]]; then
        ok ".env already exists — skipping (delete to regenerate)"
        return
    fi

    log "Writing $env_file"
    cat > "$env_file" << EOF
# Generated by setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do NOT commit this file to git.

SERVER_DOMAIN=${DOMAIN}
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}

DB_USER=altosec
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=altosec
DB_HOST=db
DB_PORT=5432

JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY=24h

AGENT_SOURCE_DIR=agent-src
AGENT_ARTIFACT_DIR=agent-artifacts
EOF

    # .env.production is what the workflow copies on each deploy
    cp "$env_file" "$DEPLOY_DIR/.env.production"
    ok ".env and .env.production written"
}

# ─── Initial docker compose deploy ───────────────────────────────────────────
initial_deploy() {
    log "Running initial docker compose build & up..."
    cd "$DEPLOY_DIR"
    docker compose -f docker-compose.prod.yml up -d --build
    ok "Initial deploy complete — stack is up"
}

# ─── Install GitHub Actions self-hosted runner ───────────────────────────────
install_runner() {
    log "Installing GitHub Actions runner v${RUNNER_VERSION}..."

    # Create a dedicated runner user
    if ! id -u runner &>/dev/null 2>&1; then
        useradd -m -s /bin/bash runner
        ok "Created user 'runner'"
    fi
    # Allow runner to use docker without sudo
    usermod -aG docker runner

    mkdir -p "$RUNNER_DIR"
    chown runner:runner "$RUNNER_DIR"

    # Detect architecture
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x64"   ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="arm"   ;;
        *) err "Unsupported architecture: $arch" ;;
    esac

    local tarball="actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"
    local dl_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"

    if [[ ! -f "$RUNNER_DIR/config.sh" ]]; then
        log "Downloading runner ($arch)..."
        curl -fsSL -o "/tmp/${tarball}" "$dl_url"
        tar -xzf "/tmp/${tarball}" -C "$RUNNER_DIR"
        rm "/tmp/${tarball}"
    fi

    # Give runner user ownership
    chown -R runner:runner "$RUNNER_DIR"

    # Configure (replace if already registered)
    log "Configuring runner as '${RUNNER_NAME}'..."
    sudo -u runner bash -c "
        cd ${RUNNER_DIR}
        ./config.sh \
            --url ${REPO_URL} \
            --token ${RUNNER_TOKEN} \
            --name ${RUNNER_NAME} \
            --labels self-hosted,linux,production \
            --work /tmp/runner-work \
            --unattended \
            --replace
    "
    ok "Runner configured"

    # Install & start as systemd service
    log "Installing runner as systemd service..."
    cd "$RUNNER_DIR"
    ./svc.sh install runner
    ./svc.sh start
    ok "Runner service started"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "\033[1;32m╔══════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;32m║     Altosec Stress Tester — Setup Complete   ║\033[0m"
    echo -e "\033[1;32m╚══════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "  \033[1mFrontend:\033[0m  http://${DOMAIN}:${FRONTEND_PORT}"
    echo -e "  \033[1mAPI:\033[0m       http://${DOMAIN}:${BACKEND_PORT}/api/v1/health"
    echo -e "  \033[1mRunner:\033[0m    ${RUNNER_NAME}  [self-hosted, linux, production]"
    echo ""
    echo -e "  \033[1mNext steps:\033[0m"
    echo "  1. Verify runner is online:"
    echo "     GitHub → repo → Settings → Actions → Runners"
    echo "  2. Merge any PR to main — this server auto-deploys"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo ""
log "=== Altosec Stress Tester — Server Provisioning ==="
log "Domain        : $DOMAIN"
log "Backend port  : $BACKEND_PORT"
log "Frontend port : $FRONTEND_PORT"
log "Deploy dir    : $DEPLOY_DIR"
log "Runner name   : $RUNNER_NAME"
echo ""

install_deps
install_docker
setup_repo
write_env
initial_deploy
install_runner
print_summary

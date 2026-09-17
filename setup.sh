#!/usr/bin/env bash
# setup.sh — Provision a production server for Altosec Stress Tester
#
# Installs Docker, nginx (host), Let's Encrypt SSL, and registers a
# GitHub Actions self-hosted runner. All env vars are GitHub Secrets.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/altosecteam-org/AltoSec-Stress-Tester-Script/main/setup.sh \
#     | sudo bash -s -- --domain <DOMAIN> --runner-token <TOKEN> [options]
#
# Required:
#   --domain         Server domain (must have DNS pointing here, e.g. app.example.com)
#   --runner-token   GitHub Actions runner registration token
#                    → GitHub repo → Settings → Actions → Runners → New self-hosted runner
#
# Optional:
#   --email          Email for Let's Encrypt expiry notices (default: admin@<domain>)
#   --backend-port   Backend API port  (default: 8080)
#   --frontend-port  Frontend port     (default: 3000)
#   --runner-dir     Runner directory  (default: /opt/actions-runner)
#   --runner-name    Runner name       (default: hostname)
#   --runner-version GitHub runner ver (default: 2.321.0)
#   --repo-url       Main repo URL     (default: https://github.com/altosecteam-org/Altosec-stress-tester)
#   --skip-ssl       Skip SSL setup (useful if domain DNS is not ready yet)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/altosecteam-org/Altosec-stress-tester"
RUNNER_DIR="/opt/actions-runner"
RUNNER_VERSION="2.321.0"
RUNNER_TOKEN=""
RUNNER_NAME="${HOSTNAME:-$(hostname)}"
DOMAIN=""
EMAIL=""
BACKEND_PORT="8080"
FRONTEND_PORT="3000"
SKIP_SSL="false"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)         DOMAIN="$2";         shift 2 ;;
        --runner-token)   RUNNER_TOKEN="$2";   shift 2 ;;
        --email)          EMAIL="$2";          shift 2 ;;
        --backend-port)   BACKEND_PORT="$2";   shift 2 ;;
        --frontend-port)  FRONTEND_PORT="$2";  shift 2 ;;
        --runner-dir)     RUNNER_DIR="$2";     shift 2 ;;
        --runner-name)    RUNNER_NAME="$2";    shift 2 ;;
        --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
        --repo-url)       REPO_URL="$2";       shift 2 ;;
        --skip-ssl)       SKIP_SSL="true";     shift ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo -e "\033[1;34m[setup]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[setup] ✓\033[0m $*"; }
err()  { echo -e "\033[1;31m[setup] ERROR:\033[0m $*" >&2; exit 1; }
warn() { echo -e "\033[1;33m[setup] WARN:\033[0m $*"; }

# ─── Validation ───────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]]   || err "Run as root: sudo bash setup.sh ..."
[[ -z "$RUNNER_TOKEN" ]] && err "--runner-token is required"
[[ -z "$DOMAIN" ]]       && err "--domain is required"

[[ -z "$EMAIL" ]] && EMAIL="admin@${DOMAIN}"

# ─── Install system dependencies ──────────────────────────────────────────────
install_deps() {
    log "Installing system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # libicu: required by GitHub Actions runner (.NET Core 6.0)
    apt-get install -y -qq git curl jq libicu-dev nginx certbot python3-certbot-nginx
    ok "System dependencies ready"
}

# ─── Install Docker ───────────────────────────────────────────────────────────
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

# ─── Configure nginx reverse proxy ────────────────────────────────────────────
setup_nginx() {
    log "Configuring nginx reverse proxy..."

    # Temporary HTTP-only config so certbot can complete the ACME challenge
    cat > /etc/nginx/sites-available/altosec << EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

    ln -sf /etc/nginx/sites-available/altosec /etc/nginx/sites-enabled/altosec
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    ok "nginx HTTP config active"
}

# ─── Issue SSL certificate ────────────────────────────────────────────────────
issue_ssl() {
    if [[ "$SKIP_SSL" == "true" ]]; then
        warn "Skipping SSL setup (--skip-ssl passed)"
        return
    fi

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        ok "SSL certificate already exists for ${DOMAIN}"
    else
        log "Issuing SSL certificate for ${DOMAIN}..."
        certbot certonly --nginx \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN"
        ok "SSL certificate issued"
    fi

    # Write full HTTPS nginx config
    cat > /etc/nginx/sites-available/altosec << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # SSE (Server-Sent Events) — disable buffering
    proxy_buffering off;
    proxy_read_timeout 3600s;

    location /api/ {
        proxy_pass         http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Connection '';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
    }

    location / {
        proxy_pass       http://127.0.0.1:${FRONTEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

    nginx -t
    systemctl reload nginx
    ok "nginx HTTPS config active"

    # Auto-renewal via cron (certbot installs its own timer too, but explicit is safer)
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --nginx && systemctl reload nginx") | crontab -
        ok "certbot auto-renewal cron installed (daily at 03:00)"
    fi
}

# ─── Register GitHub Actions self-hosted runner ───────────────────────────────
install_runner() {
    log "Installing GitHub Actions runner v${RUNNER_VERSION}..."

    if ! id -u runner &>/dev/null 2>&1; then
        useradd -m -s /bin/bash runner
        ok "Created user 'runner'"
    fi
    usermod -aG docker runner

    mkdir -p "$RUNNER_DIR"
    chown runner:runner "$RUNNER_DIR"

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

    chown -R runner:runner "$RUNNER_DIR"

    log "Installing runner .NET Core 6.0 dependencies..."
    bash "$RUNNER_DIR/bin/installdependencies.sh" || true
    ok "Runner dependencies installed"

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

    log "Installing runner as systemd service..."
    cd "$RUNNER_DIR"
    ./svc.sh install runner
    ./svc.sh start
    ok "Runner service started"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "\033[1;32m╔══════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;32m║        Altosec Stress Tester — Setup Complete                ║\033[0m"
    echo -e "\033[1;32m╚══════════════════════════════════════════════════════════════╝\033[0m"
    echo ""
    if [[ "$SKIP_SSL" == "false" ]]; then
        echo -e "  \033[1mURL:\033[0m     https://${DOMAIN}"
    fi
    echo -e "  \033[1mRunner:\033[0m  ${RUNNER_NAME}  [self-hosted, linux, production]"
    echo ""
    echo -e "  \033[1;33mNext: add these GitHub Secrets to the main repo:\033[0m"
    echo "  GitHub → repo → Settings → Secrets and variables → Actions"
    echo ""
    echo "    SERVER_DOMAIN    → ${DOMAIN}"
    echo "    BACKEND_PORT     → ${BACKEND_PORT}"
    echo "    FRONTEND_PORT    → ${FRONTEND_PORT}"
    echo "    DB_PASSWORD      → \$(openssl rand -hex 16)"
    echo "    JWT_SECRET       → \$(openssl rand -hex 32)"
    echo ""
    echo "  Then push or merge to main — the first deploy will run automatically."
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo ""
log "=== Altosec Stress Tester — Server Provisioning ==="
log "Domain      : $DOMAIN"
log "Runner name : $RUNNER_NAME"
echo ""

install_deps
install_docker
setup_nginx
issue_ssl
install_runner
print_summary

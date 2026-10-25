#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time server bootstrap for the Notes API host (Amazon Linux 2023).
#
# Run as root, once, on a freshly launched instance:
#   sudo ./bootstrap-server.sh --repo-dir /opt/notes-api/src
#
# Installs Docker + Nginx, enables them at boot, lays out the directory tree,
# and installs the reverse-proxy configuration. It is idempotent: running it
# again only re-installs the configuration files.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="/opt/notes-api"

log() { printf '[bootstrap] %s\n' "$*"; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "Unknown argument: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "must run as root (use sudo)"

# --- 1. Packages ------------------------------------------------------------
if command -v dnf >/dev/null; then
  PKG=dnf
elif command -v apt-get >/dev/null; then
  PKG=apt-get
else
  die "unsupported distribution (need dnf or apt-get)"
fi

if ! command -v docker >/dev/null; then
  log "Installing Docker..."
  if [[ "$PKG" == "dnf" ]]; then
    dnf install -y docker >/dev/null
  else
    apt-get update -qq && apt-get install -y docker.io >/dev/null
  fi
else
  log "Docker already installed: $(docker --version)"
fi

if ! command -v nginx >/dev/null; then
  log "Installing Nginx..."
  if [[ "$PKG" == "dnf" ]]; then
    dnf install -y nginx >/dev/null
  else
    apt-get update -qq && apt-get install -y nginx >/dev/null
  fi
else
  log "Nginx already installed: $(nginx -v 2>&1)"
fi

# --- 2. Services (start automatically after reboot) ------------------------
log "Enabling Docker and Nginx at boot..."
systemctl enable --now docker >/dev/null 2>&1
systemctl enable nginx >/dev/null 2>&1

# --- 3. Directory layout ---------------------------------------------------
log "Creating ${INSTALL_ROOT}..."
mkdir -p "${INSTALL_ROOT}/state" "${INSTALL_ROOT}/releases"

# --- 4. Reverse-proxy configuration ---------------------------------------
if [[ -f "${REPO_DIR}/nginx/default.conf" ]]; then
  log "Installing Nginx site configuration..."
  install -m 0644 "${REPO_DIR}/nginx/default.conf" /etc/nginx/conf.d/notes-api.conf

  # Disable the stock welcome page so :80 is served only by our vhost.
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
  fi
  # Debian-style layouts keep the default site in sites-enabled.
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  # The upstream file is rewritten by deploy.sh; create a sane default only if
  # it does not exist yet, so a re-run never moves live traffic.
  if [[ ! -f /etc/nginx/notes-upstream.conf ]]; then
    log "Installing default upstream (:3000)..."
    install -m 0644 "${REPO_DIR}/nginx/upstream.conf" /etc/nginx/notes-upstream.conf
  else
    log "Keeping existing upstream file (live traffic unchanged)"
  fi
else
  die "nginx/default.conf not found under ${REPO_DIR}"
fi

log "Validating Nginx configuration..."
nginx -t

log "Reloading Nginx..."
systemctl reload nginx || systemctl restart nginx

# --- 5. Log rotation -------------------------------------------------------
cat >/etc/logrotate.d/notes-api <<'EOF'
/var/log/nginx/notes_api.*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 "$(cat /var/run/nginx.pid)"
    endscript
}
EOF

log "Bootstrap complete."
log "  Docker : $(docker --version)"
log "  Nginx  : $(nginx -v 2>&1)"
log "  Next   : scripts/deploy.sh --image <registry>/<repo>:<sha>"

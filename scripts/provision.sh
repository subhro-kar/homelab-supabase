#!/usr/bin/env bash
# provision.sh — Set up a fresh OCI ARM64 VM for Supabase
# Run this script ONCE on the new VM after creating it in the OCI console.
#
# Usage: ssh into the new VM, then:
#   curl -sL <raw-url>/scripts/provision.sh | bash
# Or:
#   git clone <repo-url> ~/homelab-supabase && cd ~/homelab-supabase && bash scripts/provision.sh
#
# What this does:
#   1. Updates system packages
#   2. Installs Docker + Docker Compose
#   3. Installs Tailscale
#   4. Installs Nginx
#   5. Sets up firewall (UFW)
#   6. Creates directory structure for Supabase volumes
#   7. Copies Cloudflare origin certs from Tailscale-connected old VM
#
# Prerequisites:
#   - OCI VM.Standard.A1.Flex (ARM64) with Ubuntu 24.04
#   - VM created in subhbits-vcn, subnet 10.0.2.0/24
#   - Public IP assigned to the VM
#   - SSH access with ubuntu user

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[PROVISION]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────
# 1. System updates
# ──────────────────────────────────────────────
log "Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
    curl wget git vim htop tmux \
    apt-transport-https ca-certificates \
    gnupg lsb-release ufw fail2ban

# ──────────────────────────────────────────────
# 2. Install Docker
# ──────────────────────────────────────────────
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository (detect architecture)
    ARCH=$(dpkg --print-architecture)
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $CODENAME stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add ubuntu user to docker group
    sudo usermod -aG docker ubuntu

    log "Docker installed: $(docker --version)"
fi

# ──────────────────────────────────────────────
# 3. Install Tailscale
# ──────────────────────────────────────────────
if command -v tailscale &>/dev/null; then
    log "Tailscale already installed: $(tailscale --version | head -1)"
else
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log "Tailscale installed. Run 'sudo tailscale up' to authenticate."
fi

# ──────────────────────────────────────────────
# 4. Install Nginx
# ──────────────────────────────────────────────
if command -v nginx &>/dev/null; then
    log "Nginx already installed: $(nginx -v 2>&1)"
else
    log "Installing Nginx..."
    sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    log "Nginx installed."
fi

# ──────────────────────────────────────────────
# 5. Firewall setup (UFW)
# ──────────────────────────────────────────────
log "Configuring UFW firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH
sudo ufw allow 22/tcp

# HTTP/HTTPS (for Nginx reverse proxy + Cloudflare)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Supabase API (proxied through Nginx, but allow direct for debugging)
sudo ufw allow 8000/tcp comment 'Supabase API'
sudo ufw allow 3001/tcp comment 'Supabase Studio'

# Tailscale (allows all traffic over Tailscale interface)
sudo ufw allow in on tailscale0
sudo ufw allow out on tailscale0

sudo ufw --force enable
log "UFW configured."

# ──────────────────────────────────────────────
# 5b. Fix iptables for OCI (OCI adds a REJECT rule before UFW)
# ──────────────────────────────────────────────
log "Fixing iptables for OCI compatibility..."
# OCI's default iptables REJECT rule blocks traffic before UFW rules
# Insert ACCEPT rules for 80/443 before the REJECT rule
sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
# Persist across reboots
sudo apt-get install -y iptables-persistent 2>/dev/null || true
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
sudo sh -c 'ip6tables-save > /etc/iptables/rules.v6' 2>/dev/null || true
log "iptables rules configured and persisted."

# ──────────────────────────────────────────────
# 6. Create directory structure
# ──────────────────────────────────────────────
log "Creating Supabase directory structure..."
sudo mkdir -p /opt/supabase/volumes/db
sudo chown -R ubuntu:ubuntu /opt/supabase

# ──────────────────────────────────────────────
# 7. Summary
# ──────────────────────────────────────────────
echo ""
log "=========================================="
log "  Provisioning complete!"
log "=========================================="
echo ""
log "Next steps:"
echo "  1. Authenticate Tailscale:"
echo "     sudo tailscale up"
echo ""
echo "  2. Clone the repo:"
echo "     git clone git@github.com:subhro-kar/homelab-supabase.git /opt/supabase"
echo ""
echo "  3. Copy .env from old VM:"
echo "     scp OLD_VM:/home/ubuntu/supabase/docker/.env /opt/supabase/docker/.env"
echo ""
echo "  4. Update .env with new URLs:"
echo "     SITE_URL=https://db.subhbits.com"
echo "     API_EXTERNAL_URL=https://db.subhbits.com"
echo ""
echo "  5. Copy Cloudflare origin certs:"
echo "     scp OLD_VM:/etc/nginx/ssl/cloudflare-*.pem /etc/nginx/ssl/"
echo ""
echo "  6. Deploy Supabase:"
echo "     cd /opt/supabase/docker && docker compose up -d"
echo ""
echo "  7. Configure Nginx:"
echo "     sudo cp /opt/supabase/nginx/supabase.conf /etc/nginx/sites-available/"
echo "     sudo ln -sf /etc/nginx/sites-available/supabase.conf /etc/nginx/sites-enabled/"
echo "     sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo "  8. Run database migration from old VM:"
echo "     bash scripts/migrate.sh"
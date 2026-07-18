#!/usr/bin/env bash
# migrate.sh — Migrate Supabase database from old VM to new VM
#
# This script:
#   1. Dumps the PostgreSQL database from the OLD VM
#   2. Transfers the dump to the NEW VM
#   3. Restores it on the NEW VM
#
# Prerequisites:
#   - Both VMs must be on Tailscale (or reachable via SSH)
#   - Supabase must be running on the OLD VM
#   - Supabase must be running on the NEW VM (with empty DB)
#   - SSH access to both VMs
#
# Usage:
#   Run this from the NEW VM (or any machine with SSH access to both):
#
#   bash scripts/migrate.sh <old_vm_ip> [old_vm_ssh_user]
#
# Example:
#   bash scripts/migrate.sh 100.78.231.54 ubuntu
#
#   # Or if using Tailscale hostname:
#   bash scripts/migrate.sh instance-20260620-0936 ubuntu

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[MIGRATE]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
OLD_VM_IP="${1:?Usage: $0 <old_vm_ip> [ssh_user]}"
OLD_VM_USER="${2:-ubuntu}"
DUMP_FILE="/tmp/supabase_dump_$(date +%Y%m%d_%H%M%S).sql.gz"
OLD_DOCKER_PATH="/home/ubuntu/supabase/docker"
NEW_DOCKER_PATH="/opt/supabase/docker"

# ──────────────────────────────────────────────
# Step 1: Dump database from old VM
# ──────────────────────────────────────────────
log "Step 1: Dumping PostgreSQL from old VM (${OLD_VM_IP})..."

ssh "${OLD_VM_USER}@${OLD_VM_IP}" bash -s <<DUMP_SCRIPT
set -e
echo "[OLD VM] Creating database dump..."
docker exec supabase-db pg_dump -U postgres -d postgres \
    --no-owner --no-acl --clean --if-exists \
    | gzip > /tmp/supabase_migrate.sql.gz
echo "[OLD VM] Dump created: /tmp/supabase_migrate.sql.gz"
echo "[OLD VM] Dump size: \$(du -h /tmp/supabase_migrate.sql.gz | cut -f1)"
DUMP_SCRIPT

# ──────────────────────────────────────────────
# Step 2: Transfer dump to new VM (this machine)
# ──────────────────────────────────────────────
log "Step 2: Transferring dump to this VM..."
scp "${OLD_VM_USER}@${OLD_VM_IP}:/tmp/supabase_migrate.sql.gz" "${DUMP_FILE}"
log "Dump transferred: ${DUMP_FILE} ($(du -h "${DUMP_FILE}" | cut -f1))"

# ──────────────────────────────────────────────
# Step 3: Restore database on new VM
# ──────────────────────────────────────────────
log "Step 3: Restoring database on this VM..."

# Check that Supabase is running
if ! docker ps --format '{{.Names}}' | grep -q 'supabase-db'; then
    err "Supabase database container is not running! Start it first: cd ${NEW_DOCKER_PATH} && docker compose up -d"
fi

# Copy dump into the container
docker cp "${DUMP_FILE}" supabase-db:/tmp/supabase_migrate.sql.gz

# Restore
log "Restoring database (this may take a moment)..."
docker exec supabase-db bash -c "
    gunzip -c /tmp/supabase_migrate.sql.gz | psql -U postgres -d postgres 2>&1 || true
"

# Cleanup
docker exec supabase-db rm -f /tmp/supabase_migrate.sql.gz
rm -f "${DUMP_FILE}"

log "Database restoration complete!"

# ──────────────────────────────────────────────
# Step 4: Restart Supabase services
# ──────────────────────────────────────────────
log "Step 4: Restarting Supabase services..."
cd "${NEW_DOCKER_PATH}"
docker compose restart

log "=========================================="
log "  Migration complete!"
log "=========================================="
echo ""
log "Verify the migration:"
echo "  1. Check Studio: https://studio.subhbits.com"
echo "  2. Check API: https://db.subhbits.com/rest/v1/"
echo "  3. Check DB connection: docker exec supabase-db psql -U postgres -c '\\dt'"
echo ""
log "If everything works, stop Supabase on the OLD VM:"
echo "  ssh ${OLD_VM_USER}@${OLD_VM_IP} 'cd ${OLD_DOCKER_PATH} && docker compose down'"
echo ""
warn "Remember to update Cloudflare DNS if not already pointing to this VM!"
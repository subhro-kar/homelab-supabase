# Homelab Supabase

Self-hosted Supabase (PostgreSQL + Auth + Storage + Realtime) running on OCI Ampere A1 (ARM64).

## Architecture

```
subhbits-vcn (10.0.0.0/16) — ap-mumbai-1
├── Subnet A (10.0.0.0/24) — Main VM
│   Authentik, Infisical, Open WebUI, AdGuard, G0DM0D3
│
└── Subnet B (10.0.2.0/24) — This VM
    Supabase (all services) + Nginx + Tailscale
```

**DNS:** Cloudflare proxies `db.subhbits.com` → API, `studio.subhbits.com` → Studio.

## VM Specs

| Setting | Value |
|---------|-------|
| Shape | VM.Standard.A1.Flex (ARM64) |
| OCPUs | 1 |
| RAM | 6 GB |
| Boot volume | 47 GB |
| OS | Ubuntu 24.04 LTS ARM64 |
| Region | ap-mumbai-1 |

## Quick Start (New VM)

### 1. Create VM in OCI Console

Create a new compute instance in `subhbits-vcn`:
- **Subnet:** Create new subnet `10.0.2.0/24` in `subhbits-vcn`
- **Security List:** Allow ingress 22, 80, 443 / egress all
- **Public IP:** Assign a public IP

### 2. Provision

```bash
# SSH into the new VM
ssh ubuntu@<new-vm-ip>

# Clone this repo
git clone git@github.com:subhro-kar/homelab-supabase.git
cd homelab-supabase

# Run provision script
bash scripts/provision.sh
```

### 3. Configure Tailscale

```bash
sudo tailscale up
# Note the Tailscale IP (100.x.x.x)
```

### 4. Deploy Supabase

```bash
# Copy .env from old VM (over Tailscale)
scp ubuntu@<old-vm-tailscale-ip>:/home/ubuntu/supabase/docker/.env docker/.env

# Edit .env to update URLs
sed -i 's|http://localhost:8000|https://db.subhbits.com|g' docker/.env
sed -i 's|http://localhost:3000|https://db.subhbits.com|g' docker/.env

# Start Supabase
cd docker && docker compose up -d
```

### 5. Configure Nginx

```bash
# Copy Cloudflare origin certs from old VM
sudo mkdir -p /etc/nginx/ssl
scp ubuntu@<old-vm-tailscale-ip>:/etc/nginx/ssl/cloudflare-origin.pem /etc/nginx/ssl/
scp ubuntu@<old-vm-tailscale-ip>:/etc/nginx/ssl/cloudflare-private.key /etc/nginx/ssl/

# Configure Nginx
sudo cp nginx/supabase.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/supabase.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default  # Remove default if needed
sudo nginx -t && sudo systemctl reload nginx
```

### 6. Migrate Database

Run from the **new VM**:

```bash
bash scripts/migrate.sh <old-vm-tailscale-ip> ubuntu
```

### 7. Update DNS

In Cloudflare dashboard:
- Update `db.subhbits.com` A record → new VM's public IP
- Update `studio.subhbits.com` A record → new VM's public IP
- Keep Cloudflare proxy (orange cloud) enabled

### 8. Verify

```bash
# Check Studio
curl -s https://studio.subhbits.com | head -5

# Check API
curl -s https://db.subhbits.com/rest/v1/ -H "apikey: <your-anon-key>"

# Check database
docker exec supabase-db psql -U postgres -c '\dt'
```

### 9. Decommission Old VM Supabase

Once verified on the new VM:

```bash
# SSH into old VM and stop Supabase
ssh ubuntu@<old-vm-tailscale-ip>
cd /home/ubuntu/supabase/docker && docker compose down
```

## Directory Structure

```
homelab-supabase/
├── docker/
│   ├── docker-compose.yml       # Supabase services (ARM64 compatible)
│   ├── .env.example             # Template (no secrets)
│   └── volumes/                 # Persistent volume paths
├── nginx/
│   └── supabase.conf            # Reverse proxy config
├── scripts/
│   ├── provision.sh             # VM setup (Docker, Tailscale, Nginx)
│   └── migrate.sh               # Database dump/restore
└── README.md
```

## Secrets Management

Secrets are in `docker/.env` (gitignored). **Infisical integration is planned** — for now:

- `.env` is excluded from git via `.gitignore`
- `.env.example` contains placeholder values only
- Never commit real secrets to the repo

## ARM64 Compatibility

All Supabase Docker images support `linux/arm64`. No changes needed to `docker-compose.yml`.

## Rollback

If the new VM has issues:

1. Switch Cloudflare DNS back to old VM IP (instant — no TTL with proxy)
2. Start Supabase on old VM: `docker compose up -d`
3. Data remains on old VM until explicitly removed

## Troubleshooting

### Docker Volume Mount Bug

When mounting a file that doesn't exist on the host (e.g. `./volumes/api/kong.yml:/etc/kong/kong.yml`), Docker creates a **directory** instead of a file. This silently breaks the container. Fix:

```bash
docker compose down  # Stop containers first!
sudo rm -rf volumes/api/kong.yml  # Remove the directory
# Now create the actual file before starting containers
```

All required config files are now tracked in this repo under `volumes/`.

### OCI iptables vs UFW

OCI's default image adds a REJECT rule in iptables *before* UFW rules. Even if UFW shows port 443 allowed, traffic gets rejected. Fix:

```bash
sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 443 -j ACCEPT
sudo apt-get install -y iptables-persistent
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
```

### JWT Key Mismatch After pg_restore

If `ANON_KEY` and `SERVICE_ROLE_KEY` were generated with a different `JWT_SECRET` than what's in `.env`, PostgREST returns `"No suitable key or wrong key type"`. Regenerate keys to match:

```bash
# In .env, verify JWT_SECRET matches what signed ANON_KEY
python3 -c "
import hmac, hashlib, base64, json
secret = 'YOUR_JWT_SECRET'.encode()
header = base64.urlsafe_b64encode(json.dumps({'alg':'HS256','typ':'JWT'}).encode()).rstrip(b'=').decode()
payload = base64.urlsafe_b64encode(json.dumps({'role':'anon','iss':'supabase','iat':0,'exp':1893456000}).encode()).rstrip(b'=').decode()
sig = base64.urlsafe_b64encode(hmac.new(secret, f'{header}.{payload}'.encode(), hashlib.sha256).digest()).rstrip(b'=').decode()
print(f'ANON_KEY={header}.{payload}.{sig}')
"
```

### Storage / Functions Migration RLS Conflicts

If storage or edge-functions fail after pg_restore due to RLS on migration tables:

```sql
DROP SCHEMA storage CASCADE;
CREATE SCHEMA storage AUTHORIZATION supabase_storage_admin;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin;
GRANT USAGE ON SCHEMA storage TO postgres, anon, authenticated, service_role;

DROP SCHEMA IF EXISTS supabase_functions CASCADE;
CREATE SCHEMA supabase_functions AUTHORIZATION supabase_admin;
GRANT ALL ON SCHEMA supabase_functions TO supabase_admin;
GRANT USAGE ON SCHEMA supabase_functions TO postgres, anon, authenticated, service_role;
```

Also set JWT settings in the database:
```sql
ALTER DATABASE postgres SET "app.settings.jwt_secret" TO 'your-jwt-secret';
ALTER DATABASE postgres SET "app.settings.jwt_exp" TO '3600';
```

## Idle Reclamation Warning

OCI free tier reclaims A1 instances idle for 7+ days (<20% CPU/network/memory). Supabase's background processes should keep usage above the threshold, but consider adding a monitoring cron job as insurance.

## Useful Commands

```bash
# View Supabase logs
docker compose -f docker/docker-compose.yml logs -f

# Restart a specific service
docker compose -f docker/docker-compose.yml restart supabase-db

# Check container status
docker compose -f docker/docker-compose.yml ps

# Access PostgreSQL directly
docker exec -it supabase-db psql -U postgres
```
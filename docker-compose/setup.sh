#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup.sh — Bootstrap a self-hosted Neon stack from zero.
# Run from the docker-compose/ directory:
#   bash setup.sh
# Re-running is safe (idempotent where possible).
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✔ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✖ $*${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
need_sudo() {
    if [[ $EUID -ne 0 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

prompt() {
    # prompt <var_name> <message> [default]
    local var="$1" msg="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}${msg}${NC} [${default}]: ")" val
        printf -v "$var" '%s' "${val:-$default}"
    else
        read -rp "$(echo -e "${BOLD}${msg}${NC}: ")" val
        printf -v "$var" '%s' "$val"
    fi
}

prompt_password() {
    local var="$1" msg="$2"
    while true; do
        read -rsp "$(echo -e "${BOLD}${msg}${NC}: ")" pw1; echo
        read -rsp "$(echo -e "${BOLD}Confirm password${NC}: ")" pw2; echo
        if [[ "$pw1" == "$pw2" && -n "$pw1" ]]; then
            printf -v "$var" '%s' "$pw1"
            break
        fi
        warn "Passwords do not match or empty, try again."
    done
}

md5_pg_password() {
    # md5(password + rolname) — PostgreSQL MD5 auth format
    python3 -c "import hashlib,sys; print(hashlib.md5((sys.argv[1]+sys.argv[2]).encode()).hexdigest())" "$1" "$2"
}

json_set_password() {
    local file="$1" hash="$2"
    python3 - "$file" "$hash" <<'EOF'
import json, sys
path, new_hash = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
for role in data["spec"]["cluster"]["roles"]:
    if role["name"] == "cloud_admin":
        role["encrypted_password"] = new_hash
with open(path, "w") as f:
    json.dump(data, f, indent=4)
EOF
}

json_set_databases() {
    local file="$1"; shift
    local dbs=("$@")
    python3 - "$file" "${dbs[@]}" <<'EOF'
import json, sys
path = sys.argv[1]
names = sys.argv[2:]
with open(path) as f:
    data = json.load(f)
existing = {d["name"] for d in data["spec"]["cluster"]["databases"]}
for name in names:
    if name not in existing:
        data["spec"]["cluster"]["databases"].append(
            {"name": name, "owner": "cloud_admin", "options": None}
        )
with open(path, "w") as f:
    json.dump(data, f, indent=4)
print(f"Databases: {[d['name'] for d in data['spec']['cluster']['databases']]}")
EOF
}

# ── Step 0: Check prerequisites ───────────────────────────────────────────────
header "Prerequisites"

install_if_missing() {
    local pkg="$1" cmd="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg…"
        need_sudo apt-get install -y "$pkg"
        success "$pkg installed."
    else
        success "$cmd already present ($(command -v "$cmd"))."
    fi
}

if ! command -v apt-get &>/dev/null; then
    die "This script requires apt-get (Ubuntu/Debian)."
fi

need_sudo apt-get update -qq

install_if_missing git git
install_if_missing python3 python3

# Docker
if ! command -v docker &>/dev/null; then
    info "Installing docker.io…"
    need_sudo apt-get install -y docker.io docker-compose-plugin
    need_sudo systemctl enable --now docker
    success "Docker installed."
else
    success "docker already present."
fi

# Docker Compose plugin (v2)
if ! docker compose version &>/dev/null; then
    info "Installing docker-compose-plugin…"
    need_sudo apt-get install -y docker-compose-plugin
fi
success "docker compose $(docker compose version --short) ready."

# Add current user to docker group if needed (takes effect on next login)
if ! groups "$USER" | grep -q docker; then
    warn "User '$USER' is not in the docker group."
    warn "Adding… you may need to log out and back in, or run: newgrp docker"
    need_sudo usermod -aG docker "$USER"
fi

# ── Step 1: Collect configuration ─────────────────────────────────────────────
header "Configuration"

CONFIG_JSON="$SCRIPT_DIR/compute_wrapper/var/db/postgres/configs/config.json"
ENV_FILE="$SCRIPT_DIR/.env"

# Hostname / domain
prompt HOST "Server hostname or domain (e.g. neon.example.com or localhost)" "localhost"

# Password
echo
warn "The Postgres superuser is 'cloud_admin'."
warn "This password is stored as an MD5 hash in config.json."
echo
if [[ -f "$ENV_FILE" ]] && grep -q "POSTGRES_URL=" "$ENV_FILE"; then
    # Try to extract existing password from .env to offer as default
    EXISTING_PW=$(grep "^POSTGRES_URL=" "$ENV_FILE" | sed 's|.*cloud_admin:\([^@]*\)@.*|\1|')
    if [[ -n "$EXISTING_PW" && "$EXISTING_PW" != "cloud_admin" ]]; then
        warn "Existing password detected in .env. Press Enter to keep it, or type a new one."
        read -rsp "$(echo -e "${BOLD}New password${NC} [keep existing]: ")" PG_PW; echo
        PG_PW="${PG_PW:-$EXISTING_PW}"
    else
        prompt_password PG_PW "Password for cloud_admin"
    fi
else
    prompt_password PG_PW "Password for cloud_admin"
fi

# Databases
echo
info "Enter database names to create (space-separated)."
info "The 'postgres' database always exists. Add your app databases here."
prompt DB_INPUT "Databases" "postgres"
# shellcheck disable=SC2206
DB_ARRAY=($DB_INPUT)

# SSL
echo
SSL_SETUP="n"
if [[ "$HOST" != "localhost" && "$HOST" != "127.0.0.1" ]]; then
    read -rp "$(echo -e "${BOLD}Set up Let's Encrypt SSL for ${HOST}?${NC} [y/N]: ")" SSL_SETUP
fi

# PG version
prompt PG_VERSION "Postgres version (14 15 16 17)" "16"

# ── Step 2: Update config.json ────────────────────────────────────────────────
header "Updating Postgres spec (config.json)"

PG_HASH=$(md5_pg_password "$PG_PW" "cloud_admin")
info "Password hash: ${PG_HASH:0:8}…"
json_set_password "$CONFIG_JSON" "$PG_HASH"
success "Password hash updated in config.json."

json_set_databases "$CONFIG_JSON" "${DB_ARRAY[@]}"
success "Databases configured."

# ── Step 3: Write .env ────────────────────────────────────────────────────────
header "Writing .env"

SSL_MODE="disable"
[[ "${SSL_SETUP,,}" == "y" ]] && SSL_MODE="require"

PRIMARY_DB="${DB_ARRAY[0]}"

cat > "$ENV_FILE" <<EOF
# Neon Docker Compose — generated by setup.sh
# Edit manually or re-run setup.sh to regenerate.

REPOSITORY=ghcr.io/neondatabase
TAG=latest
PG_VERSION=${PG_VERSION}
PARALLEL_COMPUTES=1

# Leave blank to auto-create on first boot
TENANT_ID=
TIMELINE_ID=

# Connection URLs for your applications
POSTGRES_URL=postgresql://cloud_admin:${PG_PW}@${HOST}:55433/${PRIMARY_DB}?sslmode=${SSL_MODE}
POSTGRES_URL_UNPOOLED=postgresql://cloud_admin:${PG_PW}@${HOST}:55433/${PRIMARY_DB}?sslmode=${SSL_MODE}

# neon-test-extensions profile only (not used by Postgres itself)
PGUSER=cloud_admin
PGPASSWORD=${PG_PW}
EOF

success ".env written."

# ── Step 4: SSL ───────────────────────────────────────────────────────────────
if [[ "${SSL_SETUP,,}" == "y" ]]; then
    header "SSL — Let's Encrypt"

    install_if_missing certbot certbot

    CERT_DIR="$SCRIPT_DIR/certs"
    mkdir -p "$CERT_DIR"

    # Check if cert already exists and is valid
    if need_sudo certbot certificates 2>/dev/null | grep -q "$HOST"; then
        warn "Certificate for $HOST already exists, skipping issuance."
    else
        info "Obtaining certificate for $HOST (port 80 must be free)…"
        need_sudo certbot certonly --standalone -d "$HOST" --non-interactive --agree-tos \
            --register-unsafely-without-email
    fi

    info "Copying certs with correct ownership (uid 1000)…"
    need_sudo cp "/etc/letsencrypt/live/${HOST}/fullchain.pem" "$CERT_DIR/server.crt"
    need_sudo cp "/etc/letsencrypt/live/${HOST}/privkey.pem"   "$CERT_DIR/server.key"
    need_sudo chown 1000:1000 "$CERT_DIR/server.crt" "$CERT_DIR/server.key"
    need_sudo chmod 644 "$CERT_DIR/server.crt"
    need_sudo chmod 600 "$CERT_DIR/server.key"
    success "Certs installed in $CERT_DIR."

    # Install renewal hook
    HOOK_SRC="$SCRIPT_DIR/renew-certs.sh"
    HOOK_DST="/etc/letsencrypt/renewal-hooks/deploy/neon-postgres.sh"
    # Patch the domain into the hook
    sed "s|neon.ixa.ink|${HOST}|g" "$HOOK_SRC" > /tmp/neon-postgres-hook.sh
    need_sudo cp /tmp/neon-postgres-hook.sh "$HOOK_DST"
    need_sudo chmod +x "$HOOK_DST"
    success "Auto-renewal hook installed at $HOOK_DST."
fi

# ── Step 5: Clean stale pageserver state ──────────────────────────────────────
header "Checking for stale pageserver state"

PS_STALE=("$SCRIPT_DIR/pageserver_config/tenants"
           "$SCRIPT_DIR/pageserver_config/deletion"
           "$SCRIPT_DIR/pageserver_config/pageserver.pid")

STALE_FOUND=0
for p in "${PS_STALE[@]}"; do
    [[ -e "$p" ]] && { STALE_FOUND=1; break; }
done

if [[ $STALE_FOUND -eq 1 ]]; then
    warn "Stale pageserver data detected. Removing to ensure a clean boot."
    warn "(This does NOT remove your MinIO data unless you also run 'docker compose down -v'.)"
    for p in "${PS_STALE[@]}"; do
        rm -rf "$p" && info "Removed: $p"
    done
fi
success "Pageserver state is clean."

# ── Step 6: Pull images & start stack ─────────────────────────────────────────
header "Starting the stack"

# Tear down any previous run first (keep volumes unless user asks)
if docker compose ps -q 2>/dev/null | grep -q .; then
    info "Stopping existing containers…"
    docker compose down
fi

info "Pulling latest images and building compute wrapper…"
PG_VERSION="$PG_VERSION" docker compose pull --ignore-buildable 2>&1 | grep -v "^time=" || true
PG_VERSION="$PG_VERSION" docker compose up --build -d 2>&1 | grep -v "^time=" | grep -v "^#"
success "Stack started."

# ── Step 7: Wait for compute ──────────────────────────────────────────────────
header "Waiting for compute to be ready"

TIMEOUT=120
ELAPSED=0
printf "Waiting"
until docker compose logs compute_is_ready 2>/dev/null | grep -q "All computes are started"; do
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        echo
        die "Compute did not become ready within ${TIMEOUT}s. Run: docker compose logs compute1"
    fi
    printf "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo

success "Compute is ready!"

# ── Step 8: Summary ───────────────────────────────────────────────────────────
header "Done"

echo
echo -e "${BOLD}Connection details:${NC}"
echo -e "  Host:     ${CYAN}${HOST}:55433${NC}"
echo -e "  User:     ${CYAN}cloud_admin${NC}"
echo -e "  Password: ${CYAN}${PG_PW}${NC}"
echo -e "  SSL mode: ${CYAN}${SSL_MODE}${NC}"
echo
echo -e "${BOLD}Databases created:${NC}"
for db in "${DB_ARRAY[@]}"; do
    echo -e "  ${CYAN}${db}${NC}"
done
echo
echo -e "${BOLD}POSTGRES_URL:${NC}"
echo -e "  ${CYAN}postgresql://cloud_admin:${PG_PW}@${HOST}:55433/${PRIMARY_DB}?sslmode=${SSL_MODE}${NC}"
echo
echo -e "${BOLD}Useful commands:${NC}"
echo -e "  ${YELLOW}docker compose logs -f compute1${NC}   — live compute logs"
echo -e "  ${YELLOW}docker compose ps${NC}                 — container health"
echo -e "  ${YELLOW}docker compose down -v${NC}            — full wipe (removes MinIO data)"
echo -e "  ${YELLOW}docker compose restart compute1${NC}   — re-apply config.json changes"
echo
if [[ "${SSL_SETUP,,}" != "y" && "$HOST" != "localhost" ]]; then
    warn "SSL is not enabled. Re-run setup.sh and choose 'y' for SSL when ready,"
    warn "or follow the SSL section in HOWTO_DOCKER.md."
fi

# Self-Hosted Neon on Docker Compose — Full Tutorial

This guide walks through running a complete Neon stack locally or on a VPS,
starting from a fresh Ubuntu 24.04 machine and cloning
[https://github.com/soulwax/neon](https://github.com/soulwax/neon).

---

## Quick start (automated)

`setup.sh` handles everything: prerequisites, password hashing, database
creation, `.env` generation, optional Let's Encrypt SSL, and stack startup.

```bash
git clone https://github.com/soulwax/neon.git
cd neon/docker-compose
bash setup.sh
```

The script will prompt for:
- **Hostname** — `localhost` for local use, your domain for a public server
- **Password** — for the `cloud_admin` Postgres superuser
- **Databases** — space-separated list to create (e.g. `myapp myapp_shadow`)
- **SSL** — `y` to run certbot automatically (domain must point at this server, port 80 free)

Re-running `setup.sh` is safe — it detects existing state and only changes
what is needed.

---

## Architecture

The stack runs 8 containers:

| Container | Role | Exposed port |
|---|---|---|
| `minio` | S3-compatible object storage for WAL and page layers | 9000, 9001 |
| `minio_create_buckets` | One-shot: creates the `neon` MinIO bucket | — |
| `storage_broker` | Internal pub/sub between safekeepers and pageserver | 50051 |
| `safekeeper1/2/3` | WAL quorum (3-node, 2-of-3 needed) | 7676–7678 |
| `pageserver` | Page version storage, serves base backups | 9898 |
| `compute1` | Postgres 16 compute node | **55433** |
| `compute_is_ready` | Health-check waiter, exits 0 when compute accepts connections | — |

The compute node (`compute1`) is the only endpoint your applications talk to.
Port **55433** is the Postgres wire protocol.

---

## Prerequisites

```bash
# Docker (Ubuntu 24.04 ships a recent version)
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin git

# Allow your user to run docker without sudo
sudo usermod -aG docker $USER
newgrp docker
```

Verify:
```bash
docker --version          # 24+ expected
docker compose version    # v2.x expected
```

---

## 1. Clone the repo

```bash
git clone https://github.com/soulwax/neon.git
cd neon/docker-compose
```

---

## 2. Create your `.env`

Copy the example and edit it:

```bash
cp .env.example .env   # or just edit .env directly
```

Key variables:

| Variable | Default | Notes |
|---|---|---|
| `REPOSITORY` | `ghcr.io/neondatabase` | Image registry |
| `TAG` | `latest` | Image tag for all neon services |
| `PG_VERSION` | `16` | Postgres version (14–17) |
| `PARALLEL_COMPUTES` | `1` | How many compute nodes to start |
| `TENANT_ID` | _(empty)_ | Leave blank — auto-created on first boot |
| `TIMELINE_ID` | _(empty)_ | Leave blank — auto-created on first boot |

Connection URLs (for your applications — **not** read by docker-compose itself):

```dotenv
POSTGRES_URL=postgresql://cloud_admin:yourpassword@your-host:55433/yourdb?sslmode=disable
POSTGRES_URL_UNPOOLED=postgresql://cloud_admin:yourpassword@your-host:55433/yourdb?sslmode=disable
```

> There is no connection pooler in this stack. Both URLs point to the same
> endpoint. Change `sslmode=disable` to `sslmode=require` only after
> completing the SSL setup in step 5.

---

## 3. Configure your databases and password

### Change the `cloud_admin` password

The password is stored as a PostgreSQL MD5 hash in
`compute_wrapper/var/db/postgres/configs/config.json`.

Generate a hash for your chosen password:

```bash
python3 -c "
import hashlib, getpass
pw = getpass.getpass('New password: ')
print(hashlib.md5((pw + 'cloud_admin').encode()).hexdigest())
"
```

Open `compute_wrapper/var/db/postgres/configs/config.json` and replace the
`encrypted_password` value with the output:

```json
"roles": [
    {
        "name": "cloud_admin",
        "encrypted_password": "<paste hash here>",
        "options": null
    }
]
```

> The spec in `config.json` is re-applied on every compute restart.
> A live `ALTER ROLE` via psql works immediately but is overwritten on
> the next restart. Always update `config.json` as the source of truth.

### Add databases

Add entries to the `databases` array in the same file:

```json
"databases": [
    {
        "name": "myapp",
        "owner": "cloud_admin",
        "options": null
    }
]
```

Add as many databases as you need. They are created automatically when
the compute starts.

---

## 4. Start the stack

### First boot (or full reset)

```bash
# Wipe all previous state (MinIO data, safekeeper WAL, pageserver pages)
docker compose down -v
rm -rf pageserver_config/tenants pageserver_config/deletion pageserver_config/pageserver.pid

# Build the compute wrapper image and start everything
docker compose up --build -d

# Tail logs until compute is ready
docker compose logs -f compute_is_ready
```

Wait for:
```
All computes are started
```

### Subsequent starts (no code changes)

```bash
docker compose up -d
```

### Connect

```bash
psql "postgresql://cloud_admin:yourpassword@localhost:55433/myapp?sslmode=disable"
```

### Stop without losing data

```bash
docker compose down      # keeps MinIO bucket intact
```

### Full wipe

```bash
docker compose down -v
rm -rf pageserver_config/tenants pageserver_config/deletion pageserver_config/pageserver.pid
```

> **Why the `rm -rf`?** The pageserver config directory
> (`pageserver_config/`) is a bind mount to the host, not a Docker volume.
> `down -v` removes Docker volumes but leaves host-mounted files. If you
> restart with stale tenant data in `pageserver_config/tenants/`, the
> compute will try to reuse the old Postgres cluster, which will conflict
> with any spec changes you made.

---

## 5. Enable SSL (optional but recommended for public servers)

Without SSL, connections are unencrypted. Applications that enforce
`sslmode=require` (common with Neon-compatible drivers) will refuse to connect.

### Get a certificate (Let's Encrypt)

Port 80 must be free during this step. If something else is using it,
stop it temporarily.

```bash
sudo apt-get install -y certbot
sudo certbot certonly --standalone -d your-domain.example.com
```

### Copy certs with correct ownership

The Postgres process inside the compute container runs as uid 1000
(`postgres`). The key file must be readable by that user and not
world-readable.

```bash
mkdir -p certs
sudo cp /etc/letsencrypt/live/your-domain.example.com/privkey.pem  certs/server.key
sudo cp /etc/letsencrypt/live/neon.ixa.ink/privkey.pem  certs/server.key
sudo cp /etc/letsencrypt/live/your-domain.example.com/fullchain.pem certs/server.crt
sudo cp /etc/letsencrypt/live/neon.ixa.ink/fullchain.pem certs/server.crt
sudo chown 1000:1000 certs/server.crt certs/server.key
sudo chmod 644 certs/server.crt
sudo chmod 600 certs/server.key
```

### Enable SSL in the Postgres spec

In `compute_wrapper/var/db/postgres/configs/config.json`, add to the
`settings` array:

```json
{
    "name": "ssl",
    "value": "on",
    "vartype": "bool"
},
{
    "name": "ssl_cert_file",
    "value": "/var/db/postgres/certs/server.crt",
    "vartype": "string"
},
{
    "name": "ssl_key_file",
    "value": "/var/db/postgres/certs/server.key",
    "vartype": "string"
}
```

The `certs/` directory is already mounted into the compute container
at `/var/db/postgres/certs/` (added in `docker-compose.yml`).

Restart the compute to pick up the new settings:

```bash
docker compose restart compute1
```

### Set up automatic renewal

Certbot renews the certificate automatically, but Postgres needs the
new files and a reload signal. Install the deploy hook:

```bash
sudo cp renew-certs.sh /etc/letsencrypt/renewal-hooks/deploy/neon-postgres.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/neon-postgres.sh
# Edit the script if your domain or paths differ
```

The hook copies fresh certs and sends `pg_ctl reload` to Postgres —
no restart, no dropped connections.

Test renewal without actually renewing:

```bash
sudo certbot renew --dry-run
```

### Update your connection URLs

Change `sslmode=disable` → `sslmode=require` in your `.env` and
application configuration.

---

## 6. Test connectivity from another server

**TCP port check (no Postgres client needed):**
```bash
nc -zv neon.ixa.ink 55433
```

**Full Postgres handshake:**
```bash
# Install client only
sudo apt-get install -y postgresql-client

psql "postgresql://cloud_admin:yourpassword@your-host:55433/myapp?sslmode=require" \
     -c "SELECT version();"
```

**Python (if psql not available):**
```bash
python3 -c "
import socket
s = socket.create_connection(('your-host', 55433), timeout=5)
print('TCP OK, banner:', s.recv(8))
s.close()
"
```

If `nc` succeeds but `psql` fails → auth or SSL mismatch.
If `nc` fails → port is blocked at the network / cloud firewall level.

---

## 7. Useful day-to-day commands

```bash
# Live logs for all services
docker compose logs -f

# Logs for one service
docker compose logs -f pageserver
docker compose logs -f compute1

# Restart only the compute (applies spec changes from config.json)
docker compose restart compute1

# Check container health
docker compose ps

# MinIO web console — browse stored WAL and page layers
# http://your-host:9001   user: minio / password: password

# Open a psql shell
docker exec -it docker-compose-compute1-1 \
    psql "postgresql://cloud_admin@localhost:55433/postgres"
```

---

## 8. Troubleshooting

### Compute keeps restarting / never ready

Check the compute logs first:

```bash
docker compose logs compute1 | grep -E "ERROR|FATAL|error"
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `role "X" does not exist` | `-C` connection user in `compute.sh` doesn't match base backup | Revert to `cloud_admin` in `-C` flag |
| `control_plane_api must be set` | New pageserver version requires the field | Ensure `pageserver_config/pageserver.toml` has `control_plane_api` and `control_plane_emergency_mode=true` |
| `unexpected argument '-c'` | Old `-c key=value` pageserver flag syntax removed | Use `pageserver_config/pageserver.toml` for all config |
| Compute loops but never connects | Stale tenant data from previous run | `rm -rf pageserver_config/tenants pageserver_config/deletion` and restart |

### Pageserver crash-loops

```bash
docker compose logs pageserver | tail -30
```

Check `pageserver_config/pageserver.toml` is present and valid.
The full directory is bind-mounted at `/data/.neon/` inside the container —
both `identity.toml` and `pageserver.toml` must exist.

### Auth error from application

1. Verify the password hash in `config.json` matches what you're connecting with.
2. Restart compute after changing `config.json`: `docker compose restart compute1`.
3. Check `sslmode` — if SSL is not yet configured, use `sslmode=disable`.

### SSL handshake failure

```bash
docker compose logs compute1 | grep -i ssl
```

- Cert file must be readable by uid 1000 inside the container.
- Key file must be mode 600 and owned by uid 1000.
- The `certs/` bind mount must be present in `docker-compose.yml`.

---

## File reference

```
docker-compose/
├── docker-compose.yml                          # Service definitions
├── .env                                        # Your local config (gitignored)
├── pageserver_config/
│   ├── pageserver.toml                         # Pageserver config (all settings)
│   └── identity.toml                           # Pageserver node identity (id=1234)
├── compute_wrapper/
│   ├── Dockerfile                              # Wraps the compute-node image
│   ├── shell/compute.sh                        # Startup script: creates tenant/timeline, launches compute_ctl
│   └── var/db/postgres/configs/config.json     # Postgres spec: roles, databases, GUC settings
├── certs/
│   ├── server.crt                              # TLS certificate (Let's Encrypt fullchain)
│   └── server.key                              # TLS private key (mode 600, uid 1000)
└── renew-certs.sh                              # Certbot deploy hook for cert rotation
```

# Pooled Runtime Connection Reproduction

This document reproduces the current Docker Compose setup where application runtime traffic uses PgBouncer on `neon.ixa.ink:55432`, while direct Postgres remains available on `neon.ixa.ink:55433` for migrations, schema changes, admin scripts, and anything requiring session-level Postgres behavior.

## Resulting Connection Paths

- Runtime pooled URL:
  `postgresql://cloud_admin:<password>@neon.ixa.ink:55432/starchild_frontend?sslmode=require`
- Direct/unpooled URL:
  `postgresql://cloud_admin:<password>@neon.ixa.ink:55433/starchild_frontend?sslmode=require`

Use the pooled URL for application processes such as Oxmgr, local API workers, and Vercel API replicas. Use the direct URL only for migrations, schema changes, admin scripts, advisory locks, `LISTEN/NOTIFY`, named prepared statements, or session-level GUC behavior.

This is a self-hosted PgBouncer endpoint, so the hostname is `neon.ixa.ink` and the pooled path is distinguished by port `55432`. A Neon Cloud pooled endpoint would normally use a `-pooler` host; that does not apply to this self-hosted Docker Compose endpoint.

## Files To Add Or Update

### `docker-compose.yml`

Add the PgBouncer service after `storage_broker`:

```yaml
  pgbouncer:
    restart: always
    image: pgbouncer/pgbouncer:latest
    user: "${PGBOUNCER_UID:-1000}:${PGBOUNCER_GID:-1000}"
    entrypoint: ["/opt/pgbouncer/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - 55432:5432   # pooled - use this for DATABASE_URL / app runtime via neon.ixa.ink
    volumes:
      - ./pgbouncer/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./pgbouncer/userlist.txt:/etc/pgbouncer/userlist.txt:ro
      - ./certs/server.crt:/etc/pgbouncer/server.crt:ro
      - ./certs/server.key:/etc/pgbouncer/server.key:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    depends_on:
      - compute1
```

Keep direct Postgres published on `55433`:

```yaml
    ports:
      - 55433:55433 # pg protocol handler
      - 3080:3080  # http endpoints
```

Add high file descriptor limits to the database-related services:

```yaml
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
```

For `compute1`, also keep:

```yaml
    shm_size: 512m
```

### `pgbouncer/pgbouncer.ini`

Create `pgbouncer/pgbouncer.ini`:

```ini
[databases]
starchild_frontend      = host=host.docker.internal port=55433 dbname=starchild_frontend
starchild_backend       = host=host.docker.internal port=55433 dbname=starchild_backend
starchild_backend_shadow = host=host.docker.internal port=55433 dbname=starchild_backend_shadow
coindguild              = host=host.docker.internal port=55433 dbname=coindguild
coinguild               = host=host.docker.internal port=55433 dbname=coinguild
postgres                = host=host.docker.internal port=55433 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction

default_pool_size = 20
min_pool_size = 2
reserve_pool_size = 5
reserve_pool_timeout = 3
max_client_conn = 1000

ignore_startup_parameters = extra_float_digits

server_tls_sslmode = require

client_tls_sslmode = require
client_tls_cert_file = /etc/pgbouncer/server.crt
client_tls_key_file  = /etc/pgbouncer/server.key

log_connections = 0
log_disconnections = 0
log_pooler_errors = 1

server_idle_timeout = 600
client_idle_timeout = 0
tcp_keepalive = 1
```

The backend host uses `host.docker.internal:55433` because this PgBouncer image can fail to resolve Docker service aliases internally, even when normal container DNS can resolve them.

### `pgbouncer/userlist.txt`

Create `pgbouncer/userlist.txt` with PgBouncer MD5 auth entries:

```text
"cloud_admin" "md5<md5(password + username)>"
```

For example:

```bash
printf '%s' '<password>cloud_admin' | md5sum
```

Then prefix the hash with `md5`.

### `.env`

Set runtime traffic to the pooled port and admin/migration traffic to the direct port:

```dotenv
POSTGRES_URL=postgresql://cloud_admin:<password>@neon.ixa.ink:55432/starchild_frontend?sslmode=require
POSTGRES_URL_UNPOOLED=postgresql://cloud_admin:<password>@neon.ixa.ink:55433/starchild_frontend?sslmode=require
PGBOUNCER_UID=1000
PGBOUNCER_GID=1000
```

If the TLS private key is owned by another host user, set `PGBOUNCER_UID` and `PGBOUNCER_GID` to that file owner. Check with:

```bash
stat -c '%u:%g %a %n' certs/server.key
```

Avoid making `certs/server.key` world-readable.

### `compute_wrapper/var/db/postgres/configs/config.json`

Confirm the compute has enough direct connection and memory headroom:

```json
{"name": "shared_buffers", "value": "256MB", "vartype": "string"}
{"name": "work_mem", "value": "8MB", "vartype": "string"}
{"name": "maintenance_work_mem", "value": "64MB", "vartype": "string"}
{"name": "effective_cache_size", "value": "1GB", "vartype": "string"}
{"name": "max_connections", "value": "200", "vartype": "integer"}
{"name": "max_wal_senders", "value": "20", "vartype": "integer"}
{"name": "max_replication_slots", "value": "20", "vartype": "integer"}
{"name": "wal_sender_timeout", "value": "60s", "vartype": "string"}
{"name": "idle_in_transaction_session_timeout", "value": "30s", "vartype": "string"}
{"name": "tcp_keepalives_idle", "value": "60", "vartype": "integer"}
{"name": "tcp_keepalives_interval", "value": "10", "vartype": "integer"}
{"name": "tcp_keepalives_count", "value": "6", "vartype": "integer"}
```

The current effective capacity is:

- Postgres direct connection cap: `max_connections=200`
- PgBouncer client cap: `max_client_conn=1000`
- PgBouncer server pool per database/user: `default_pool_size=20`, plus `reserve_pool_size=5`

This is enough for pooled runtime traffic from Oxmgr, local API workers, Vercel API replicas, background probes, and diagnostics, while leaving direct connections for migration/admin jobs.

## Apply And Restart

Validate Compose:

```bash
docker compose config
```

Recreate the stack:

```bash
docker compose up -d --force-recreate
```

If only PgBouncer changed:

```bash
docker compose up -d pgbouncer
```

## Verify

Check containers:

```bash
docker compose ps
```

Expected important ports:

- `pgbouncer`: `0.0.0.0:55432->5432/tcp`
- `compute1`: `0.0.0.0:55433->55433/tcp`

Check PgBouncer logs:

```bash
docker compose logs --tail 80 pgbouncer
```

Expected startup lines include:

```text
listening on 0.0.0.0:5432
process up: PgBouncer
```

Test pooled runtime path:

```bash
docker run --rm --network host postgres:latest \
  psql 'postgresql://cloud_admin:<password>@neon.ixa.ink:55432/starchild_frontend?sslmode=require' \
  -c 'select 1 as pooled_domain_ok'
```

Test direct admin/migration path:

```bash
docker run --rm --network host postgres:latest \
  psql 'postgresql://cloud_admin:<password>@neon.ixa.ink:55433/starchild_frontend?sslmode=require' \
  -c 'select 1 as direct_domain_ok'
```

Both commands should return `1`.

## Public Exposure

Because this publishes self-hosted PgBouncer on `0.0.0.0:55432`, restrict access with the host firewall or cloud security group. Allow only trusted app hosts and admin IPs. Do not leave self-hosted PgBouncer open to the internet unless the surrounding network controls are intentional.

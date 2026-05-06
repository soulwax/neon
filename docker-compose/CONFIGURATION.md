# Neon Docker Compose — Concurrent-Client Configuration

Optimised for **30–60 simultaneous read/write clients** (safe up to ~200 connections).  
Apply these changes to a fresh clone before running `docker compose up`.

---

## 1. `compute_wrapper/var/db/postgres/configs/config.json`

### Changed settings

| Setting | Default | New value | Why |
|---|---|---|---|
| `shared_buffers` | `1MB` | `256MB` | Primary Postgres read cache — 1MB is near-unusable under load |
| `max_connections` | `100` | `200` | Headroom for 60 clients + internal/replication overhead |
| `max_wal_senders` | `10` | `20` | Matches increased connection count |
| `max_replication_slots` | `10` | `20` | Matches increased connection count |
| `wal_sender_timeout` | `5s` | `60s` | 5s triggers spurious disconnects under normal write load |

### Added settings

| Setting | Value | Why |
|---|---|---|
| `work_mem` | `8MB` | Per-sort/hash buffer; 60 clients × 8MB stays within safe RAM usage |
| `maintenance_work_mem` | `64MB` | Speeds up VACUUM and CREATE INDEX under concurrent load |
| `effective_cache_size` | `1GB` | Planner hint for total available cache (OS + Postgres); improves query plans |
| `checkpoint_completion_target` | `0.9` | Spreads checkpoint I/O over 90% of the interval, reducing write spikes |
| `random_page_cost` | `1.1` | Neon fetches pages remotely like an SSD — the default 4.0 produces bad plans |
| `effective_io_concurrency` | `256` | Tells Postgres it can issue many parallel I/O requests (remote storage) |
| `max_worker_processes` | `8` | Pool for parallel query and background workers |
| `max_parallel_workers` | `8` | How many parallel workers can run simultaneously |
| `max_parallel_workers_per_gather` | `2` | Conservative — prevents one query from starving others |
| `idle_in_transaction_session_timeout` | `30s` | Kills stale transactions holding locks, freeing connections faster |
| `tcp_keepalives_idle` | `60` | Detect dead connections after 60s of silence |
| `tcp_keepalives_interval` | `10` | Retry keepalive probe every 10s |
| `tcp_keepalives_count` | `6` | Drop connection after 6 failed probes |

---

## 2. `pageserver_config/pageserver.toml`

### Changed

| Setting | Default | New value | Why |
|---|---|---|---|
| `virtual_file_io_mode` | `buffered` | `direct` | `buffered` was set for slow CI disks only; `direct` is faster on real hardware |

### Added

| Setting | Value | Why |
|---|---|---|
| `page_cache_size` | `32768` | 32768 × 8KB = 256MB in-memory page cache (default is 64MB); reduces remote fetches per client request |

> **Note:** If running on genuinely slow or rotational disks, revert `virtual_file_io_mode` to `buffered`.

---

## 3. `docker-compose.yml`

### `shm_size` on compute

```yaml
compute1:
  shm_size: 512m
```

Docker's default `/dev/shm` is 64MB, which silently caps `shared_buffers` regardless of what Postgres is configured to use. Set to at least 2× your `shared_buffers` value.

### `ulimits.nofile` on all services

```yaml
ulimits:
  nofile:
    soft: 65536
    hard: 65536
```

Added to: `pageserver`, `safekeeper1`, `safekeeper2`, `safekeeper3`, `compute1`.

Each connection and open file consumes a file descriptor. Linux's default limit (1024) would hard-cap concurrent connections well below 60 without this.

---

## Quick verification after startup

Once `compute_is_ready` logs `All computes are started`, run:

```bash
PGPASSWORD=<your_password> psql -h 127.0.0.1 -p 55433 -U cloud_admin postgres -c \
  "SELECT name, setting, unit FROM pg_settings
   WHERE name IN (
     'shared_buffers','work_mem','max_connections','effective_cache_size',
     'random_page_cost','effective_io_concurrency','max_worker_processes',
     'wal_sender_timeout','idle_in_transaction_session_timeout'
   ) ORDER BY name;"
```

Expected output (Postgres reports in its own units):

| name | setting | unit | equals |
|---|---|---|---|
| effective\_cache\_size | 131072 | 8kB | 1 GB |
| effective\_io\_concurrency | 256 | — | — |
| idle\_in\_transaction\_session\_timeout | 30000 | ms | 30 s |
| max\_connections | 200 | — | — |
| max\_worker\_processes | 8 | — | — |
| random\_page\_cost | 1.1 | — | — |
| shared\_buffers | 32768 | 8kB | 256 MB |
| wal\_sender\_timeout | 60000 | ms | 60 s |
| work\_mem | 8192 | kB | 8 MB |

---

## Scaling further

If you add more RAM or need to push beyond 60 clients:

- `shared_buffers` → 25% of total RAM (e.g. `512MB` on a 4GB host)
- `effective_cache_size` → 75% of total RAM
- `max_connections` → keep below 500; above that, add a connection pooler (PgBouncer)
- `page_cache_size` → `65536` (512MB) for heavy read workloads
- `work_mem` → lower it (e.g. `4MB`) if you increase `max_connections` significantly, to avoid memory exhaustion under peak load

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data Loss Warning

Before changing or restarting the Docker Compose stack, read `docker-compose/DO_NOT_DO_THIS.md`.

Do not force-recreate the full stateful Neon stack, prune Docker volumes, or run `docker compose down -v` unless the user explicitly confirms data can be destroyed. As of 2026-05-13 the stateful services use **named Docker volumes** (`docker-compose_pageserver_data`, `*_safekeeper{1,2,3}_data`, `*_minio_data`), so the anonymous-volume swap risk is no longer active — but the historical anonymous volumes still exist on disk and should not be pruned without an explicit OK.

## Internet Exposure and DNS

The Neon stack is internet-facing via `madtec.org`:

- `madtec.org:55433` → direct compute1 (TLS-required, `hostssl scram-sha-256`; plaintext from non-loopback rejected by a post-start `pg_hba` override in `compute_wrapper/shell/compute.sh`).
- `127.0.0.1:55432` → pgbouncer (pooled, loopback only — not exposed).
- `cloud_admin` SCRAM hash lives in `compute_wrapper/var/db/postgres/configs/config.json` (`encrypted_password`) and `pgbouncer/userlist.txt`. The plaintext password is held by the human only.

DNS for `madtec.org` is managed by a dyndns script that pushes A/AAAA updates to Cloudflare as the home IP changes. The scripts and systemd units live at `/home/soulwax/workspace/other/dyndns` (its own repo with `CLAUDE.md` + `AGENTS.md` — read those before editing). Do not assume the resolved IPs are stable; if reachability breaks, check `systemctl status cloudflare-dyndns.timer` and `dig A/AAAA madtec.org` against `curl -4/-6 ifconfig.me`. Do not edit Cloudflare records for `madtec.org` manually — the script will overwrite them.

## What This Is

Neon is an open-source serverless Postgres platform that separates compute and storage. It replaces PostgreSQL's storage layer by redistributing data across a cluster of nodes. The system consists of:

- **Pageserver** — scalable storage backend; responds to `GetPage@LSN` requests from compute, receives and replays WAL, manages tiered storage to S3
- **Safekeeper** — redundant WAL service; receives WAL from compute, durably stores it until pageserver has processed it
- **Storage Broker** — messaging between safekeepers and pageservers
- **Storage Controller** — manages a cluster of pageservers, exposes an API for managing sharded tenants as a single entity
- **Proxy** — Postgres protocol proxy/router with auth and connection management
- **Compute** — stateless PostgreSQL nodes (patched upstream Postgres) backed by Neon storage

## Build Commands

```bash
# Full debug build (Rust + patched Postgres for all supported versions: v14–v17)
make -j$(nproc) -s

# Release build
BUILD_TYPE=release make -j$(nproc) -s

# Build only Rust workspace
cargo build --all-features

# Build with testing features (required for integration tests)
CARGO_BUILD_FLAGS="--features=testing" make
```

## Running Locally

```bash
cargo neon init          # Initialize .neon directory with paths to binaries
cargo neon start         # Start pageserver, safekeeper, and broker
cargo neon tenant create --set-default
cargo neon endpoint create main
cargo neon endpoint start main
# Connect: psql -p 55432 -h 127.0.0.1 -U cloud_admin postgres

cargo neon stop          # Stop everything before running tests
```

## Testing

```bash
# Rust unit tests (preferred over plain cargo test)
cargo nextest run

# Run a single Rust test
cargo nextest run -p <crate-name> <test-name>

# Integration tests (Python/pytest)
./scripts/pytest                                    # all tests
DEFAULT_PG_VERSION=17 BUILD_TYPE=release ./scripts/pytest  # specific version/mode
./scripts/pytest test_runner/regress/test_foo.py   # single file

# Install Python deps first (needed once)
./scripts/pysync   # requires poetry >= 1.8
```

## Linting and Formatting

```bash
# Rust: clippy (matches CI)
./run_clippy.sh

# Rust: format
cargo fmt

# Python: format and lint
poetry run ruff format .
poetry run ruff check .
poetry run mypy .         # must run from repo root

# All formatters at once
./scripts/reformat

# Pre-commit hook setup
ln -s ../../pre-commit.py .git/hooks/pre-commit
# Or: make setup-pre-commit-hook
```

## Adding Cargo Dependencies

After adding a dependency to `Cargo.toml`, update the workspace-hack crate:

```bash
cargo hakari generate
cargo hakari manage-deps
```

Commit the updated `Cargo.lock` and `workspace_hack/` together.

## Source Tree Layout

| Directory | Purpose |
|-----------|---------|
| `pageserver/` | Core storage service crate |
| `safekeeper/` | WAL durability service crate |
| `proxy/` | Postgres protocol proxy crate |
| `storage_broker/` | Broker for safekeeper↔pageserver messaging |
| `storage_controller/` | Manages clusters of pageservers |
| `compute_tools/` | Tools for compute node management |
| `control_plane/` | Local control plane (`cargo neon` CLI) and integration test harness |
| `libs/` | Shared crates: `utils`, `postgres_ffi`, `metrics`, `remote_storage`, `pq_proto`, etc. |
| `pgxn/neon/` | Postgres storage manager extension (smgr API) |
| `pgxn/neon_walredo/` | Postgres WAL redo process library |
| `vendor/postgres-v{14,15,16,17}/` | Patched Postgres source trees per version |
| `test_runner/` | Python integration tests (pytest) |
| `endpoint_storage/` | Endpoint storage service |

## Code Conventions

**Rust error handling:**
- Use `anyhow` for most errors; use `thiserror` only when callers must distinguish error types
- Log errors where they are *handled*, not where they are propagated
- When adding `context()`, use present-tense verb form: `.context("get file metadata")` not `.context("could not get file metadata")`
- When logging errors: `tracing::error!("failed to {e:#}")` or `could not {e:#}`; use `{e:?}` to include backktrace
- Avoid `unwrap()` on network/disk inputs; `panic!`/`assert!` only for clear invariants
- `tokio::task::block_in_place` is disallowed (see `clippy.toml`)
- `todo!()` macro is disallowed in non-test code

**Logging levels:**
- `ERROR` — operation failed, requires human investigation
- `WARN` — unexpected but operation continued
- `INFO` — normal state changes and background operations
- `DEBUG`/`TRACE` — not printed in production; for debugging only

**Postgres terms:** Use `MB` (not `MiB`) to match PostgreSQL conventions. Key concepts: LSN (Log Sequence Number), timeline, tenant, layer files (L0/L1), checkpoint, compaction, basebackup, WAL.

**Integration test ERRORs/WARNs:** The pytest suite checks pageserver logs after each test and fails if unexpected ERROR or WARN lines appear. If your code path logs at these levels during tests, add the messages to the allowed list in the test.

## Rust Toolchain

The pinned toolchain is in `rust-toolchain.toml` (currently `1.88.0`). `rustup` picks it up automatically. Do not upgrade without coordinating with the team.

## Postgres Versions

Supported: v14, v15, v16, v17. The patched source trees live under `vendor/`. Neon-specific extensions in `pgxn/` are shared across versions but built against each version's headers separately.

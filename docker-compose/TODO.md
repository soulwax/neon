# TODO — Neon Docker Stack Hardening

Tracking follow-ups from the madtec.org exposure session (2026-05-13).

## P0 — Active danger

- [x] **Anonymous Docker volumes converted to named volumes** *(2026-05-13)*. Clean-slate migration (no data to preserve per user). Old anonymous volume IDs are now orphaned and listed under P2 cleanup. Top-level `volumes:` block added to `docker-compose.yml`; each stateful service binds a named volume:
  - `docker-compose_pageserver_data` → pageserver `/data`
  - `docker-compose_safekeeper1_data` → safekeeper1 `/data`
  - `docker-compose_safekeeper2_data` → safekeeper2 `/data`
  - `docker-compose_safekeeper3_data` → safekeeper3 `/data`
  - `docker-compose_minio_data` → minio `/data`
  - `pageserver_config/` bind mount kept (now contains only `pageserver.toml` + `identity.toml`; old contents backed up to `pageserver_config.bak.2026-05-13/`).
  - Verified fresh tenant `5a3bf36c…` + timeline `5e7f9e15…` created, all 5 real DBs present, no comma DBs.

## P1 — Security of the internet-exposed port

- [x] **Audit compute1 TLS / pg_hba** since `madtec.org:55433` is internet-facing. *(2026-05-13)*
  - `ssl = on`, certs from `/var/db/postgres/certs` confirmed.
  - `password_encryption = scram-sha-256` in spec + running PG.
  - `cloud_admin` rotated to 32-char random password; SCRAM hash stored in spec, pgbouncer userlist, and `pg_authid` in lockstep.
  - `pg_hba.conf` rewritten via post-start hook in `compute.sh`: loopback `trust`, everything else `hostssl scram-sha-256`, plaintext rejected.
  - Verified externally: plaintext rejected, wrong-password rejected, TLSv1.3 + scram accepted, pgbouncer pooled path still works.
  - Backups for rollback: `pgbouncer/userlist.txt.bak.2026-05-13`, `compute_wrapper/var/db/postgres/configs/config.json.bak.2026-05-13` (contain OLD md5 hash + comma DBs — delete once you're confident).
  - Password is held by you (the human) only — not on disk, not in shell history, not in argv (pre-hashed SCRAM was used for ALTER ROLE).

## P1 — Insurance

- [x] **Fresh `pg_dump -Fc` of each real database** *(2026-05-13)*. Files under `live_pre_restore_dumps/2026-05-13/`.
  - Note: all 5 DBs were confirmed empty (0 user tables) — expected per user. Dumps are schema-only stubs.

## P2 — Root cause

- [x] **Comma-suffixed databases traced** *(2026-05-13)*: they were hardcoded entries in `compute_wrapper/var/db/postgres/configs/config.json` (lines 44–58 in the old version). Removed from spec; they will no longer be recreated on compute restart.

## P2 — Cleanup

- [ ] **Remove orphaned anonymous Docker volumes** from prior recreations.
  - After the named-volume migration, these are no longer referenced by the live stack:
    - `755953e0990b32961a8e5d51f4fd7a72794aa853d6ac063be4e2e10b48facb1d` (old pageserver)
    - `3a2054a70cded3ceb9d84b10da9b5ccf41e0685462454c78ab6c27bfea39187e` (old safekeeper1)
    - `9a1f49f9fd5ba4fe940e2867b07a1f0d0386e9b2f9e95c5703250ae379d00977` (old safekeeper2)
    - `73833e4d56ce3237599ea4d4dfd106efd047ff6218f1032fbe52b4bf54b70f4b` (old safekeeper3)
    - `19c5ffb6e4781baeb280036c569e2d38da59697ff0fa34e38029c332097d756f` (old minio)
    - plus ~9 other anonymous volumes from earlier recreations (`docker volume ls` lists 14 total).
  - Check `docker-compose.recovery-*.yml` files don't reference any before removing.
  - **Never** `docker volume prune`.

- [ ] **Tidy UFW rules** — drop the now-dead `55432/tcp ALLOW Anywhere` entries (pgbouncer is loopback only). Requires sudo.

- [ ] **Delete rollback backups** once you're confident (~24h):
  - `docker-compose/pageserver_config.bak.2026-05-13/`
  - `docker-compose/pgbouncer/userlist.txt.bak.2026-05-13`
  - `docker-compose/compute_wrapper/var/db/postgres/configs/config.json.bak.2026-05-13`

## P3 — Reachability polish

- [ ] **Add A record `madtec.org → 79.199.223.227`** (currently AAAA only). Without it, IPv4-only clients can't resolve.
- [ ] **Confirm router NAT forwards `55433 → 192.168.2.116`** (needed for IPv4 reach).
- [ ] **Commit `docker-compose.yml`** — currently modified, not staged.

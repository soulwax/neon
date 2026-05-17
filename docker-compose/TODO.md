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

- [x] **Removed 14 orphaned anonymous Docker volumes** *(2026-05-13)*. ~6.5 GB reclaimed. Remaining anonymous volumes (`cf2e4c2…`, `1d2bd1b…`) are attached to stateless services (storage_broker, compute_is_ready) and intentionally left.

- [ ] **Tidy UFW rules** — drop the now-dead `55432/tcp ALLOW Anywhere` entries (pgbouncer is loopback only). Requires sudo. Commands:
  - `sudo ufw status numbered | grep 55432`
  - `sudo ufw delete <N>` (higher numbers first) — or `sudo ufw delete allow 55432/tcp` + `sudo ufw delete allow 55432`
  - Optional: also `sudo ufw delete allow 5432/tcp` (5432 no longer bound).

- [x] **Deleted rollback backups** *(2026-05-13)*. Old md5-era config, userlist, and pageserver bind-mount snapshots were removed once auth + named-volume changes verified.

## P3 — Reachability polish

- [x] **Add A record `madtec.org`** — confirmed present, points at `79.199.223.227` (managed by Cloudflare dyndns at `/home/soulwax/workspace/other/dyndns`).
- [x] **Confirm router NAT forwards `55433`** — IPv4 reachability verified end-to-end (TCP connect succeeded from outside DNS resolution).
- [x] **Commit hardening changes** — landed as `c2cbe6b53` on `main`. NOT pushed yet (awaiting explicit OK).
- [x] **Stale AAAA root-caused** *(2026-05-13)*. The dyndns script's configured `IFACE="wlxec750c68b7ce"` no longer exists (USB wifi adapter is gone); `detect_ipv6()` returned empty, so the updater wrote IPv4 only and AAAA was never refreshed. Source files in `/home/soulwax/workspace/other/dyndns/` updated to `IFACE="eno1"` (the active wired interface with the global IPv6). User still needs to:
  - Deploy the change to the systemd-installed copy: `sudo sed -i 's|^IFACE=.*|IFACE="eno1"|' /usr/local/bin/.env`
  - Trigger an immediate run: `sudo systemctl start cloudflare-dyndns.service && sudo tail -5 /var/log/cloudflare-dyndns.log`
  - Verify: `dig +short AAAA madtec.org` should return `2003:c6:b72a:a333:cfe1:122a:3a0:ae86` (the stable mngtmpaddr address).

## P0 — Security follow-up

- [ ] **Rotate Cloudflare API token**. The token in `/home/soulwax/workspace/other/dyndns/cloudflare-dyndns.conf` was inadvertently echoed to a Claude Code session on 2026-05-13. Rotate via the Cloudflare dashboard, update `.env` + `/usr/local/bin/.env` with the new token, then `sudo systemctl restart cloudflare-dyndns.service`.
- [ ] **Rotate cloudflared tunnel token**. The tunnel token (`fb058626-d93a-4193-931b-ede588887f2f`) was visible in `pgrep -af cloudflared` output on 2026-05-14 — it leaked into a Claude Code session. Rotate via Cloudflare Zero Trust → Networks → Tunnels → select the tunnel → refresh token, then `sudo systemctl restart cloudflared.service`.

## Reachability

- [x] **`neon.madtec.org` subdomain configured** *(2026-05-14)*. Was previously CNAMEd to an Argo Tunnel (`fb058626-...cfargotunnel.com`, proxied=true). Repointed to `madtec.org` (proxied=false, ttl=60), so it inherits the dyndns-managed A/AAAA. Verified at authoritative nameserver and via TCP connect to `:5432`, `:55432`, `:55433`. Public resolver caches catch up within 60s.
- [x] **Pgbouncer exposed on `:5432` and `:55432`** *(2026-05-14)*. Both bound to `0.0.0.0`; TLS+SCRAM enforced. `docker-compose.yml` updated.
- [ ] **Decide what to do with the existing cloudflared tunnel** (`fb058626-...`). The systemd unit is still running but `neon.madtec.org` no longer routes through it. If you still need it for HTTPS-only services, fine; otherwise consider `sudo systemctl disable --now cloudflared.service`.

# Agent Notes

Before changing or restarting this Neon Docker Compose stack, read:

- [DO_NOT_DO_THIS.md](./DO_NOT_DO_THIS.md) — data-loss guardrails
- [TODO.md](./TODO.md) — outstanding hardening / cleanup items

The short version: do not force-recreate the full stateful stack, do not prune volumes, and do not run `docker compose down -v`. As of 2026-05-13 the stateful services use **named Docker volumes** (`pageserver_data`, `safekeeper{1,2,3}_data`, `minio_data`); historical anonymous volumes still exist on disk and must not be pruned without explicit user confirmation.

## Internet Exposure (2026-05-13)

- `madtec.org:55433` → direct compute1, TLS-required (`hostssl scram-sha-256`), plaintext rejected.
- `127.0.0.1:55432` → pgbouncer, loopback only.
- `cloud_admin` password is held by the human; SCRAM hash is in `compute_wrapper/var/db/postgres/configs/config.json` and `pgbouncer/userlist.txt`.
- The pg_hba lockdown is enforced by a background hook in `compute_wrapper/shell/compute.sh` that runs after every container start (because `compute_ctl` regenerates pg_hba). If you rewrite `compute.sh`, preserve that hook.

## DNS

`madtec.org` A/AAAA records are managed by a Cloudflare dyndns script at `/home/soulwax/workspace/other/dyndns` (its own repo — `cloudflare-dyndns.service` + `.timer`, `add-subdomain.sh`, etc.). The resolved IPs change with the home connection; don't bake them into config. Do not edit Cloudflare records for `madtec.org`-family domains by hand — the script will overwrite them. If reachability breaks, check `systemctl status cloudflare-dyndns.timer` and `dig A/AAAA madtec.org` vs `curl -4/-6 ifconfig.me`.


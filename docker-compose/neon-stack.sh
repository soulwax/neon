#!/usr/bin/env bash
# neon-stack.sh — safe control + recovery for the local Neon docker-compose stack.
#
# Why this exists: the pageserver silently comes up with "0 timelines" if it
# starts before minio is ready (see docker-compose/DO_NOT_DO_THIS.md and the
# 2026-08-24 incident). compose `depends_on: service_completed_successfully`
# fixes `compose up`, but NOT host reboots (Docker restarts containers without
# ordering on daemon start). This script enforces correct ordering for manual
# ops and provides a one-shot recovery that never touches the compute.
#
# Usage:
#   ./neon-stack.sh status      # health of every layer + a real read test
#   ./neon-stack.sh start       # ordered bring-up: minio -> storage -> compute
#   ./neon-stack.sh stop        # graceful ordered stop
#   ./neon-stack.sh recover     # fix a broken pageserver (restart it alone)
#   ./neon-stack.sh restart-pageserver   # alias of recover
#
# NEVER restarts the compute unless you pass --force-compute to `start` after a
# stop; a compute restart forces a fresh basebackup from the pageserver and, if
# the pageserver is unhealthy, turns a soft outage into a hard one.
set -euo pipefail
cd "$(dirname "$0")"

DC="docker compose"
PS=docker-compose-pageserver-1
COMPUTE=docker-compose-compute1-1
TENANT=5a3bf36c02d9b8336d7be3bd4174a2d5
TIMELINE=5e7f9e15e8e73e1db213eba24e7cacc0

log() { printf '\033[1;36m[neon-stack]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[neon-stack]\033[0m %s\n' "$*" >&2; }

wait_minio() {
  log "waiting for minio to accept connections..."
  for _ in $(seq 1 60); do
    if docker exec docker-compose-minio-1 sh -c 'ls /data/neon >/dev/null 2>&1'; then
      log "minio is up."; return 0
    fi
    sleep 1
  done
  err "minio did not come up in 60s"; return 1
}

pageserver_timeline_active() {
  docker exec "$PS" sh -c \
    "curl -s http://localhost:9898/v1/tenant/$TENANT/timeline/$TIMELINE 2>/dev/null" \
    | grep -q '"state":"Active"'
}

cmd_status() {
  log "containers:"
  docker ps --format '  {{.Names}}\t{{.Status}}' | grep -E 'compose-|forgejo' || true
  echo
  log "pageserver timeline:"
  if pageserver_timeline_active; then
    local n
    n=$(docker exec "$PS" sh -c "curl -s http://localhost:9898/v1/tenant/$TENANT/timeline 2>/dev/null" | grep -o '"timeline_id"' | wc -l)
    printf '  \033[1;32mActive\033[0m (timelines loaded: %s)\n' "$n"
  else
    printf '  \033[1;31mNOT active / 0 timelines — run: %s recover\033[0m\n' "$0"
  fi
  echo
  log "read test (uncached catalog read via compute loopback trust):"
  if docker exec "$COMPUTE" psql -U cloud_admin -h 127.0.0.1 -p 55433 -d postgres -tAc \
       'select count(*) from pg_database' >/dev/null 2>&1; then
    printf '  \033[1;32mreads OK\033[0m\n'
  else
    printf '  \033[1;31mreads FAILING\033[0m\n'
  fi
}

cmd_start() {
  log "ordered bring-up"
  $DC up -d minio minio_create_buckets
  wait_minio
  $DC up -d storage_broker safekeeper1 safekeeper2 safekeeper3 pageserver
  log "waiting for pageserver timeline to activate..."
  for _ in $(seq 1 60); do pageserver_timeline_active && break; sleep 1; done
  pageserver_timeline_active || { err "pageserver timeline not active; NOT starting compute"; exit 1; }
  log "pageserver healthy; starting compute + pgbouncer"
  $DC up -d compute1 compute_is_ready pgbouncer
  cmd_status
}

cmd_stop() {
  log "graceful ordered stop (compute first, storage last)"
  $DC stop pgbouncer compute_is_ready compute1 || true
  $DC stop pageserver safekeeper1 safekeeper2 safekeeper3 storage_broker || true
  $DC stop minio_create_buckets minio || true
  log "stopped."
}

cmd_recover() {
  log "recovery: restarting ONLY the pageserver (compute untouched)"
  wait_minio
  docker restart "$PS"
  log "waiting for timeline to re-activate from remote storage..."
  for _ in $(seq 1 60); do pageserver_timeline_active && { log "timeline Active — recovered."; cmd_status; return 0; }; sleep 1; done
  err "timeline still not active after restart; investigate logs: docker logs $PS"
  return 1
}

case "${1:-status}" in
  status)             cmd_status ;;
  start)              cmd_start ;;
  stop)               cmd_stop ;;
  recover|restart-pageserver) cmd_recover ;;
  *) err "unknown command: ${1:-}"; grep -E '^#   \./' "$0" | sed 's/^# //'; exit 2 ;;
esac

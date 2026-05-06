# DO NOT DO THIS: Neon Docker Compose Data Loss

This stack is stateful. Treat it like production data unless the user explicitly says the data can be destroyed.

## Do Not Force-Recreate Stateful Services Blindly

Do not run this against the full stack:

```bash
docker compose up -d --force-recreate
```

In this repo, key Neon services can use anonymous Docker volumes for state. Force-recreating containers can attach fresh anonymous volumes and make the running database appear empty or partially reset, even though older volumes may still exist.

## Do Not Prune Volumes

Do not run:

```bash
docker volume prune
docker system prune --volumes
docker compose down -v
```

These can permanently delete recoverable Neon data.

## Before Any Restart Or Compose Change

1. Check current mounts:

```bash
docker inspect docker-compose-minio-1 docker-compose-pageserver-1 docker-compose-safekeeper1-1 docker-compose-safekeeper2-1 docker-compose-safekeeper3-1 --format '{{.Name}} {{json .Mounts}}'
```

2. Check volumes:

```bash
docker volume ls
```

3. Take logical dumps through the direct, unpooled endpoint:

```bash
pg_dump -Fc "postgresql://cloud_admin:<password>@127.0.0.1:55433/<database>?sslmode=require" -f "<database>.dump"
```

4. Prefer restarting only the service that changed:

```bash
docker compose up -d pgbouncer
```

## Safe Rule

If data matters, first add stable named volumes or bind mounts for MinIO, pageserver, and safekeepers. Then restart with normal `docker compose up -d`, not a full force recreate.


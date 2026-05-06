# Agent Notes

Before changing or restarting this Neon Docker Compose stack, read:

[DO_NOT_DO_THIS.md](./DO_NOT_DO_THIS.md)

The short version: do not force-recreate the full stateful stack, do not prune volumes, and do not run `docker compose down -v`. This setup can rely on anonymous Docker volumes, and replacing containers can make the active database point at fresh empty volumes.


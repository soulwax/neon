ARG REPOSITORY=ghcr.io/neondatabase
ARG COMPUTE_IMAGE=compute-node-v14
ARG TAG=latest

FROM $REPOSITORY/${COMPUTE_IMAGE}:$TAG

ARG COMPUTE_IMAGE

USER root
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries && \
    printf '%s\n' \
      'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250901T000000Z bullseye main' \
      'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20250901T000000Z bullseye-security main' \
      'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20250901T000000Z bullseye-updates main' \
      > /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl jq netcat-openbsd && \
    rm -rf /var/lib/apt/lists/*
#This is required for the pg_hintplan test
RUN mkdir -p /ext-src/pg_hint_plan-src /postgres/contrib/file_fdw /ext-src/postgis-src/ && chown postgres /ext-src/pg_hint_plan-src /postgres/contrib/file_fdw /ext-src/postgis-src

USER postgres

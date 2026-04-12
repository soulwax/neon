#!/bin/bash
# Run after certbot renews: copies new certs and signals Postgres to reload (no restart needed).
# Install: sudo cp renew-certs.sh /etc/letsencrypt/renewal-hooks/deploy/neon-postgres.sh
#          sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/neon-postgres.sh

CERT_DIR=/home/soulwax/neon/docker-compose/certs

cp /etc/letsencrypt/live/neon.ixa.ink/fullchain.pem "$CERT_DIR/server.crt"
cp /etc/letsencrypt/live/neon.ixa.ink/privkey.pem  "$CERT_DIR/server.key"
chown 1000:1000 "$CERT_DIR/server.crt" "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"
chmod 600 "$CERT_DIR/server.key"

# Reload Postgres — picks up new cert without dropping connections
docker exec docker-compose-compute1-1 \
    /usr/local/bin/pg_ctl reload -D /var/db/postgres/compute

#!/bin/sh
# TLS of the PostgreSQL server (compose-tls-db.yaml): the files come from ORO_DB_SSL_CERT_FILE, ORO_DB_SSL_KEY_FILE and
# ORO_DB_SSL_CA_FILE. PGDATA is tmpfs, so the entrypoint runs this after initdb on every start, before the server starts.
set -e

cat >> "$PGDATA/postgresql.conf" <<EOF
ssl = on
ssl_cert_file = '$ORO_DB_SSL_CERT_FILE'
ssl_key_file = '$ORO_DB_SSL_KEY_FILE'
ssl_ca_file = '$ORO_DB_SSL_CA_FILE'
EOF

# The first matching line wins: the host lines of initdb and of the entrypoint accept TCP without TLS, so they go.
# The local socket stays for the entrypoint.
HBA="$PGDATA/pg_hba.conf"
sed -i '/^host[[:space:]]/d' "$HBA"
for LINE in 'local all all trust' 'hostnossl all all all reject' 'hostssl all all all scram-sha-256'; do
    # The same fields, whatever the spaces between them
    awk -v line="$LINE" 'BEGIN { n = split(line, f) }
        NF == n { m = 1; for (i = 1; i <= n; i++) if ($i != f[i]) m = 0; if (m) found = 1 }
        END { exit !found }' "$HBA" || echo "$LINE" >> "$HBA"
done

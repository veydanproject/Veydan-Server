#!/usr/bin/env bash
# CQL as a role of the kit (service cql of mesh.yaml):
#   docker compose ... run --rm -T [-e CQL_AS=vrelay] cql [<host>] < statements.cql
# CQL_AS: admin (our superuser, the default: relay-admit), vrelay (vrelay's
# role: the checks of relay-join on a server that has no superuser) or
# migrate (the role of the tables). The host is a node of the mesh (its
# mesh address; this one's by default). The password goes to cqlsh in a
# credentials file of the tmpfs /tmp, never in an argument; the statements
# come on the input.
set -euo pipefail
host=${1:-${CQL_HOST:?CQL_HOST}}
[[ "$host" =~ ^[0-9.]+$ ]] || { echo "cql.sh: a host is an IPv4 address" >&2; exit 2; }
case "${CQL_AS:-admin}" in
    admin) user=${CASSANDRA_USER:?CASSANDRA_USER} file=/secrets/cassandra-admin-password ;;
    vrelay) user=${CASSANDRA_APP_USER:-vrelay} file=/secrets/cassandra-vrelay-password ;;
    migrate) user=${CASSANDRA_MIGRATE_USER:-vrelay_migrate} file=/secrets/cassandra-migrate-password ;;
    *) echo "cql.sh: CQL_AS is admin, vrelay or migrate" >&2; exit 2 ;;
esac
[ -s "$file" ] || { echo "cql.sh: no $file on this server (CQL_AS=${CQL_AS:-admin})" >&2; exit 2; }
umask 077
printf '[PlainTextAuthProvider]\nusername = %s\npassword = %s\n' "$user" "$(cat "$file")" > /tmp/cred.cql
cat > /tmp/in.cql
rc=0
cqlsh "$host" 9042 --request-timeout=120 --credentials /tmp/cred.cql -f /tmp/in.cql || rc=$?
rm -f /tmp/cred.cql /tmp/in.cql
exit "$rc"

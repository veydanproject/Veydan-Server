#!/usr/bin/env bash
# The system keyspaces of a node of the mesh (service cassandra-init of
# mesh.yaml, after kit/cassandra-init.sh): a keyspace still on SimpleStrategy,
# which knows no datacenters, goes to NetworkTopologyStrategy with a copy in
# this datacenter (spec/cluster.md 1.7). Only on the first server of the
# mesh: on the others they are NetworkTopologyStrategy already, and a region
# that joins is added by veydan-server relay-join, never here.
set -euo pipefail

host=${CASSANDRA_HOST:?CASSANDRA_HOST}
admin=${CASSANDRA_USER:?CASSANDRA_USER}
dc=${CASSANDRA_DC:?CASSANDRA_DC}
[[ "$dc" =~ ^[a-z][a-z0-9]{0,15}$ ]] || { echo "not a datacenter of the mesh: $dc" >&2; exit 1; }
# A server that joined the mesh has no superuser, and nothing to do here.
if [ ! -s /secrets/cassandra-admin-password ]; then
  echo "the system keyspaces: the cluster's (this server joined it; no superuser here)"
  exit 0
fi
umask 077
printf '[PlainTextAuthProvider]\nusername = %s\npassword = %s\n' "$admin" "$(cat /secrets/cassandra-admin-password)" > /tmp/cred.system
cql() { cqlsh "$host" 9042 --request-timeout=60 --credentials /tmp/cred.system -f "$1"; }
for ks in system_auth system_distributed system_traces; do
  printf "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" > /tmp/q.cql
  current=$(cql /tmp/q.cql)
  if grep -q SimpleStrategy <<<"$current"; then
    printf "ALTER KEYSPACE %s WITH replication = {'class': 'NetworkTopologyStrategy', '%s': 1};\n" "$ks" "$dc" > /tmp/a.cql
    cql /tmp/a.cql
    echo "$ks: SimpleStrategy -> NetworkTopologyStrategy, '$dc': 1"
  else
    echo "$ks: $(grep -o "{.*}" <<<"$current" || true)"
  fi
done
rm -f /tmp/cred.system /tmp/q.cql /tmp/a.cql

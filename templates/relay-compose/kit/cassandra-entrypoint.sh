#!/usr/bin/env bash
# Entrypoint of the cassandra service of the kit (compose.kit.yaml): the
# container runs as a user of the host, not the image's, on a read-only root.
# The image's entrypoint and compose/cassandra-entrypoint.sh edit the config
# in place, which /etc/cassandra (sticky, the image user's files) refuses to
# another user: the config is copied to the tmpfs /tmp/conf first, and
# CASSANDRA_CONF names it. The settings of /kit/overrides.yaml (the mesh's
# mesh/cassandra-overrides.yaml, one text) are put over it, but for those
# of several nodes (the hints, the traffic between datacenters): the formats
# of 5.0, the memtables off the heap, the commit log, the caches, the
# compaction, the timeouts and the guardrails are a node's own. Then the
# compose stack's own entrypoint, as it is. The same on every start.
set -euo pipefail
rm -rf /tmp/conf
cp -R /etc/cassandra /tmp/conf
export CASSANDRA_CONF=/tmp/conf
conf=$CASSANDRA_CONF/cassandra.yaml

# One `key: value` a line; the first line of that key, commented or not, is
# replaced; a key the file lacks is added at its end (as the mesh's entrypoint).
set_key() {
  local key=$1 value=$2
  if grep -qE "^(# )?${key}:" "$conf"; then
    sed -i -E "0,/^(# )?${key}:.*/s||${key}: ${value}|" "$conf"
  else
    printf '%s: %s\n' "$key" "$value" >>"$conf"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '' | '#'*) continue ;; esac
  key=${line%%:*}
  value=${line#*:}
  value=${value# }
  case "$key" in *[!a-z0-9_]* | '') echo "overrides.yaml: not a top-level key: $line" >&2; exit 1 ;; esac
  case "$key" in
    # Of several nodes: one node has no hints and no other datacenter.
    *hint* | internode_compression | *inter_dc_*) continue ;;
  esac
  set_key "$key" "$value"
done </kit/overrides.yaml

exec /bin/bash /vd/cassandra-entrypoint.sh "$@"

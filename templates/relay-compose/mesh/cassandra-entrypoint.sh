#!/usr/bin/env bash
# Entrypoint of the cassandra service of a server of the mesh (mesh.yaml):
# services/relay/deploy/cluster/cassandra/entrypoint.sh, on a read-only root.
# The config is copied to the tmpfs /tmp/conf (the container runs as a user
# of the host, which may not edit /etc/cassandra), the settings of
# overrides.yaml are put over it, auto_bootstrap set, then the image's own
# entrypoint writes the addresses, seeds, snitch, cluster name, tokens and
# cassandra-rackdc.properties from CASSANDRA_*. The same on every start.
set -euo pipefail
rm -rf /tmp/conf
cp -R /etc/cassandra /tmp/conf
export CASSANDRA_CONF=/tmp/conf
conf=$CASSANDRA_CONF/cassandra.yaml

# One `key: value` a line; the first line of that key, commented or not, is
# replaced; a key the file lacks is added at its end.
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
  set_key "$key" "$value"
done </mesh/overrides.yaml

# auto_bootstrap is a hidden setting: false only while a new region is added
# (spec/cluster.md 1.8); else the line is removed and the default (true) holds.
case "${CASSANDRA_AUTO_BOOTSTRAP:-true}" in
  false) set_key auto_bootstrap false ;;
  true) sed -i -E '/^auto_bootstrap:/d' "$conf" ;;
  *) echo "CASSANDRA_AUTO_BOOTSTRAP must be true or false" >&2; exit 1 ;;
esac

exec docker-entrypoint.sh "$@"

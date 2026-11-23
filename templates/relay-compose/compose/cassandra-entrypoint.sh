#!/usr/bin/env bash
# Entrypoint wrapper of the cassandra service. The container runs as a user
# that is not root on a read-only root, and the image's entrypoint edits the
# config in place: the config is copied to the tmpfs /tmp/conf first, and
# CASSANDRA_CONF names it (unless the caller made such a copy already and
# named it). Then password authentication and roles are turned on in
# cassandra.yaml (the official image has no switch for them), and the
# image's own entrypoint takes over. Safe on every start.
set -euo pipefail

if [ "${CASSANDRA_CONF:-/etc/cassandra}" = /etc/cassandra ]; then
  rm -rf /tmp/conf
  cp -R /etc/cassandra /tmp/conf
  export CASSANDRA_CONF=/tmp/conf
fi
conf=$CASSANDRA_CONF/cassandra.yaml
sed -i -E \
  -e 's/^authenticator:.*/authenticator: PasswordAuthenticator/' \
  -e 's/^authorizer:.*/authorizer: CassandraAuthorizer/' \
  "$conf"

exec docker-entrypoint.sh "$@"

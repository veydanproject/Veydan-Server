#!/bin/sh
# Entrypoint of the nats service of the kit (compose.kit.yaml): reads the
# passwords of the users of the modes and of the system account (files of
# this container's user, 0600) and starts the server with kit/nats.conf.
# Nothing is printed.
set -eu
NATS_SERVE_PASSWORD=$(cat /secrets/nats-serve-password)
NATS_WRITE_PASSWORD=$(cat /secrets/nats-write-password)
NATS_MIGRATE_PASSWORD=$(cat /secrets/nats-migrate-password)
NATS_SYS_PASSWORD=$(cat /secrets/nats-sys-password)
export NATS_SERVE_PASSWORD NATS_WRITE_PASSWORD NATS_MIGRATE_PASSWORD NATS_SYS_PASSWORD
exec nats-server -c /etc/nats/nats.conf "$@"

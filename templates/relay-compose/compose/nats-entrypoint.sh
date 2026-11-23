#!/bin/sh
# Entrypoint wrapper of the nats service: reads the generated passwords (files
# of this container's user) and starts the server with compose/nats.conf.
# Nothing is printed.
set -eu
NATS_SERVE_PASSWORD=$(cat /secrets/nats-serve-password)
NATS_WRITE_PASSWORD=$(cat /secrets/nats-write-password)
NATS_MIGRATE_PASSWORD=$(cat /secrets/nats-migrate-password)
NATS_SYS_PASSWORD=$(cat /secrets/nats-sys-password)
export NATS_SERVE_PASSWORD NATS_WRITE_PASSWORD NATS_MIGRATE_PASSWORD NATS_SYS_PASSWORD
exec nats-server -c /etc/nats/nats.conf "$@"

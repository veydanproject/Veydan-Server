#!/bin/sh
# One-shot job (service `secrets-init`): makes the passwords and the keys of
# the stack the first time `docker compose up` runs and never changes one
# that is there (but the two keys of a network, when .env names them), then
# gives each file to the users that read it (the users of compose.yaml).
# The folder of NATS, when it is mounted at /own/nats, goes to NATS's user.
set -eu

S=/secrets
umask 077
mkdir -p "$S"

# 32 or more letters and digits: no quoting problems in CQL, NATS or a URL.
rand() { head -c 1024 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$1"; }
make() { # make <file> <length>
  if [ ! -s "$S/$1" ]; then
    rand "$2" > "$S/$1.new" && mv "$S/$1.new" "$S/$1"
    echo "made $1"
    return 0
  fi
  return 1
}

for name in cassandra-admin-password cassandra-vrelay-password \
            nats-serve-password nats-write-password nats-migrate-password nats-sys-password; do
  make "$name" 32 || true
done
# The HMAC key of the invite codes of a team or a channel (at least 32 bytes).
make access-key 64 || true
# The bearer token of the statistics endpoint of serve and write
# (VRELAY_STATS_TOKEN_FILE): whoever reads the numbers sends it.
make stats-token 64 || true

# The keys a client (app-key) and a peer (peer-key) carry. Given in .env
# (MESH_APP_KEY, MESH_PEER_KEY: the keys of a network this relay joins),
# they are written over the file; otherwise made once, random.
key() { # key <file> <value of .env>
  if [ -n "$2" ]; then
    case "$2" in
      *[!A-Za-z0-9._~-]*) echo "$1: the key of .env may hold letters, digits and . _ ~ - only" >&2; exit 1 ;;
    esac
    if [ "$(cat "$S/$1" 2>/dev/null || true)" != "$2" ]; then
      printf '%s' "$2" > "$S/$1.new" && mv "$S/$1.new" "$S/$1"
      echo "$1: the one of .env"
      [ "$1" = app-key ] && : > "$S/.card"
    fi
  elif make "$1" 40; then
    [ "$1" = app-key ] && : > "$S/.card"
  fi
  return 0
}
key app-key "${MESH_APP_KEY:-}"
key peer-key "${MESH_PEER_KEY:-}"

# Each file to its readers: <owner>:<group> <mode> <file>...
own() {
  o=$1 m=$2
  shift 2
  for f in "$@"; do chown "$o" "$S/$f" && chmod "$m" "$S/$f"; done
}
own 999:999 0400 cassandra-admin-password                  # cassandra-init, vrelay migrate
own 999:65532 0440 cassandra-vrelay-password               # cassandra-init sets it, vrelay signs in
own 10001:65532 0440 nats-serve-password nats-write-password  # NATS, vrelay
own 10001:999 0440 nats-migrate-password                   # NATS, vrelay migrate
own 10001:10001 0400 nats-sys-password                     # NATS
own 65532:65532 0400 app-key peer-key access-key stats-token  # vrelay
chown 0:0 "$S"
chmod 0755 "$S"

if [ -d /own/nats ]; then
  chown 10001:10001 /own/nats
  chmod 0700 /own/nats
fi
echo "secrets: in place"

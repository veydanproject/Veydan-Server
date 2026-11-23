#!/bin/sh
# One-shot job (service `relay-init`, profile relay), before vrelay and
# Caddy: checks the names of the relay (RELAY_HOST and RELAY_ALIASES of
# .env) and writes them as the site of Caddy (sites.caddy, imported by
# compose/Caddyfile), gives the files of access (/access) to vrelay's user
# and the folders of Caddy to Caddy's, and prints the card of the relay the
# first time there is one.
#
#   docker compose run --rm --no-deps relay-init card [<invite code>]
#
# prints it again: the relay's address, its app key and the link the app
# takes (veydan://server/…, as `veydan-server card` of the server kit makes
# it: <id> the first 16 hex of the sha256 of the relay's URL).
set -eu

host=$(printf '%s' "${RELAY_HOST:-}" | tr 'A-Z' 'a-z')
if [ -z "$host" ]; then
  echo "RELAY_HOST is empty: put the name of the relay in .env (compose/.env.example), then docker compose up -d" >&2
  exit 1
fi
name_ok() {
  case "$1" in
    '' | *[!a-z0-9.-]* | .* | *. | *..*) echo "$2=$1 is not a host name" >&2; exit 1 ;;
  esac
}
name_ok "$host" RELAY_HOST
# The names of the site of Caddy: the host and every alias.
sites=$host
for a in $(printf '%s' "${RELAY_ALIASES:-}" | tr 'A-Z,' 'a-z '); do
  name_ok "$a" RELAY_ALIASES
  sites="$sites, $a"
done
mode=${ACCESS_MODE:-open}
case "$mode" in open | team | channel) ;; *) echo "ACCESS_MODE=$mode: open, team or channel" >&2; exit 1 ;; esac

card() { # card [<invite code>]
  url="wss://$host"
  id=$(printf '%s' "$url" | sha256sum | cut -c1-16)
  key=$(cat /secrets/app-key)
  q="u=wss%3A%2F%2F$host&k=$key&p=off&n="
  [ "$mode" = open ] || q="$q&a=$mode"
  if [ -n "${1:-}" ]; then
    case "$1" in *[!A-Za-z0-9._~-]*) echo "not an invite code: $1" >&2; exit 1 ;; esac
    q="$q&inv=$1"
  fi
  echo "The relay:    $url"
  echo "Its app key:  $key"
  echo "The link for the app:"
  echo "  veydan://server/$id?$q"
}

if [ "${1:-}" = card ]; then
  card "${2:-}"
  exit 0
fi

# The folders are vrelay's and Caddy's to write: a link put there by them
# must not take this root (it has /secrets) anywhere. A link is refused, a
# file is made only where none is (noclobber: O_EXCL, which a link put in
# between makes fail), and the owners are set on the links themselves
# (chown -h), never on what they point to.
umask 077
set -C
for f in /access/members.txt /access/invites.json /own/caddy-config/sites.caddy; do
  if [ -L "$f" ]; then
    echo "$f is a symbolic link: refused (a link there was not put by this stack; remove it)" >&2
    exit 1
  fi
done
[ -e /access/members.txt ] || : > /access/members.txt
[ -e /access/invites.json ] || echo '[]' > /access/invites.json
chown -R -h 65532:65532 /access
chmod 0700 /access
rm -f /own/caddy-config/sites.caddy
printf '%s {\n\timport relay\n}\n' "$sites" > /own/caddy-config/sites.caddy
set +C
for d in /own/caddy-data /own/caddy-config; do
  chown -R -h 10002:10002 "$d"
  chmod 0700 "$d"
done

if [ -e /secrets/.card ]; then
  card
  rm -f /secrets/.card
else
  echo "relay $host: in place (the card: docker compose run --rm --no-deps relay-init card)"
fi

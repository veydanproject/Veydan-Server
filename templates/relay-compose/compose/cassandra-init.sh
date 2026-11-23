#!/usr/bin/env bash
# The roles of Cassandra (one-shot services cassandra-init and
# cassandra-grant of compose.yaml; the server kit runs the same, before and
# after `vrelay migrate`). The same every time.
#
#   1. The default superuser cassandra/cassandra does not survive: our own
#      superuser ($CASSANDRA_USER, /secrets/cassandra-admin-password) is made
#      with it, then it can log in no more (no login, no superuser, a random
#      password).
#   2. vrelay's own role ($CASSANDRA_APP_USER, /secrets/cassandra-vrelay-password):
#      no superuser; once the keyspace exists, SELECT and MODIFY on it, and
#      nothing else.
#   3. The default login is tried last: if it still works, this fails.
#
# The passwords go to cqlsh in a credentials file in /tmp (a tmpfs of the
# container, mode 0600) and the statements in a file: never in an argument,
# never on the output.
set -euo pipefail

host=${CASSANDRA_HOST:-cassandra}
admin=${CASSANDRA_USER:?CASSANDRA_USER}
app=${CASSANDRA_APP_USER:?CASSANDRA_APP_USER}
ks=${VRELAY_KEYSPACE:?VRELAY_KEYSPACE}
wait_s=${CASSANDRA_INIT_WAIT:-180}
admin_pass=$(cat /secrets/cassandra-admin-password)
app_pass=$(cat /secrets/cassandra-vrelay-password)
for v in "$admin" "$app" "$ks"; do
  [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "not a name of CQL: $v" >&2; exit 1; }
done
for v in "$admin_pass" "$app_pass"; do
  [[ "$v" =~ ^[A-Za-z0-9]{32,}$ ]] || { echo "a password of /secrets is not 32 or more letters and digits" >&2; exit 1; }
done

umask 077
creds() { # creds <user> <password> → the path of a credentials file
  local f=/tmp/cred.$1
  printf '[PlainTextAuthProvider]\nusername = %s\npassword = %s\n' "$1" "$2" > "$f"
  printf '%s' "$f"
}
cql() { # cql <user> <password> <file of statements>
  cqlsh "$host" 9042 --request-timeout=60 --credentials "$(creds "$1" "$2")" -f "$3"
}
ping_as() {
  printf 'SELECT release_version FROM system.local;\n' > /tmp/ping.cql
  cql "$1" "$2" /tmp/ping.cql >/dev/null 2>&1
}

deadline=$((SECONDS + wait_s))
mode=
while [ -z "$mode" ]; do
  if ping_as "$admin" "$admin_pass"; then mode=ready
  elif ping_as cassandra cassandra; then mode=first
  elif [ "$SECONDS" -ge "$deadline" ]; then echo "no login works after ${wait_s}s" >&2; exit 1
  else sleep 3; fi
done

if [ "$mode" = first ]; then
  echo "first start: superuser $admin in place of cassandra"
  printf "CREATE ROLE IF NOT EXISTS \"%s\" WITH PASSWORD = '%s' AND SUPERUSER = true AND LOGIN = true;\n" "$admin" "$admin_pass" > /tmp/admin.cql
  cql cassandra cassandra /tmp/admin.cql
fi
# (Cassandra takes a new password of a role once in 5 s: each is set only
# when it is not what it should be.)
if ping_as cassandra cassandra; then
  junk=$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)
  printf "ALTER ROLE cassandra WITH LOGIN = false AND SUPERUSER = false AND PASSWORD = '%s';\n" "$junk" > /tmp/default.cql
  cql "$admin" "$admin_pass" /tmp/default.cql
  echo "role cassandra: no login, no superuser"
fi
printf "SELECT role FROM system_auth.roles WHERE role = '%s';\n" "$app" > /tmp/app.cql
if ! cql "$admin" "$admin_pass" /tmp/app.cql | grep -qw "$app"; then
  printf "CREATE ROLE \"%s\" WITH PASSWORD = '%s' AND SUPERUSER = false AND LOGIN = true;\n" "$app" "$app_pass" > /tmp/roles.cql
  cql "$admin" "$admin_pass" /tmp/roles.cql
  echo "role $app: made"
elif ! ping_as "$app" "$app_pass"; then
  printf "ALTER ROLE \"%s\" WITH PASSWORD = '%s' AND SUPERUSER = false AND LOGIN = true;\n" "$app" "$app_pass" > /tmp/roles.cql
  cql "$admin" "$admin_pass" /tmp/roles.cql
  echo "role $app: its password set again"
fi
printf "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" > /tmp/ks.cql
if cql "$admin" "$admin_pass" /tmp/ks.cql | grep -qw "$ks"; then
  printf 'GRANT SELECT ON KEYSPACE "%s" TO "%s";\nGRANT MODIFY ON KEYSPACE "%s" TO "%s";\n' "$ks" "$app" "$ks" "$app" > /tmp/grant.cql
  cql "$admin" "$admin_pass" /tmp/grant.cql
  echo "role $app: SELECT and MODIFY on keyspace $ks"
else
  echo "role $app: no keyspace $ks yet (vrelay migrate makes it; then this again)"
fi
rm -f /tmp/*.cql
if ping_as cassandra cassandra; then
  echo "the default login cassandra/cassandra still works" >&2
  exit 1
fi
rm -f /tmp/cred.*
ping_as "$admin" "$admin_pass" || { echo "superuser $admin: no login" >&2; exit 1; }
ping_as "$app" "$app_pass" || { echo "role $app: no login" >&2; exit 1; }
rm -f /tmp/cred.* /tmp/ping.cql
echo "cassandra roles: ok (cassandra cannot log in)"

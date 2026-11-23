#!/usr/bin/env bash
# The roles of Cassandra on a server of the kit (service cassandra-init of
# compose.kit.yaml, in place of compose/cassandra-init.sh). Run by
# components/vrelay.sh before and after `vrelay migrate`; the same every time.
#
#   1. The default superuser cassandra/cassandra does not survive: our own
#      superuser ($CASSANDRA_USER, /secrets/cassandra-admin-password) is made
#      with it, then it can log in no more (no login, no superuser, a random
#      password).
#   2. vrelay's own role ($CASSANDRA_APP_USER, /secrets/cassandra-vrelay-password):
#      no superuser; once the keyspace exists, SELECT and MODIFY on it, and
#      nothing else.
#   3. In the mesh ($CASSANDRA_MIGRATE_USER, /secrets/cassandra-migrate-password):
#      the role that makes the tables on a server that joined the mesh,
#      which is never given the superuser: no superuser; CREATE on the
#      keyspaces (CREATE KEYSPACE IF NOT EXISTS asks it), ALTER, SELECT and
#      MODIFY on vrelay's.
#   4. The default login is tried last: if it still works, this fails.
#
# A server that joined the mesh has no /secrets/cassandra-admin-password:
# the roles are the cluster's, made by the first server, and here they are
# only checked (each logs in; the default login does not).
#
# The passwords go to cqlsh in a credentials file in /tmp (a tmpfs of the
# container, mode 0600) and the statements in a file: never in an argument,
# never on the output.
set -euo pipefail

host=${CASSANDRA_HOST:-cassandra}
admin=${CASSANDRA_USER:?CASSANDRA_USER}
app=${CASSANDRA_APP_USER:?CASSANDRA_APP_USER}
mig=${CASSANDRA_MIGRATE_USER:-}
ks=${VRELAY_KEYSPACE:?VRELAY_KEYSPACE}
wait_s=${CASSANDRA_INIT_WAIT:-180}
admin_pass=""
[ -f /secrets/cassandra-admin-password ] && admin_pass=$(cat /secrets/cassandra-admin-password)
app_pass=$(cat /secrets/cassandra-vrelay-password)
mig_pass=""
# A server of the mesh that joined with a key of the first form has the
# superuser and no password of the role migrate: it makes nothing of it.
if [ -n "$mig" ] && [ -n "$admin_pass" ] && [ ! -s /secrets/cassandra-migrate-password ]; then mig=""; fi
[ -z "$mig" ] || mig_pass=$(cat /secrets/cassandra-migrate-password)
for v in "$admin" "$app" "$ks" ${mig:+"$mig"}; do
  [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "not a name of CQL: $v" >&2; exit 1; }
done
for v in ${admin_pass:+"$admin_pass"} "$app_pass" ${mig_pass:+"$mig_pass"}; do
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

if [ -z "$admin_pass" ]; then
  # A server that joined the mesh: no superuser here, the roles checked.
  [ -n "$mig" ] || { echo "no /secrets/cassandra-admin-password: only a server that joined a mesh has none" >&2; exit 1; }
  deadline=$((SECONDS + wait_s))
  until ping_as "$app" "$app_pass"; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "role $app: no login after ${wait_s}s" >&2; exit 1; }
    sleep 3
  done
  ping_as "$mig" "$mig_pass" || { echo "role $mig: no login (made by the first server of the mesh: veydan-server rerun there)" >&2; exit 1; }
  if ping_as cassandra cassandra; then
    echo "the default login cassandra/cassandra still works" >&2
    exit 1
  fi
  rm -f /tmp/cred.* /tmp/ping.cql
  echo "cassandra roles: ok, the cluster's ($app and $mig log in, cassandra cannot; no superuser on this server)"
  exit 0
fi

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
if [ -n "$mig" ]; then
  printf "SELECT role FROM system_auth.roles WHERE role = '%s';\n" "$mig" > /tmp/mig.cql
  if ! cql "$admin" "$admin_pass" /tmp/mig.cql | grep -qw "$mig"; then
    printf "CREATE ROLE \"%s\" WITH PASSWORD = '%s' AND SUPERUSER = false AND LOGIN = true;\n" "$mig" "$mig_pass" > /tmp/roles.cql
    cql "$admin" "$admin_pass" /tmp/roles.cql
    echo "role $mig: made"
  elif ! ping_as "$mig" "$mig_pass"; then
    printf "ALTER ROLE \"%s\" WITH PASSWORD = '%s' AND SUPERUSER = false AND LOGIN = true;\n" "$mig" "$mig_pass" > /tmp/roles.cql
    cql "$admin" "$admin_pass" /tmp/roles.cql
    echo "role $mig: its password set again"
  fi
  # CREATE KEYSPACE IF NOT EXISTS asks CREATE on all keyspaces, even when
  # the keyspace is there; no other keyspace is read or changed by it.
  printf 'GRANT CREATE ON ALL KEYSPACES TO "%s";\n' "$mig" > /tmp/grant.cql
  cql "$admin" "$admin_pass" /tmp/grant.cql
fi
printf "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" > /tmp/ks.cql
if cql "$admin" "$admin_pass" /tmp/ks.cql | grep -qw "$ks"; then
  printf 'GRANT SELECT ON KEYSPACE "%s" TO "%s";\nGRANT MODIFY ON KEYSPACE "%s" TO "%s";\n' "$ks" "$app" "$ks" "$app" > /tmp/grant.cql
  cql "$admin" "$admin_pass" /tmp/grant.cql
  echo "role $app: SELECT and MODIFY on keyspace $ks"
  if [ -n "$mig" ]; then
    printf 'GRANT ALTER ON KEYSPACE "%s" TO "%s";\nGRANT SELECT ON KEYSPACE "%s" TO "%s";\nGRANT MODIFY ON KEYSPACE "%s" TO "%s";\n' \
      "$ks" "$mig" "$ks" "$mig" "$ks" "$mig" > /tmp/grant.cql
    cql "$admin" "$admin_pass" /tmp/grant.cql
    echo "role $mig: CREATE on the keyspaces, ALTER, SELECT and MODIFY on keyspace $ks"
  fi
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
[ -z "$mig" ] || ping_as "$mig" "$mig_pass" || { echo "role $mig: no login" >&2; exit 1; }
rm -f /tmp/cred.* /tmp/ping.cql
echo "cassandra roles: ok (cassandra cannot log in)"

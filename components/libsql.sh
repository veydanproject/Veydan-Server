# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# libsql-server (sqld): the index of the blobs this media server stored.
# Every media server runs its own. Everything in /opt/libsql:
#   bin/sqld  etc/libsql.service  data/
# Listens on 127.0.0.1:8080: the programs of this server talk to it,
# nobody else reaches it.
# Sourced by run.sh.

L=/opt/libsql
say "libsql: $LIBSQL_VERSION (the index of this server's media)"

ensure_user libsql "$L"
mkdirp "$L" 0755 root:root
mkdirp "$L/bin" 0755 root:root
mkdirp "$L/etc" 0750 root:libsql
mkdirp "$L/data" 0750 libsql:libsql

if [ "$DRY" = 1 ]; then
    printf '   + sqld %s → %s/bin/sqld\n' "$LIBSQL_VERSION" "$L"
elif [ "$(cat "$L/bin/.version" 2>/dev/null)" != "$LIBSQL_VERSION" ] || [ ! -x "$L/bin/sqld" ]; then
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/sqld.tar.xz" \
        "https://github.com/tursodatabase/libsql/releases/download/$LIBSQL_VERSION/libsql-server-x86_64-unknown-linux-gnu.tar.xz"
    echo "$LIBSQL_SHA256  $tmp/sqld.tar.xz" | sha256sum -c --quiet - \
        || die "sqld $LIBSQL_VERSION: checksum does not match versions.conf"
    tar -xJf "$tmp/sqld.tar.xz" -C "$tmp"
    install -m 0755 "$tmp/libsql-server-x86_64-unknown-linux-gnu/sqld" "$L/bin/sqld"
    echo "$LIBSQL_VERSION" > "$L/bin/.version"
    rm -rf "$tmp"
fi

render "$HERE/templates/systemd/libsql.service" "$L/etc/libsql.service" 0644 root:root
link_unit "$L/etc/libsql.service"
run systemctl restart libsql

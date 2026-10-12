# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# blossom-server (hzrd149) on Deno 2. Everything in /opt/blossom:
#   deno/deno  app/ (the server, read-only)  cache/ (DENO_DIR)
#   etc/config.yml  etc/blossom.env (S3 keys, index token)  etc/blossom.service
#   data/ (upload buffer; local blobs when there is no S3)
# Listens on 127.0.0.1:3000; only nginx is in front of it. Files go to the
# bucket of the network (or this disk); the index of what this server
# stored is its own sqld. A file uploaded through another media server is
# served by nginx straight from the bucket (components/nginx.sh).
# Sourced by run.sh.

B=/opt/blossom
say "blossom: $BLOSSOM_COMMIT on deno $DENO_VERSION"

ensure_user blossom "$B"
mkdirp "$B" 0755 root:root
mkdirp "$B/deno" 0755 root:root
mkdirp "$B/etc" 0750 root:blossom
mkdirp "$B/data" 0750 blossom:blossom
mkdirp "$B/cache" 0750 blossom:blossom

if [ "$DRY" = 1 ]; then
    printf '   + deno %s → %s/deno/deno, blossom-server %s → %s/app\n' \
        "$DENO_VERSION" "$B" "$BLOSSOM_COMMIT" "$B"
else
    # Deno: the official build, checked by its sha256.
    if [ "$("$B/deno/deno" --version 2>/dev/null | awk 'NR==1 {print "v"$2}')" != "$DENO_VERSION" ]; then
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/deno.zip" \
            "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-x86_64-unknown-linux-gnu.zip"
        echo "$DENO_SHA256  $tmp/deno.zip" | sha256sum -c --quiet - \
            || die "deno $DENO_VERSION: checksum does not match versions.conf"
        unzip -q -o "$tmp/deno.zip" -d "$tmp"
        install -m 0755 "$tmp/deno" "$B/deno/deno"
        rm -rf "$tmp"
    fi

    # The server: the pinned commit. Owned by root, so the service cannot
    # change its own code.
    if [ "$(git -C "$B/app" rev-parse HEAD 2>/dev/null)" != "$BLOSSOM_COMMIT" ]; then
        [ -d "$B/app/.git" ] || git clone --quiet "$BLOSSOM_REPO" "$B/app"
        git -C "$B/app" fetch --quiet origin
        git -C "$B/app" checkout --quiet --force "$BLOSSOM_COMMIT"
    fi
    # Modules for the lock file, into the cache the service reads. Run as
    # blossom: the native libsql and sharp parts land in the same cache.
    #
    # Where jsr.io or registry.npmjs.org are slow or closed (Russia, say),
    # the cache of another server of the mesh does the same: on it
    #   tar -C /opt/blossom -czf blossom-cache.tar.gz cache
    # and put the file into the kit as blossom-cache.tar.gz.
    if [ -f "$HERE/blossom-cache.tar.gz" ]; then
        say "blossom: modules from deploy/blossom-cache.tar.gz"
        tar -xzf "$HERE/blossom-cache.tar.gz" -C "$B"
        chown -R blossom:blossom "$B/cache"
    fi
    say "blossom: fetching modules (from jsr.io and registry.npmjs.org; a few minutes)"
    ( cd "$B/app" && timeout 1200 runuser -u blossom -- env DENO_DIR="$B/cache" HOME="$B/data" \
        "$B/deno/deno" install --frozen --entrypoint main.ts ) \
        || die "blossom: deno could not fetch the modules. Check: curl -sI https://jsr.io https://registry.npmjs.org — or bring the cache of another server (see components/blossom.sh)"
fi

# The index: this server's own sqld (components/libsql.sh), on the
# loopback. Storage: the bucket of the network, or this disk when the
# network names none (then the other media servers ask this one).
V_DATABASE="  url: \"http://127.0.0.1:8080\""
if [ -n "$S3_ENDPOINT" ]; then
    V_STORAGE_BACKEND=s3
else
    V_STORAGE_BACKEND=local
    say "blossom: files on this disk ($B/data/blobs)"
fi
# An older install (its "local" mode) wrote its own config file.
[ -f "$(target "$B/etc/config-local.yml")" ] && run rm -f "$B/etc/config-local.yml"
V_MEDIA_FQDN=$MEDIA_FQDN
V_NETWORK=${NETWORK^}
V_BLOSSOM_CONFIG=$B/etc/config.yml
V_S3_ENDPOINT=${S3_ENDPOINT:-https://s3.example.org}
V_S3_BUCKET=${S3_BUCKET:-media}
V_S3_REGION=${S3_REGION:-auto}
render "$HERE/templates/blossom.yml" "$B/etc/config.yml" 0640 root:blossom keep "# blossom-server of " "publicDomain: "

# The secrets config.yml reads from the environment. From server.conf, so
# a rerun applies a changed key.
{
    echo "# Environment of blossom, made by run.sh from server.conf; config.yml"
    echo "# reads the keys from here. Edits are lost on the next run."
    printf 'S3_ACCESS_KEY=%s\n' "$S3_ACCESS_KEY"
    printf 'S3_SECRET_KEY=%s\n' "$S3_SECRET_KEY"
} | put "$B/etc/blossom.env" 0640 root:blossom

render "$HERE/templates/systemd/blossom.service" "$B/etc/blossom.service" 0644 root:root
link_unit "$B/etc/blossom.service"
run systemctl restart blossom

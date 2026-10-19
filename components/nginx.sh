# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# nginx in front of everything, and the certificates.
#
# Our files live in /opt/veydan/nginx; nginx sees them through one line in
# /etc/nginx/conf.d/veydan.conf. A site on 443 is switched on only once its
# certificate exists, so nginx can always start.
# Sourced by run.sh.

N=$STATE/nginx
V_ACME=$STATE/acme
ACME=$STATE/acme
# Where the WebSockets of the relay go: vguard, which components/guard.sh
# puts up in front of strfry (a relay never goes without it).
V_RELAY_WS=${V_RELAY_WS:-127.0.0.1:7777}
say "nginx: $HOSTS"

# nginx workers (www-data) pass through /opt/veydan to the ACME directory
# only; every file in it stays root's.
[ "$DRY" = 1 ] || chmod 0711 "$STATE"
mkdirp "$ACME" 0755 root:root

echo "include $N/*.conf;" | put /etc/nginx/conf.d/veydan.conf 0644 root:root

# Debian's "Welcome to nginx!" site answers any name and the bare IP. Off:
# a request for a name this server does not serve gets no page at all (a
# CDN pointed at the IP would cache that page as our site).
if [ -L "$(target /etc/nginx/sites-enabled/default)" ] || [ -f "$(target /etc/nginx/sites-enabled/default)" ]; then
    run rm -f /etc/nginx/sites-enabled/default
fi
cat <<EOF | put "$N/01-default.conf" 0600 root:root
# Made by run.sh: names and addresses this server does not serve.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
# The signing of requests to the bucket (templates/njs/s3.js) is in the
# http context, so the media site can use it.
mkdirp "$STATE/njs" 0755 root:root
put "$STATE/njs/s3.js" 0644 root:root < "$HERE/templates/njs/s3.js"
V_NJS=$STATE/njs
render "$HERE/templates/nginx/http.conf" "$N/00-http.conf" 0600 root:root

# The client behind Cloudflare: nginx takes CF-Connecting-IP, but only from
# Cloudflare's own addresses (anyone else could write the header). Without
# this every limit counts a whole Cloudflare edge as one client. The ranges
# come fresh from cloudflare.com, or from the kit when that fails.
cf=$(mktemp)
if [ "$DRY" != 1 ] && curl -fsS -m 10 https://www.cloudflare.com/ips-v4 > "$cf" && echo >> "$cf" \
        && curl -fsS -m 10 https://www.cloudflare.com/ips-v6 >> "$cf"; then
    :
else
    cp "$HERE/templates/cloudflare-ips.txt" "$cf"
fi
{
    echo "# Cloudflare edge ranges. Made by run.sh."
    grep -E '^[0-9a-fA-F:.]+/[0-9]+$' "$cf" | sed 's/.*/set_real_ip_from &;/'
    echo "real_ip_header CF-Connecting-IP;"
} | put "$N/05-cloudflare.conf" 0600 root:root
rm -f "$cf"
# An older install kept the relay key here.
[ -f "$(target "$N/10-relay-key.conf")" ] && run rm -f "$N/10-relay-key.conf"

# Media: with MEDIA_UPLOAD_KEY=required everything needs one of the two keys
# (the peer key is for the other media servers) EXCEPT a download of a blob by
# its hash, the list of a key, the index and the CORS preflight. It fails
# closed: blossom matches its routes without regard to case, so a list of
# writes to deny (PUT /UPLOAD) would be bypassed. The method is matched
# case-sensitively, the hash and the extension in both cases. With "open" (a
# network whose apps do not carry the key yet) neither the map nor the guards
# exist.
MEDIA_KEY_MAP="" V_MEDIA_KEY_GUARD=""
if [ "$MEDIA_UPLOAD_KEY" = required ]; then
    MEDIA_KEY_MAP=$(cat <<'EOF'
# Media: all but a download needs the app key or the peer key (MEDIA_UPLOAD_KEY=required).
# The first rule that matches wins; the last character is veydan_relay_denied (1: no key).
map "$request_method$uri$veydan_relay_denied" $veydan_media_denied {
    "~^(GET|HEAD)/[0-9a-fA-F]{64}(\.[a-zA-Z0-9]+)?[01]$" 0;
    "~^GET/list/[0-9a-fA-F]{64}[01]$" 0;
    "~^GET/[01]$" 0;
    "~^OPTIONS/.*[01]$" 0;
    "~1$" 1;
    default 0;
}
EOF
)
    V_MEDIA_KEY_GUARD='        if ($veydan_media_denied) {
            return 401;
        }'
fi

# The keys nginx compares, from server.conf. The relay takes the app key
# (what the app sends) or the peer key (the other relays, vpush); with the
# peer key it is a peer to vguard.
cat <<EOF | put "$N/10-keys.conf" 0600 root:root
# Keys of the network (server.conf). Made by run.sh.
map \$arg_key \$veydan_key_query {
    default 0;
    "$MESH_APP_KEY" 1;
    "$MESH_PEER_KEY" 1;
}
map \$http_x_api_key \$veydan_key_header {
    default 0;
    "$MESH_APP_KEY" 1;
    "$MESH_PEER_KEY" 1;
}
map "\$veydan_key_query\$veydan_key_header" \$veydan_relay_denied {
    "00"    1;
    default 0;
}
$MEDIA_KEY_MAP
# The peer key, alone: the other relays and vpush. The relay tells vguard
# (X-Veydan-Role) that such a connection reads everything; with the app
# key the read policy holds. Empty: no header at all.
map \$arg_key \$veydan_peer_query {
    default 0;
    "$MESH_PEER_KEY" 1;
}
map \$http_x_api_key \$veydan_peer_header {
    default 0;
    "$MESH_PEER_KEY" 1;
}
map "\$veydan_peer_query\$veydan_peer_header" \$veydan_relay_role {
    "00"    "";
    default peer;
}
EOF

# Port 80: ACME answers and a redirect, for every name of this server.
cat <<EOF | put "$N/20-http-80.conf" 0600 root:root
# Made by run.sh.
server {
    listen 80;
    listen [::]:80;
    server_name $HOSTS$ALIAS_HOSTS;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

cert_paths() { # cert_paths <host>  → sets V_CERT, V_CERT_KEY
    if [ "$TLS" = letsencrypt ]; then
        V_CERT=/etc/letsencrypt/live/$1/fullchain.pem
        V_CERT_KEY=/etc/letsencrypt/live/$1/privkey.pem
    else
        V_CERT=$STATE/tls/$1/fullchain.pem
        V_CERT_KEY=$STATE/tls/$1/privkey.pem
    fi
}

# The resolvers of this machine (IPv4): a name in a site that is looked up
# when asked, not when nginx starts, needs them named.
V_RESOLVER=$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null || true)
V_RESOLVER=${V_RESOLVER:-1.1.1.1 8.8.8.8 }

# A blob this media server has not got: the bucket of the network, by its
# hash, with a signed request; or, with files on disks, the next media
# server of the network; or nothing.
V_BLOB_FALLBACK="    location @elsewhere { return 404; }"
V_BLOB_FALLBACK_NOTE="nothing: this is the one media server, with files on its disk"
if has media && [ -n "$S3_ENDPOINT" ]; then
    V_S3_SCHEME=${S3_ENDPOINT%%://*}
    V_S3_HOST=${S3_ENDPOINT#*://}; V_S3_HOST=${V_S3_HOST%/}
    V_S3_BUCKET=$S3_BUCKET
    # The name for TLS (the host without its port).
    V_S3_NAME=${V_S3_HOST%%:*}
    V_BLOB_FALLBACK=$(render_text "$HERE/templates/nginx/blob-bucket.conf")
    V_BLOB_FALLBACK_NOTE="the bucket of the network has it under its hash, read with a signed request"
elif has media && [ -n "$MEDIA_PEERS" ]; then
    V_MESH_NEXT=${MEDIA_PEERS%% *}
    V_BLOB_FALLBACK=$(render_text "$HERE/templates/nginx/blob-mesh.conf")
    V_BLOB_FALLBACK_NOTE="the next media server of the network ($V_MESH_NEXT) is asked"
fi
# The keys the signing reads, in a file of nginx's own (root reads the
# config; the workers get the variables from the master).
if has media && [ -n "$S3_ENDPOINT" ]; then
    cat <<EOF | put "$N/11-bucket.conf" 0600 root:root
# The bucket of the network, for the media site (server.conf). Made by run.sh.
map \$host \$s3_key    { default "$S3_ACCESS_KEY"; }
map \$host \$s3_secret { default "$S3_SECRET_KEY"; }
map \$host \$s3_region { default "$S3_REGION"; }
map \$host \$s3_host   { default "$V_S3_HOST"; }
EOF
elif [ -f "$(target "$N/11-bucket.conf")" ]; then
    run rm -f "$N/11-bucket.conf"
fi

# What a kit with more components puts into the sites (hooks/nginx.sh, not
# in the public kit): the push site renders V_VLINK_LOCATION.
V_VLINK_LOCATION=""
# shellcheck disable=SC1091
[ -f "$HERE/hooks/nginx.sh" ] && . "$HERE/hooks/nginx.sh"

# The sites of this server, "<kind>:<fqdn>" each: the three of the kit and
# what a component added (EXTRA_SITES, with templates/nginx/<kind>.conf).
site_list() {
    has relay && echo "relay:$RELAY_FQDN"
    has media && echo "media:$MEDIA_FQDN"
    has vpush && echo "vpush:$VPUSH_FQDN"
    local s
    for s in $EXTRA_SITES; do echo "$s"; done
    return 0
}

# The names a role answers under: its own and its aliases.
role_aliases() { # role_aliases <relay|media|vpush>
    case $1 in
        relay) printf '%s' "$RELAY_ALIAS_FQDNS" ;;
        media) printf '%s' "$MEDIA_ALIAS_FQDNS" ;;
        vpush) printf '%s' "$VPUSH_ALIAS_FQDNS" ;;
    esac
}

# Turns on the 443 sites whose certificates exist.
sites() {
    local s kind h
    for s in $(site_list); do
        kind=${s%%:*} h=${s#*:}
        cert_paths "$h"
        if [ "$DRY" = 1 ] || [ -f "$V_CERT" ]; then
            V_HOST=$h
            V_ALIASES=$(role_aliases "$kind")
            render "$HERE/templates/nginx/$kind.conf" "$N/30-$kind.conf" 0600 root:root
        fi
    done
}

# Does the certificate of a host name every name given?
cert_covers() { # cert_covers <cert> <name>...
    local cert=$1 sans n; shift
    [ -f "$cert" ] || return 1
    sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)
    for n in "$@"; do [[ "$sans" == *"DNS:$n"* ]] || return 1; done
    return 0
}

reload_nginx() {
    run nginx -t -q || die "nginx refuses the config: nginx -t"
    run systemctl enable --now nginx
    run systemctl reload nginx
}

sites
reload_nginx

# Certificates: one per role, naming the host and its aliases. Made when
# there is none, or when it does not name every alias yet (the alias was
# added, or its DNS came here after the install). An alias whose DNS is not
# here yet cannot be certified: the host's own names are certified alone,
# and a rerun after the move completes it.
issue_cert() { # issue_cert <host> [alias]...
    local h=$1 names=("$@") args=() n
    if [ "$TLS" = letsencrypt ]; then
        for n in "${names[@]}"; do args+=(-d "$n"); done
        say "tls: Let's Encrypt for ${names[*]}"
        run certbot certonly --webroot -w "$ACME" "${args[@]}" --cert-name "$h" --expand \
            --email "$ACME_EMAIL" --agree-tos --non-interactive \
            --deploy-hook "systemctl reload nginx"
    else
        say "tls: self-signed for ${names[*]}"
        mkdirp "$STATE/tls" 0700 root:root
        mkdirp "$STATE/tls/$h" 0700 root:root
        run openssl genpkey -quiet -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$(target "$V_CERT_KEY")"
        run openssl req -x509 -key "$(target "$V_CERT_KEY")" -days 3650 -subj "/CN=$h" \
            -addext "subjectAltName=$(printf 'DNS:%s,' "${names[@]}" | sed 's/,$//')" \
            -out "$(target "$V_CERT")"
    fi
}
for s in $(site_list); do
    kind=${s%%:*} h=${s#*:}
    cert_paths "$h"
    # shellcheck disable=SC2046
    set -- $(role_aliases "$kind")
    if [ "$DRY" != 1 ] && cert_covers "$V_CERT" "$h" "$@"; then continue; fi
    if issue_cert "$h" "$@"; then continue; fi
    [ $# -gt 0 ] || die "certbot failed for $h: is port 80 open and does $h point here?"
    warn "no certificate for $h with $*: their DNS does not point here yet? The names of this server are certified alone; run 'veydan-server rerun' once the DNS of the aliases is here"
    [ "$DRY" != 1 ] && [ -f "$V_CERT" ] && continue
    issue_cert "$h" || die "certbot failed for $h: is port 80 open and does $h point here?"
done

sites
reload_nginx

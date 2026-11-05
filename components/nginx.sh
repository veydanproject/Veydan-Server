# shellcheck shell=bash disable=SC2034,SC2016  # V_* are read by the templates; nginx's $variables stay in single quotes
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
# The upload keys of the media site (templates/njs/upload.js).
put "$STATE/njs/upload.js" 0644 root:root < "$HERE/templates/njs/upload.js"
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
#
# An upload key (templates/njs/upload.js) lets a person who has not got the
# key of the server upload and delete their own blobs: $veydan_upload_ok is
# "1" for PUT and HEAD /upload and DELETE of a blob with a good one. It is
# never a key of the relay.
#
# A team or channel server (ACCESS_MODE, components/guard.sh): the app key
# alone no longer uploads. A write with it is asked of vguard
# (auth_request /_veydan_access → 127.0.0.1:7779/_access, which reads the
# Authorization of the upload: a member, 204, or not, 401); the peer key
# and an upload key pass without it, and a download by the hash stays open.
MEDIA_KEY_MAP="" V_MEDIA_KEY_GUARD="" V_MEDIA_REVOKE_LOCATION="" V_MEDIA_ACCESS_LOCATION=""
V_MEDIA_INFO='{"v":1,"upload":"open"}'
media_access=""
access_on && media_access=$ACCESS_MODE
if [ "$MEDIA_UPLOAD_KEY" = required ]; then
    V_MEDIA_INFO='{"v":1,"upload":"key","scoped":1}'
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
# Refused: denied, and no good upload key either. Anything unexpected refuses.
map "$veydan_media_denied$veydan_upload_ok" $veydan_media_refused {
    "~^0"   0;
    "11"    0;
    default 1;
}
EOF
)
    # What upload.js reads: the app key, and the folder of the revocations.
    MEDIA_KEY_MAP+=$(printf '\n%s\n%s\n%s' \
        "# For the upload keys (templates/njs/upload.js)." \
        "map \$host \$veydan_app_key    { default \"$MESH_APP_KEY\"; }" \
        "map \$host \$veydan_media_keys { default \"$STATE/media-keys\"; }")
    V_MEDIA_KEY_GUARD='        if ($veydan_media_refused) {
            return 401;
        }'
    if [ -n "$media_access" ]; then
        MEDIA_KEY_MAP+=$'\n'$(cat <<'EOF'
# Team and channel (ACCESS_MODE): what is a write, by the same rules as
# $veydan_media_denied; and whether vguard is asked about it.
map "$request_method$uri" $veydan_media_write {
    "~^(GET|HEAD)/[0-9a-fA-F]{64}(\.[a-zA-Z0-9]+)?$" 0;
    "~^GET/list/[0-9a-fA-F]{64}$" 0;
    "~^GET/$" 0;
    "~^OPTIONS/" 0;
    default 1;
}
# Asked: a write with the app key. Not asked: no write; no key (refused
# above, or a good upload key); the peer key; a good upload key beside the
# app key. Anything unexpected is asked.
map "$veydan_media_write$veydan_relay_denied$veydan_relay_role$veydan_upload_ok" $veydan_media_ask {
    "~^0"       0;
    "~^11"      0;
    "~^10peer"  0;
    "101"       0;
    default     1;
}
EOF
)
        # The answer is made here, in the request itself: the subrequest
        # reads it (it sees the variables of its request).
        V_MEDIA_KEY_GUARD+='
        set $veydan_access_ask $veydan_media_ask;
        auth_request /_veydan_access;'
    fi
    V_MEDIA_REVOKE_LOCATION='    # The upload keys of a person end here: POST ?label=&pubkey= with the
    # app key in X-Api-Key (upload.js checks it; not the peer key).
    location = /.well-known/veydan-media/revoke {
        limit_req zone=veydan_media burst=20 nodelay;
        js_content upload.revoke;
    }'
fi
if [ -n "$media_access" ]; then
    V_MEDIA_INFO="${V_MEDIA_INFO%\}},\"access\":\"$media_access\"}"
    # The subrequest carries the Content-Length of the upload, and nginx
    # measures it against this location too: client_max_body_size 0 (the
    # size is judged by the location of the upload).
    V_MEDIA_ACCESS_LOCATION='    # Team and channel: is the signer of this write a member? vguard reads
    # the Authorization of the upload and answers 204 or 401.
    location = /_veydan_access {
        internal;
        if ($veydan_access_ask = 0) {
            return 204;
        }
        client_max_body_size 0;
        proxy_pass http://127.0.0.1:7779/_access;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Original-Method $request_method;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
    }'
fi
# The revocations of upload keys: written by nginx's workers (upload.js)
# and by veydan-server upload-key revoke.
if has media; then mkdirp "$STATE/media-keys" 0700 www-data:www-data; fi

# The gate of the relay (relay.conf): the key, as above, on an open or a
# team server; none on a channel server, whose readers come by the link of
# a channel and carry no app key (vguard lets them read and members write).
V_ACCESS_LOCATION=""
RELAY_GATE_MAP='# The gate of the relay (ACCESS_MODE): open and team, the key of the network.
map $veydan_relay_denied $veydan_relay_gate {
    default $veydan_relay_denied;
}'
if access_on && [ "$ACCESS_MODE" = channel ]; then
    RELAY_GATE_MAP='# The gate of the relay (ACCESS_MODE=channel): none, vguard decides.
map $veydan_relay_denied $veydan_relay_gate {
    default 0;
}'
fi
# The access API of vguard (join, members, invites; NIP-98 signed) under the
# relay host, before the gate: one who joins by an invite may have no key.
if access_on; then
    V_ACCESS_LOCATION='    # The access API of vguard (ACCESS_MODE): /info and /join for anyone,
    # the rest signed (NIP-98) by a member or the owner. No key needed.
    location ^~ /.well-known/veydan-access/ {
        limit_req zone=veydan_relay burst=10 nodelay;
        client_max_body_size 4k;
        proxy_pass http://127.0.0.1:7779;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
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
$RELAY_GATE_MAP
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

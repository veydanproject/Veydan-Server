# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# Common ground: packages, /opt/veydan, the saved configuration, firewall.
# Sourced by run.sh.

say "base: packages"
run apt-get update -q
apt_install ca-certificates curl git jq openssl unzip xz-utils gettext-base
# nginx and certificates only where there is a site to serve: a bridge or a
# node of calls alone listens on its own ports.
[ -z "$HOSTS" ] || apt_install nginx libnginx-mod-http-js
[ -n "$HOSTS" ] && [ "$TLS" = letsencrypt ] && apt_install certbot
[ "$FIREWALL" = ufw ] && apt_install ufw

mkdirp "$STATE" 0700 root:root
mkdirp "$STATE/nginx" 0700 root:root

# The network and this server as installed: every key every service here
# uses. Read back on every run, so a rerun or --add asks nothing new; a
# run with a changed file (a new relay, say) updates it.
{
    echo "# The network and this server, as installed by run.sh on $(date -u +%F)."
    echo "# Read back on every run. The keys never change; a new server of the"
    echo "# network takes the network part of this file."
    echo
    echo "# ---- the network"
    for v in BASE_DOMAIN NETWORK MESH_RELAYS MESH_MEDIA MESH_ORIGINS MESH_APP_KEY MESH_PEER_KEY \
             S3_ENDPOINT S3_BUCKET S3_REGION S3_ACCESS_KEY S3_SECRET_KEY \
             TLS ACME_EMAIL FIREWALL ADMIN_PUBKEY VLINK_REGISTRY_HOST \
             $EXTRA_NET_VARS; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done
    echo
    echo "# ---- this server"
    for v in SERVER COMPONENTS RELAY_HOST MEDIA_HOST VPUSH_HOST RELAY_ALIASES MEDIA_ALIASES VPUSH_ALIASES \
             REGION RELAY_NAME RELAY_RETENTION_DAYS SKIP_DNS_CHECK FCM_APPS PUSH_GATEWAY MEDIA_UPLOAD_KEY \
             CALL_PUBLIC_IP CALL_PORT CALL_SFU_PORT CALL_RELAY_PORTS CALL_REGISTRY_URL \
             $EXTRA_CONF_VARS; do
        printf '%s=%q\n' "$v" "${!v:-}"
    done
} | put "$STATE/server.conf" 0600 root:root

# The command of the server (templates/veydan-server) and the kit it runs:
# the one that installed this server.
mkdirp "$STATE/kit" 0755 root:root
run ln -sfn "$HERE" "$STATE/kit/current"
put /usr/local/bin/veydan-server 0755 root:root < "$HERE/templates/veydan-server"

# The other servers of the network, by their real addresses: relay to
# relay, media to media and vpush go past a CDN in front of the names
# (Cloudflare cuts a connection from Russia after ~16 KB). TLS stays
# checked: every server has its own certificate. Users still come through
# the CDN.
hosts_block=""
mine=" $(hostname -I 2>/dev/null) "
for n in $(printf '%s\n' $MESH_RELAY_FQDNS $MESH_MEDIA_FQDNS | sed '/^$/d' | sort -u); do
    ip=$(origin_of "$n") || continue
    [[ "$mine" == *" $ip "* ]] && continue
    hosts_block+="$ip $n"$'\n'
done
hosts_now=""
[ -f "$(target /etc/hosts)" ] && hosts_now=$(cat "$(target /etc/hosts)")
hosts_new=$(
    printf '%s\n' "$hosts_now" | sed '/^# veydan-mesh begin/,/^# veydan-mesh end$/d'
    if [ -n "$hosts_block" ]; then
        echo "# veydan-mesh begin (run.sh, from MESH_ORIGINS in server.conf)"
        printf '%s' "$hosts_block"
        echo "# veydan-mesh end"
    fi
)
if [ "$DRY" = 1 ]; then
    printf '%s\n' "$hosts_new" | put /etc/hosts 0644 root:root
else
    # Rewritten in place, not replaced: in containers and on some VPS
    # /etc/hosts is a mount, which a rename cannot replace.
    printf '%s\n' "$hosts_new" > /etc/hosts
fi
[ -n "$hosts_block" ] && say "base: /etc/hosts: $(printf '%s' "$hosts_block" | tr '\n' ' ')"

if [ "$FIREWALL" = ufw ]; then
    say "base: firewall (ssh${HOSTS:+, 80, 443})"
    # Every port sshd listens on stays open, whatever it is.
    ssh_ports=$( { ss -Hltnp 2>/dev/null || true; } | awk '/"sshd"/ {sub(/.*:/, "", $4); print $4}' | sort -u)
    [ -n "$ssh_ports" ] || ssh_ports=22
    for p in $ssh_ports; do run ufw allow "$p/tcp"; done
    # 80 and 443 are nginx's: open where there is a site.
    [ -z "$HOSTS" ] || run ufw allow 80/tcp
    [ -z "$HOSTS" ] || run ufw allow 443/tcp
    run ufw --force enable
fi

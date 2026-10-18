#!/usr/bin/env bash
# shellcheck disable=SC2034  # the network and answer variables are read by the components
# Veydan server, the installer proper: relay (strfry), media (blossom with
# its own index and the bucket of the network), push (vpush) behind nginx,
# and the node of calls (vcall) beside it, on Debian 13, without docker.
# Everything of an app is in /opt/<app>. install.sh finds the kit and runs
# this file; run it directly from a checkout.
#
# One file, server.conf, describes the network and this server
# (server.conf.example). What it lacks is asked on the terminal; the answers
# are saved to /opt/veydan/server.conf and a rerun asks nothing.
#
#   run.sh                            server.conf beside install.sh, or questions
#   run.sh --config my.conf           takes the answers from a file
#   run.sh --add call                 adds a component to an installed server
#   run.sh --bridge                   a VLink bridge and nothing else: no domain,
#                                     no certificate, one or two questions
#   run.sh --volunteer                a bridge and a node of calls for the Veydan
#                                     network: no domain, a few questions
#   run.sh --call                     the node of calls alone, the same way
#   run.sh --join <key>               joins the network of the key
#                                     (veydan-server join-token on one of its servers)
#   run.sh --dry-run ...              prints what it would do, writes the
#                                     files under a temporary directory
#   run.sh --lang ru                  questions in Russian (also by $LANG)
#
# Safe to run again: files the admin may edit are kept (a changed template
# goes next to them as *.new), keys come from server.conf and never change.
set -euo pipefail

# -P: run through /opt/veydan/kit/current (a symlink) HERE must be the real
# kit, or base.sh makes current point to itself.
HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/release.sh
. "$HERE/lib/release.sh"
# shellcheck source=versions.conf
. "$HERE/versions.conf"

STATE=/opt/veydan
FROM=$HERE
CONF_FILE=""
ADD=()
YES=0
KIT_LANG=""
JOIN=""
ONLY=""

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=${2:?--from needs a directory}; shift 2 ;;
        --config) CONF_FILE=${2:?--config needs a file}; shift 2 ;;
        --add) ADD+=("${2:?--add needs a component}"); shift 2 ;;
        --join) JOIN=${2:?--join needs the key}; shift 2 ;;
        --bridge) ONLY=bridge; shift ;;
        --volunteer) ONLY="bridge call"; shift ;;
        --call) ONLY=call; shift ;;
        --dry-run) DRY=1; shift ;;
        --lang) KIT_LANG=${2:?--lang needs a code}; shift 2 ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done
if [ -z "$KIT_LANG" ]; then
    case "${LC_ALL:-${LANG:-}}" in ru*) KIT_LANG=ru ;; esac
fi
# shellcheck source=lib/ask.sh
. "$HERE/lib/ask.sh"

if [ "$DRY" = 1 ]; then
    # A DRY_ROOT given stays (a test lays files there first, as a server
    # would have them).
    DRY_ROOT=${DRY_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/veydan-dry.XXXXXX")}
    say "dry run: nothing is changed, files go under $DRY_ROOT"
    # A real run installs these itself; a dry run installs nothing.
    for t in envsubst jq openssl; do
        command -v "$t" >/dev/null || die "a dry run needs $t: apt-get install gettext-base jq openssl"
    done
else
    [ "$(id -u)" = 0 ] || die "run as root"
    . /etc/os-release
    if [ "${ID:-}" != debian ] || [ "${VERSION_ID:-}" != 13 ]; then
        warn "made for Debian 13, this is ${PRETTY_NAME:-unknown}"
        [ "$YES" = 1 ] || confirm q_go_on || exit 1
    fi
fi

# --- the configuration --------------------------------------------------------
#
# Defaults, then what this server was installed with, then the file given
# (or server.conf beside the installer), then the questions.

BASE_DOMAIN="" NETWORK="" MESH_RELAYS="" MESH_MEDIA="" MESH_ORIGINS="" MESH_APP_KEY="" MESH_PEER_KEY=""
S3_ENDPOINT="" S3_BUCKET="" S3_REGION="" S3_ACCESS_KEY="" S3_SECRET_KEY=""
TLS=letsencrypt ACME_EMAIL="" FIREWALL=ufw ADMIN_PUBKEY="" VLINK_REGISTRY_HOST=""
SERVER="" COMPONENTS="" RELAY_HOST="" MEDIA_HOST="" VPUSH_HOST="" REGION="" RELAY_NAME="" SKIP_DNS_CHECK=0 FCM_APPS="" PUSH_GATEWAY="" MEDIA_UPLOAD_KEY=""
RELAY_ALIASES="" MEDIA_ALIASES="" VPUSH_ALIASES=""
RELAY_RETENTION_DAYS=90
CALL_PUBLIC_IP="" CALL_PORT=8443 CALL_SFU_PORT=3479 CALL_RELAY_PORTS=49152-49999 CALL_REGISTRY_URL=""
# Of older installs; read and set aside.
MEDIA_INDEX_HOST="" MESH_INDEX_TOKEN="" MEDIA_MODE=""

FIRST=1
# shellcheck disable=SC1091
if [ -f "$STATE/server.conf" ]; then
    . "$STATE/server.conf"; FIRST=0
elif [ -f "$STATE/mesh.env" ]; then
    # A server of the kit before server.conf: the network and the answers
    # in two files.
    . "$STATE/mesh.env"
    [ -f "$STATE/install.conf" ] && . "$STATE/install.conf"
    FIRST=0
fi
if [ -n "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
elif [ -f "$FROM/server.conf" ] && [ "$FROM/server.conf" != "$STATE/server.conf" ]; then
    say "answers: $FROM/server.conf"
    # shellcheck disable=SC1090
    . "$FROM/server.conf"
fi
for c in "${ADD[@]}"; do has "$c" || COMPONENTS="${COMPONENTS:+$COMPONENTS }$c"; done
# --bridge, --volunteer, --call: these components and nothing else, whatever
# a file says.
[ -z "$ONLY" ] || COMPONENTS=$ONLY
# A node of calls of a volunteer is no part of a network of its own: it
# reports to the registry of the Veydan network, as a bridge does by itself
# (VEYDAN_REGISTRY of versions.conf). A network of one's own names its
# registry with VLINK_REGISTRY_HOST instead.
if [[ " $ONLY " == *" call "* ]] && [ -z "${VLINK_REGISTRY_HOST:-}" ] && [ -z "$CALL_REGISTRY_URL" ]; then
    CALL_REGISTRY_URL=$VEYDAN_REGISTRY
fi
[ -n "$COMPONENTS" ] || COMPONENTS="relay media"

# A server with sites (relay, media, push behind nginx) has a domain,
# certificates and a network to start or join; a bridge or a node of calls
# alone is reached at its bare address and asks none of that.
sites_wanted() { has relay || has media || has vpush; }
case "$MEDIA_MODE" in
    local|proxy) warn "MEDIA_MODE=$MEDIA_MODE is gone: every media server keeps its own index now and reads the bucket of the network itself" ;;
esac
[ -z "$MEDIA_INDEX_HOST" ] || say "MEDIA_INDEX_HOST is not used any more: the index of media is on every media server"

# --- the questions ------------------------------------------------------------

# A first server with nothing to go on: a new network, or one to join with
# the key of another server (its network part of server.conf, base64).
JOINED=0
[ "$FIRST" = 1 ] && [ -z "$ONLY" ] && ask COMPONENTS q_components
if [ "$FIRST" = 1 ] && sites_wanted && [ -z "$BASE_DOMAIN" ] && [ -z "$JOIN" ]; then
    MODE=new
    ask MODE q_mode "new join"
    [ "$MODE" = join ] && ask_secret JOIN q_join_key
fi
if [ -n "$JOIN" ]; then
    key=${JOIN#veydan-join-1.}
    [ "$key" != "$JOIN" ] || die "$(msg join_bad)"
    net=$(printf '%s' "$key" | base64 -d 2>/dev/null) || die "$(msg join_bad)"
    # Lines of NAME=value and nothing else: the key is sourced as a file.
    printf '%s\n' "$net" | grep -v '^$' | grep -qv '^[A-Z][A-Z0-9_]*=' && die "$(msg join_bad)"
    joinfile=$(mktemp)
    printf '%s\n' "$net" > "$joinfile"
    # shellcheck disable=SC1090
    . "$joinfile"
    rm -f "$joinfile"
    [ -n "$BASE_DOMAIN" ] && [ -n "$MESH_APP_KEY" ] || die "$(msg join_bad)"
    JOINED=1
    say "$(msg join_ok): $NETWORK ($BASE_DOMAIN), relays $MESH_RELAYS"
    # Its own word first: the names of a joining server are made from it.
    if [ -z "$SERVER" ]; then
        SERVER=""
        ask SERVER q_server
        [ -n "$SERVER" ] || die "SERVER is empty: a word for this server"
    fi
fi

for c in $COMPONENTS; do
    [ "$c" != guard ] || die "guard is part of the relay (components/guard.sh), not a component of its own"
    [ -f "$HERE/components/$c.sh" ] || [ "$c" = relay ] || [ "$c" = media ] || die "unknown component: $c"
done
# A relay goes up only with its read policy: refused here, before anything
# is built or installed (components/guard.sh checks it again).
if has relay && ! vguard_at_hand; then die "$NO_VGUARD"; fi
if [ -z "$BASE_DOMAIN" ] && sites_wanted; then
    ask BASE_DOMAIN q_domain
    [ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is empty: the domain of this server"
fi
if has relay; then
    [ -n "$RELAY_HOST" ] || { RELAY_HOST=${SERVER:+$SERVER-}relay; ask RELAY_HOST q_relay_host; }
fi
if has media; then
    [ -n "$MEDIA_HOST" ] || { MEDIA_HOST=${SERVER:+$SERVER-}media; ask MEDIA_HOST q_media_host; }
    if [ "$FIRST" = 1 ] && [ -z "$S3_ENDPOINT" ]; then
        MEDIA_STORE=disk
        ask MEDIA_STORE q_media_store "disk s3"
        if [ "$MEDIA_STORE" = s3 ]; then
            ask S3_ENDPOINT q_s3_endpoint
            S3_BUCKET=${S3_BUCKET:-media}; ask S3_BUCKET q_s3_bucket
            S3_REGION=${S3_REGION:-auto}; ask S3_REGION q_s3_region
            ask S3_ACCESS_KEY q_s3_key
            ask_secret S3_SECRET_KEY q_s3_secret
        fi
    fi
fi
if has vpush; then
    [ -n "$VPUSH_HOST" ] || { VPUSH_HOST=${SERVER:+$SERVER-}push; ask VPUSH_HOST q_vpush_host; }
fi
if [ "$TLS" = letsencrypt ] && [ -z "$ACME_EMAIL" ] && sites_wanted; then
    ask ACME_EMAIL q_email
fi

# This server's word: the first label of its first name, without the role.
if [ -z "$SERVER" ]; then
    for h in "$RELAY_HOST" "$MEDIA_HOST" "$VPUSH_HOST"; do
        [ -n "$h" ] || continue
        SERVER=$(short "$h"); SERVER=${SERVER%%-relay*}; SERVER=${SERVER%%-media*}; SERVER=${SERVER%%-vpush*}; SERVER=${SERVER%%-push*}
        break
    done
fi
# No name to take it from (a bridge, a node of calls): the machine's own.
[ -n "$SERVER" ] || SERVER=$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9_\n-' '-')
[ -n "$SERVER" ] || SERVER=server
[ -n "$NETWORK" ] || NETWORK=${BASE_DOMAIN%%.*}
[ -n "$NETWORK" ] || NETWORK=veydan

# The node of calls is reached at the bare IP: the one this server has in
# MESH_ORIGINS, or its first address.
if has call && [ -z "$CALL_PUBLIC_IP" ]; then
    for h in "$RELAY_HOST" "$MEDIA_HOST" "$VPUSH_HOST"; do
        [ -n "$h" ] && CALL_PUBLIC_IP=$(origin_of "$(fqdn "$h")") && break
    done
    [ -n "$CALL_PUBLIC_IP" ] || CALL_PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    ask CALL_PUBLIC_IP q_call_ip
    ask CALL_PORT q_call_port
fi
# Region: the part of SERVER before its first "-" (eu-2 → eu); a word
# without one serves the region default.
if [ -z "$REGION" ]; then
    case "$SERVER" in *-*) REGION=${SERVER%%-*} ;; *) REGION=default ;; esac
    # A volunteer's server is named by its hoster, not by its region.
    [ -z "$ONLY" ] || REGION=default
    [ "$FIRST" = 1 ] && { sites_wanted || has call; } && ask REGION q_region
fi
# Whether phones are woken through the push of the Veydan network. Only
# stored for now (the card says it, p=); `veydan-server push` changes it.
# --yes and a rerun keep what is saved, off at first.
PUSH_GATEWAY=${PUSH_GATEWAY:-off}
# Media takes an upload only with the key of the server (a plain setting,
# not asked). A server installed before the setting existed keeps uploads
# open: its apps do not carry the key yet.
if [ -z "$MEDIA_UPLOAD_KEY" ]; then
    if [ "$FIRST" = 1 ]; then MEDIA_UPLOAD_KEY=required; else MEDIA_UPLOAD_KEY=open; fi
fi
if has relay && [ "$FIRST" = 1 ]; then
    ask PUSH_GATEWAY q_push_gateway "veydan off"
fi

# The keys of the network: made once, here, when the network starts. A
# server without a relay or push has no use for them.
for k in $(sites_wanted && echo MESH_APP_KEY MESH_PEER_KEY); do
    if [ -z "${!k}" ]; then
        printf -v "$k" '%s' "$(secret)"
        say "$k: made"
    fi
done
# A network of this one server, unless the file names more. A joining
# server adds itself: the key came from a server that does not know it.
if has relay && [ -z "$MESH_RELAYS" ]; then MESH_RELAYS=$RELAY_HOST; fi
if has media && [ -z "$MESH_MEDIA" ]; then MESH_MEDIA=$MEDIA_HOST; fi
if [ "$JOINED" = 1 ]; then
    has relay && [[ " $MESH_RELAYS " != *" $RELAY_HOST "* ]] && [[ " $MESH_RELAYS " != *" $(fqdn "$RELAY_HOST") "* ]] && MESH_RELAYS="$MESH_RELAYS $RELAY_HOST"
    has media && [[ " $MESH_MEDIA " != *" $MEDIA_HOST "* ]] && [[ " $MESH_MEDIA " != *" $(fqdn "$MEDIA_HOST") "* ]] && MESH_MEDIA="$MESH_MEDIA $MEDIA_HOST"
fi

# --- checks -------------------------------------------------------------------

! sites_wanted || [ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is empty"
[[ "$SERVER" =~ ^[A-Za-z0-9_-]+$ ]] || die "SERVER: letters, digits, - and _ only"
[[ "$NETWORK" =~ ^[A-Za-z0-9_-]+$ ]] || die "NETWORK: letters, digits, - and _ only"
[[ "$REGION" =~ ^[A-Za-z0-9_-]+$ ]] || die "REGION: letters, digits, - and _ only"
case "$PUSH_GATEWAY" in veydan|off) ;; *) die "PUSH_GATEWAY is veydan or off" ;; esac
case "$MEDIA_UPLOAD_KEY" in required|open) ;; *) die "MEDIA_UPLOAD_KEY is required or open" ;; esac
RELAY_RETENTION_DAYS=${RELAY_RETENTION_DAYS:-90}
days_re='^[0-9]{1,4}$'
[[ "$RELAY_RETENTION_DAYS" =~ $days_re ]] || die "RELAY_RETENTION_DAYS: a number of days, 0 to keep for ever"
RELAY_RETENTION_DAYS=$((10#$RELAY_RETENTION_DAYS))
if [ "$RELAY_RETENTION_DAYS" -gt 0 ] && [ "$RELAY_RETENTION_DAYS" -lt 7 ]; then
    die "RELAY_RETENTION_DAYS: below 7 a phone that was off for a week would miss its messages; 0 keeps for ever"
fi
for k in $(sites_wanted && echo MESH_APP_KEY MESH_PEER_KEY); do
    [[ "${!k}" =~ ^[A-Za-z0-9._~-]{32,}$ ]] || die "server.conf: $k is odd (letters, digits, ._~- only, 32 or more)"
done
! sites_wanted || [ "$MESH_APP_KEY" != "$MESH_PEER_KEY" ] || die "server.conf: the app key and the peer key must differ"
case "$TLS" in
    letsencrypt) ! sites_wanted || [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is empty (needed by Let's Encrypt)" ;;
    selfsigned) ;;
    *) die "TLS is letsencrypt or selfsigned" ;;
esac
case "$FIREWALL" in ufw|none) ;; *) die "FIREWALL is ufw or none" ;; esac
if [ -n "$S3_ENDPOINT" ]; then
    url_re='^https?://[^<>/]+/?$'
    [[ "$S3_ENDPOINT" =~ $url_re ]] || die "S3_ENDPOINT: https://<host>, nothing after the host"
    [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] || die "S3_BUCKET, S3_ACCESS_KEY and S3_SECRET_KEY go with S3_ENDPOINT"
    [ -n "$S3_REGION" ] || S3_REGION=auto
fi
ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
for o in $MESH_ORIGINS; do
    [[ "$o" == *=* && "${o#*=}" =~ $ip_re ]] || die "MESH_ORIGINS takes name=ipv4 pairs, not \"$o\""
done
if has call; then
    # The node reports its region to the registry, which takes a short
    # word only; any other one keeps the node off the list without a word.
    [[ "$REGION" =~ ^[a-z0-9-]{1,16}$ ]] || die "REGION=$REGION: the call node needs a-z, 0-9 and - only, up to 16 (eu, us-east)"
    [[ "$CALL_PUBLIC_IP" =~ $ip_re ]] || die "CALL_PUBLIC_IP: the server's public IPv4, not \"$CALL_PUBLIC_IP\""
    port_re='^[0-9]{1,5}$'
    [[ "$CALL_PORT" =~ $port_re ]] && [ "$CALL_PORT" -ge 1 ] && [ "$CALL_PORT" -le 65535 ] || die "CALL_PORT: a TCP port"
    # The node has no way to go without its SFU yet, so there is no 0.
    [[ "$CALL_SFU_PORT" =~ $port_re ]] && [ "$CALL_SFU_PORT" -ge 1 ] && [ "$CALL_SFU_PORT" -le 65535 ] \
        || die "CALL_SFU_PORT: a port (the node always runs its SFU)"
    CALL_PORT=$((10#$CALL_PORT)) CALL_SFU_PORT=$((10#$CALL_SFU_PORT))
    range_re='^([0-9]{1,5})-([0-9]{1,5})$'
    [[ "$CALL_RELAY_PORTS" =~ $range_re ]] && [ "${BASH_REMATCH[1]}" -ge 1024 ] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
        && [ "${BASH_REMATCH[2]}" -le 65535 ] || die "CALL_RELAY_PORTS: first-last above 1023, e.g. 49152-49999"
    relay_first=$((10#${BASH_REMATCH[1]})) relay_last=$((10#${BASH_REMATCH[2]}))
    # What each port carries: control and TURN/TLS on CALL_PORT/tcp,
    # STUN/TURN on 3478 udp+tcp, the SFU on its port udp+tcp, allocations
    # on the relay range/udp. Two of them on one port and the node cannot
    # start.
    [ "$CALL_PORT" != 443 ] && [ "$CALL_PORT" != 80 ] || die "CALL_PORT=$CALL_PORT is nginx's: take another (8443)"
    [ "$CALL_PORT" != 3478 ] || die "CALL_PORT=3478 is TURN's over TCP: take another (8443)"
    [ "$CALL_SFU_PORT" != 3478 ] || die "CALL_SFU_PORT=3478 is STUN/TURN's"
    [ "$CALL_SFU_PORT" != "$CALL_PORT" ] || die "CALL_SFU_PORT and CALL_PORT are both $CALL_PORT: take two ports"
    in_relay() { [ "$1" -ge "$relay_first" ] && [ "$1" -le "$relay_last" ]; }
    ! in_relay "$CALL_SFU_PORT" || die "CALL_SFU_PORT=$CALL_SFU_PORT is inside CALL_RELAY_PORTS=$CALL_RELAY_PORTS"
    ! in_relay 3478 || die "CALL_RELAY_PORTS=$CALL_RELAY_PORTS takes 3478, STUN/TURN's"
fi
has relay && { [ -n "$RELAY_HOST" ] || die "RELAY_HOST is empty"; }
has media && { [ -n "$MEDIA_HOST" ] || die "MEDIA_HOST is empty"; }
has vpush && { [ -n "$VPUSH_HOST" ] || die "VPUSH_HOST is empty"; }

RELAY_FQDN="" MEDIA_FQDN="" VPUSH_FQDN=""
has relay && RELAY_FQDN=$(fqdn "$RELAY_HOST")
has media && MEDIA_FQDN=$(fqdn "$MEDIA_HOST")
has vpush && VPUSH_FQDN=$(fqdn "$VPUSH_HOST")

# What a kit with more components adds (hooks/, not in the public kit):
# hooks/pre.sh for every server and hooks/<component>.pre.sh for a
# component of this one, before anything is installed. They check their
# settings and may add
#   EXTRA_SITES      "<kind>:<fqdn>" each: a site of templates/nginx/<kind>.conf
#   EXTRA_NET_VARS   settings of the network to save in server.conf
#   EXTRA_CONF_VARS  settings of this server to save in server.conf
#   CARD_EXTRA       lines for the card of the server (server.txt)
#   CARD_SHOW        text shown at the end of the run as well
EXTRA_SITES="" EXTRA_NET_VARS="" EXTRA_CONF_VARS="" CARD_EXTRA="" CARD_SHOW=""
for hook in pre $(printf '%s.pre ' $COMPONENTS); do
    # shellcheck disable=SC1090
    [ -f "$HERE/hooks/$hook.sh" ] && . "$HERE/hooks/$hook.sh"
done
EXTRA_HOSTS=""
for s in $EXTRA_SITES; do EXTRA_HOSTS+="${s#*:} "; done
HOSTS=$(printf '%s\n' "$RELAY_FQDN" "$MEDIA_FQDN" "$VPUSH_FQDN" $EXTRA_HOSTS | sed '/^$/d' | sort -u | tr '\n' ' ')

# Aliases: other names a role answers under, the names of a server this one
# takes over (the DNS of those names is moved here). Served and given
# certificates like the names of this server; never a peer of it.
RELAY_ALIAS_FQDNS="" MEDIA_ALIAS_FQDNS="" VPUSH_ALIAS_FQDNS=""
for a in $RELAY_ALIASES; do has relay && RELAY_ALIAS_FQDNS+="$(fqdn "$a") "; done
for a in $MEDIA_ALIASES; do has media && MEDIA_ALIAS_FQDNS+="$(fqdn "$a") "; done
for a in $VPUSH_ALIASES; do has vpush && VPUSH_ALIAS_FQDNS+="$(fqdn "$a") "; done
ALIAS_HOSTS=$(printf '%s\n' $RELAY_ALIAS_FQDNS $MEDIA_ALIAS_FQDNS $VPUSH_ALIAS_FQDNS | sed '/^$/d' | sort -u | tr '\n' ' ')
for a in $ALIAS_HOSTS; do
    [[ " $HOSTS" != *" $a "* ]] || die "$a is a name of this server and an alias at once"
done

# The other relays of the network: this relay's peers, and what vpush may
# watch. The other media servers: where a file this one has not got is.
# A server that took other names: a list saved at its install names it by
# the name it had then, now an alias. Its name of today joins the list.
renamed() { # renamed <fqdns of the list> <fqdn> <alias fqdns>: is an alias listed and the name not?
    local a
    [[ " $1" == *" $2 "* ]] && return 1
    for a in $3; do [[ " $1" == *" $a "* ]] && return 0; done
    return 1
}
MESH_RELAY_FQDNS=""
for r in $MESH_RELAYS; do MESH_RELAY_FQDNS+="$(fqdn "$r") "; done
if has relay && renamed "$MESH_RELAY_FQDNS" "$RELAY_FQDN" "$RELAY_ALIAS_FQDNS"; then
    MESH_RELAYS="$MESH_RELAYS $RELAY_HOST"; MESH_RELAY_FQDNS+="$RELAY_FQDN "
fi
PEERS=""
for r in $MESH_RELAY_FQDNS; do
    [ "$r" = "$RELAY_FQDN" ] && continue
    [[ " $RELAY_ALIAS_FQDNS" == *" $r "* ]] && continue
    PEERS+="$r "
done
if has relay && [[ " $MESH_RELAY_FQDNS" != *" $RELAY_FQDN "* ]]; then
    die "$RELAY_FQDN is not in MESH_RELAYS ($MESH_RELAYS): add it there (on every server) or fix the name"
fi
MESH_MEDIA_FQDNS=""
for m in $MESH_MEDIA; do MESH_MEDIA_FQDNS+="$(fqdn "$m") "; done
if has media && renamed "$MESH_MEDIA_FQDNS" "$MEDIA_FQDN" "$MEDIA_ALIAS_FQDNS"; then
    MESH_MEDIA="$MESH_MEDIA $MEDIA_HOST"; MESH_MEDIA_FQDNS+="$MEDIA_FQDN "
fi
MEDIA_PEERS=""
for m in $MESH_MEDIA_FQDNS; do
    [ "$m" = "$MEDIA_FQDN" ] && continue
    [[ " $MEDIA_ALIAS_FQDNS" == *" $m "* ]] && continue
    MEDIA_PEERS+="$m "
done
if has media && [[ " $MESH_MEDIA_FQDNS" != *" $MEDIA_FQDN "* ]]; then
    die "$MEDIA_FQDN is not in MESH_MEDIA ($MESH_MEDIA): add it there (on every server) or fix the name"
fi

# Every name has to point here before Let's Encrypt is asked. A name proxied
# by Cloudflare resolves to Cloudflare's edge; where its origin points is
# not visible from here, so it is only reported. On a terminal the records
# are shown and waited for.
dns_check() { # → sets DNS_MISSING to the names that do not point here
    local h ips ip proxied mine
    DNS_MISSING=""
    mine=" $(hostname -I) "
    for h in $HOSTS; do
        # (getent fails on a name that does not resolve; with pipefail that
        # would end the run without a word.)
        ips=$( { getent ahostsv4 "$h" || true; } | awk '{print $1}' | sort -u | tr '\n' ' ')
        if [ -z "$ips" ]; then DNS_MISSING+="$h "; continue; fi
        proxied=1
        for ip in $ips; do cloudflare_ip "$ip" "$HERE/templates/cloudflare-ips.txt" || proxied=0; done
        if [ "$proxied" = 1 ]; then
            say "$h is proxied by Cloudflare: its origin must be this server ($(hostname -I | awk '{print $1}')); SSL mode Full (strict), \"Always Use HTTPS\" off"
            continue
        fi
        for ip in $ips; do
            [[ "$mine" == *" $ip "* ]] || { DNS_MISSING+="$h "; break; }
        done
    done
}
if [ "$DRY" != 1 ] && [ "$TLS" = letsencrypt ] && [ "$SKIP_DNS_CHECK" != 1 ]; then
    for _ in 1 2 3; do
        dns_check
        [ -n "$DNS_MISSING" ] || break
        [ "$TTY" = 1 ] || die "${DNS_MISSING}do(es) not point to this server ($(hostname -I)). Add the A records, or SKIP_DNS_CHECK=1 when behind NAT."
        tell "$(msg dns_add)"
        for h in $DNS_MISSING; do tell "   A  $h  $(hostname -I | awk '{print $1}')"; done
        pause dns_enter
    done
    [ -z "$DNS_MISSING" ] || die "${DNS_MISSING}still do(es) not point here"
fi

sites_wanted && say "network $NETWORK ($BASE_DOMAIN): relays $MESH_RELAY_FQDNS| media $MESH_MEDIA_FQDNS"
say "this server: $SERVER, region $REGION, components: $COMPONENTS"
[ -n "$ALIAS_HOSTS" ] && say "also answers as: $ALIAS_HOSTS(certificates once their DNS points here)"
has relay && say "relay  wss://$RELAY_FQDN  peers: ${PEERS:-none}  push of the Veydan network: $PUSH_GATEWAY"
if has media; then
    if [ -n "$S3_ENDPOINT" ]; then
        say "media  https://$MEDIA_FQDN  (files in the bucket $S3_BUCKET at $S3_ENDPOINT, index here)"
    else
        say "media  https://$MEDIA_FQDN  (files on this disk; other media servers: ${MEDIA_PEERS:-none})"
    fi
fi
[ -n "$MESH_ORIGINS" ] && say "between servers, past a CDN: $MESH_ORIGINS"
has vpush && say "vpush  https://$VPUSH_FQDN"
has call && say "call   $CALL_PUBLIC_IP:$CALL_PORT (control, TURN/TLS), 3478 udp+tcp, sfu $CALL_SFU_PORT udp+tcp, relay $CALL_RELAY_PORTS/udp"
if [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
    confirm q_install || exit 1
fi

# --- install ------------------------------------------------------------------
#
# The order is fixed; a component is on when it is in COMPONENTS and its
# file is in the kit (the private ones come with the private overlay).

# shellcheck source=components/base.sh
. "$HERE/components/base.sh"
# shellcheck source=components/strfry.sh
has relay && . "$HERE/components/strfry.sh"
# shellcheck source=components/guard.sh
has relay && . "$HERE/components/guard.sh"
# shellcheck source=components/libsql.sh
has media && . "$HERE/components/libsql.sh"
# shellcheck source=components/blossom.sh
has media && . "$HERE/components/blossom.sh"
# shellcheck source=components/vpush.sh
has vpush && . "$HERE/components/vpush.sh"
# shellcheck source=components/call.sh
has call && . "$HERE/components/call.sh"
# The media site renders these; the private components fill them.
V_VAULT_LOCATION="" V_MEDIA_AUTH_LOCATION="" V_MEDIA_ROOT_GUARD="" V_CLOUD_LOCATION="" V_MANIFEST_LOCATION=""
for c in $COMPONENTS; do
    case "$c" in relay|media|vpush|call|agent) continue ;; esac
    # shellcheck disable=SC1090
    . "$HERE/components/$c.sh"
done
# The agent last: it reports what the others installed.
# shellcheck disable=SC1091
has agent && . "$HERE/components/agent.sh"
# shellcheck source=components/nginx.sh
[ -z "$HOSTS" ] || . "$HERE/components/nginx.sh"
# shellcheck source=components/manifest.sh
. "$HERE/components/manifest.sh"

say "done"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo
    echo "Warnings:"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
fi
[ "$DRY" = 1 ] && echo "Dry run files: $DRY_ROOT"
exit 0

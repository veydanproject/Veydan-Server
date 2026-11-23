# shellcheck shell=bash disable=SC2034  # V_* and MESH_* are read by the templates and the callers
# The mesh of the vrelay engine: servers in regions, joined by WireGuard
# (services/relay/spec/cluster.md, spec/security.md). Sourced by run.sh,
# components/vrelay.sh and relay-mesh.sh (veydan-server relay-peer,
# relay-join), after lib/common.sh. Functions only.
#
# server.conf, this server (nothing of it is the same on every server):
#   RELAY_MESH_WG        this server's address in the mesh, 10.77.1.1/16 (the
#                        prefix is the whole mesh: /16 if not given), or off
#   RELAY_DC             its region: the datacenter of Cassandra, the JetStream
#                        domain of NATS, the region in the names of the queue
#                        (lower-case letters and digits; empty: REGION)
#   RELAY_MESH_WG_PEERS  the other servers, one entry each, space separated:
#                          name,endpoint,public key,mesh address,region[,hub]
#                        hub: that server's region is the hub of the leaf links
#                        of NATS (none marked: this server's region is)
#   RELAY_STORE_SEEDS    the seeds of Cassandra (empty: the first server, by
#                        name, of each region; two from three servers on)
#   RELAY_BUS_ROUTES     the other NATS servers of this region (empty: one
#                        server a region, JetStream standalone)
#   RELAY_MESH_WG_ENDPOINT  this server's endpoint in its line for the others
#                        (empty: its public address, mesh_self_endpoint)

MESH_IF=wg0
MESH_PORT=51820
MESH_WG_DIR=/etc/wireguard
MESH_MARK="# veydan-mesh: written by the kit (lib/mesh.sh); veydan-server relay-peer changes it"
MESH_JOINED=/opt/vrelay/etc/mesh-joined
MESH_CSEC=/opt/vrelay/compose/secrets
MESH_SEC=/opt/vrelay/etc/secrets
MESH_DAYS=(Mon Tue Wed Thu Fri Sat Sun)

mesh_ip4_ok() { # mesh_ip4_ok <a.b.c.d>
    local a
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for a in "${BASH_REMATCH[@]:1}"; do [ "$((10#$a))" -le 255 ] || return 1; done
}
mesh_ip2n() { local a b c d; IFS=. read -r a b c d <<< "$1"; printf '%s' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d )); }
mesh_n2ip() { printf '%s.%s.%s.%s' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 )); }
mesh_in_net() { # mesh_in_net <ip>: inside the mesh's network
    local m=$(( (0xffffffff << (32 - MESH_PREFIX)) & 0xffffffff ))
    [ $(( $(mesh_ip2n "$1") & m )) = $(( $(mesh_ip2n "$MESH_IP") & m )) ]
}
mesh_up() { printf '%s' "${1^^}"; }

# The host of an endpoint (an IPv4, or an IPv6 in brackets) and its port.
mesh_endpoint() { # mesh_endpoint <endpoint> → sets EP_HOST EP_PORT
    EP_HOST="" EP_PORT=$MESH_PORT
    case "$1" in
        \[*\]:*) EP_HOST=${1%%]*}; EP_HOST=${EP_HOST#[}; EP_PORT=${1##*]:} ;;
        \[*\]) EP_HOST=${1#[}; EP_HOST=${EP_HOST%]} ;;
        *:*) EP_HOST=${1%%:*}; EP_PORT=${1#*:} ;;
        *) EP_HOST=$1 ;;
    esac
    [[ "$EP_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$EP_PORT" -ge 1 ] && [ "$EP_PORT" -le 65535 ] || return 1
    mesh_ip4_ok "$EP_HOST" && return 0
    [[ "$EP_HOST" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$EP_HOST" == *:*:* ]]
}

# Reads and checks the settings of the mesh; dies on a bad one. MESH=0: this
# server is alone (the single-server path, as before the mesh existed).
mesh_load() {
    MESH=0 MESH_IP="" MESH_PREFIX="" MESH_NET="" MESH_DC="" MESH_HUB_DC="" MESH_IS_HUB=0
    PEER_NAME=() PEER_EP=() PEER_HOST=() PEER_KEY=() PEER_IP=() PEER_DC=() PEER_HUB=()
    MESH_REGIONS="" MESH_OTHER_DCS="" MESH_SAME_IPS="" MESH_HUB_IPS="" MESH_SEEDS="" MESH_ROUTES=""
    MESH_REPLICATION="" MESH_LOCAL_RF=1 MESH_BUS_REPLICAS=1 MESH_REPAIR_ON=""
    local wg=${RELAY_MESH_WG:-off} e name ep key ip dc flag extra i j hubs="" n
    case "$wg" in
        off|"")
            [ -z "${RELAY_MESH_WG_PEERS:-}${RELAY_STORE_SEEDS:-}${RELAY_BUS_ROUTES:-}" ] \
                || die "RELAY_MESH_WG_PEERS, RELAY_STORE_SEEDS and RELAY_BUS_ROUTES go with RELAY_MESH_WG, this server's address in the WireGuard of the mesh (10.77.1.1/16); without it this server is alone: leave them empty"
            return 0 ;;
        on) die "RELAY_MESH_WG is this server's address in the WireGuard of the mesh (10.77.1.1/16), or off" ;;
    esac
    MESH_IP=${wg%%/*} MESH_PREFIX=16
    [[ "$wg" == */* ]] && MESH_PREFIX=${wg#*/}
    mesh_ip4_ok "$MESH_IP" && [[ "$MESH_PREFIX" =~ ^[0-9]{1,2}$ ]] && [ "$MESH_PREFIX" -ge 8 ] && [ "$MESH_PREFIX" -le 30 ] \
        || die "RELAY_MESH_WG=$wg: an IPv4 address with its prefix, 10.77.1.1/16 (the prefix 8 to 30: the network of the whole mesh)"
    case "$MESH_IP" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;; *) die "RELAY_MESH_WG=$wg: a private address (10/8, 172.16/12, 192.168/16), never one of the internet" ;; esac
    MESH=1
    if [ -n "${RELAY_MESH_WG_ENDPOINT:-}" ]; then
        mesh_endpoint "$RELAY_MESH_WG_ENDPOINT" \
            || die "RELAY_MESH_WG_ENDPOINT=$RELAY_MESH_WG_ENDPOINT: this server's endpoint for the others, <IPv4>[:port] or [<IPv6>][:port] (the port: $MESH_PORT if not given)"
    fi
    n=$(mesh_ip2n "$MESH_IP")
    n=$(( n & ((0xffffffff << (32 - MESH_PREFIX)) & 0xffffffff) ))
    MESH_NET=$(mesh_n2ip "$n")/$MESH_PREFIX
    [ -n "${RELAY_DC:-}" ] || RELAY_DC=$(printf '%s' "${REGION:-}" | tr '[:upper:]' '[:lower:]')
    [[ "$RELAY_DC" =~ ^[a-z][a-z0-9]{0,15}$ ]] \
        || die "RELAY_DC=$RELAY_DC: the region of this server in the mesh, lower-case letters and digits, a letter first, up to 16 (eu, us): the datacenter of Cassandra, the domain of NATS and a part of the names of the queue; set RELAY_DC"
    MESH_DC=$RELAY_DC
    [[ "$SERVER" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "SERVER=$SERVER: a server of the mesh is named by 1 to 32 letters, digits, - and _ (the name of its NATS and of its WireGuard peer)"
    for e in ${RELAY_MESH_WG_PEERS:-}; do
        IFS=, read -r name ep key ip dc flag extra <<< "$e"
        [ -z "$extra" ] || die "RELAY_MESH_WG_PEERS: \"$e\" has more than six fields (name,endpoint,public key,mesh address,region[,hub])"
        [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "RELAY_MESH_WG_PEERS: \"$e\": the name (first field) is 1 to 32 letters, digits, - and _"
        [ "$name" != "$SERVER" ] || die "RELAY_MESH_WG_PEERS: $name is this server (SERVER): list the other servers only"
        mesh_endpoint "$ep" || die "RELAY_MESH_WG_PEERS: $name: the endpoint \"$ep\" is <public IPv4>[:port] or [<IPv6>][:port] (the port: $MESH_PORT if not given)"
        [[ "$key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || die "RELAY_MESH_WG_PEERS: $name: \"$key\" is not a public key of WireGuard (44 characters of base64; veydan-server relay-peer on that server prints it)"
        mesh_ip4_ok "$ip" && mesh_in_net "$ip" || die "RELAY_MESH_WG_PEERS: $name: the mesh address \"$ip\" is not inside $MESH_NET (RELAY_MESH_WG of this server)"
        [ "$ip" != "$MESH_IP" ] || die "RELAY_MESH_WG_PEERS: $name has this server's own mesh address $ip"
        [[ "$dc" =~ ^[a-z][a-z0-9]{0,15}$ ]] || die "RELAY_MESH_WG_PEERS: $name: the region \"$dc\" is lower-case letters and digits, a letter first"
        case "$flag" in ""|hub) ;; *) die "RELAY_MESH_WG_PEERS: $name: the sixth field is hub or nothing, not \"$flag\"" ;; esac
        for j in "${!PEER_NAME[@]}"; do
            [ "${PEER_NAME[$j]}" != "$name" ] || die "RELAY_MESH_WG_PEERS: $name twice"
            [ "${PEER_IP[$j]}" != "$ip" ] || die "RELAY_MESH_WG_PEERS: $name and ${PEER_NAME[$j]} have one mesh address, $ip"
            [ "${PEER_KEY[$j]}" != "$key" ] || die "RELAY_MESH_WG_PEERS: $name and ${PEER_NAME[$j]} have one public key"
        done
        if [[ "$EP_HOST" == *:* ]]; then ep="[$EP_HOST]:$EP_PORT"; else ep="$EP_HOST:$EP_PORT"; fi
        PEER_NAME+=("$name") PEER_EP+=("$ep") PEER_HOST+=("$EP_HOST") PEER_KEY+=("$key") PEER_IP+=("$ip") PEER_DC+=("$dc") PEER_HUB+=("$flag")
        [ "$flag" = hub ] && hubs+="$dc "
    done
    hubs=$(printf '%s\n' $hubs | sort -u | sed '/^$/d')
    [ "$(printf '%s\n' "$hubs" | grep -c .)" -le 1 ] || die "RELAY_MESH_WG_PEERS: the servers marked hub are of the regions $(printf '%s ' $hubs): the hub of the leaf links is one region"
    MESH_HUB_DC=${hubs:-$MESH_DC}
    [ "$MESH_HUB_DC" = "$MESH_DC" ] && MESH_IS_HUB=1
    MESH_REGIONS=$(printf '%s\n' "$MESH_DC" "${PEER_DC[@]}" | sort -u | tr '\n' ' ')
    MESH_OTHER_DCS=$(printf '%s\n' "${PEER_DC[@]}" | sort -u | grep -vx "$MESH_DC" | tr '\n' ' ' || true)
    for i in "${!PEER_NAME[@]}"; do
        [ "${PEER_DC[$i]}" = "$MESH_DC" ] && MESH_SAME_IPS+="${PEER_IP[$i]} "
        [ "${PEER_DC[$i]}" = "$MESH_HUB_DC" ] && MESH_HUB_IPS+="${PEER_IP[$i]} "
    done
    # The routes of NATS: servers of this region, and a cluster is three or more.
    for ip in ${RELAY_BUS_ROUTES//,/ }; do
        [[ " $MESH_SAME_IPS" == *" $ip "* ]] || die "RELAY_BUS_ROUTES: $ip is not the mesh address of a server of the region $MESH_DC in RELAY_MESH_WG_PEERS"
        MESH_ROUTES+="$ip "
    done
    n=$(printf '%s\n' $MESH_ROUTES | grep -c . || true)
    [ "$n" != 1 ] || die "RELAY_BUS_ROUTES: one route makes a NATS cluster of two, which has no majority when one is away: one server a region (no routes) or three (two routes)"
    [ "$n" -ge 2 ] && MESH_BUS_REPLICAS=3
    # The seeds: the same list on every server.
    if [ -n "${RELAY_STORE_SEEDS:-}" ]; then
        for ip in ${RELAY_STORE_SEEDS//,/ }; do
            mesh_ip4_ok "$ip" && mesh_in_net "$ip" || die "RELAY_STORE_SEEDS: $ip is not an address inside $MESH_NET"
            MESH_SEEDS+="$ip,"
        done
    else
        for dc in $MESH_REGIONS; do
            for ip in $(mesh_region_servers "$dc" | awk '{print $2}' | head -n "$( [ "$(mesh_region_servers "$dc" | grep -c .)" -ge 3 ] && echo 2 || echo 1)"); do
                MESH_SEEDS+="$ip,"
            done
        done
    fi
    MESH_SEEDS=${MESH_SEEDS%,}
    # Copies of the rows: one a region, three from three servers on.
    for dc in $MESH_REGIONS; do
        n=$(mesh_region_servers "$dc" | grep -c .)
        n=$([ "$n" -ge 3 ] && echo 3 || echo 1)
        MESH_REPLICATION+="$dc:$n,"
        [ "$dc" = "$MESH_DC" ] && MESH_LOCAL_RF=$n
    done
    MESH_REPLICATION=${MESH_REPLICATION%,}
    # The weekly repair: a day of its own for each server (cluster.md 1.3).
    i=$(printf '%s\n' "$SERVER" "${PEER_NAME[@]}" | sort -V | grep -nx "$SERVER" | cut -d: -f1)
    i=$((i - 1))
    MESH_REPAIR_ON="${MESH_DAYS[$(( (i * 3) % 7 ))]} *-*-* $(printf '%02d' $(( 3 + i / 7 ))):30:00 UTC"
    return 0
}

# "name ip" of every server of a region, this one included, by name.
mesh_region_servers() { # mesh_region_servers <dc>
    local i
    {
        [ "$1" = "$MESH_DC" ] && printf '%s %s\n' "$SERVER" "$MESH_IP"
        for i in "${!PEER_NAME[@]}"; do
            [ "${PEER_DC[$i]}" != "$1" ] || printf '%s %s\n' "${PEER_NAME[$i]}" "${PEER_IP[$i]}"
        done
    } | sort -V
}

mesh_peer_index() { # mesh_peer_index <name> → the index, or 1
    local i
    for i in "${!PEER_NAME[@]}"; do [ "${PEER_NAME[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }; done
    return 1
}

# The state of this server in the mesh: founder (the first, alone when it
# came up), joined (relay-join done), or pending (peers, not joined yet).
mesh_state() {
    if [ -f "$(target "$MESH_JOINED")" ]; then printf joined
    elif [ "${#PEER_NAME[@]}" = 0 ]; then printf founder
    else printf pending
    fi
}

# --- WireGuard -------------------------------------------------------------------

# This server's key pair: the private key made once (0600, never printed).
mesh_wg_key() {
    local k; k=$(target "$MESH_WG_DIR/$MESH_IF.key")
    mkdirp "$MESH_WG_DIR" 0700 root:root
    if [ ! -s "$k" ]; then
        if command -v wg >/dev/null; then
            ( umask 077; wg genkey ) | put "$MESH_WG_DIR/$MESH_IF.key" 0600 root:root
        else
            [ "$DRY" = 1 ] || die "mesh: no wg (wireguard-tools) to make the key with"
            openssl rand -base64 32 | put "$MESH_WG_DIR/$MESH_IF.key" 0600 root:root
        fi
        say "mesh: the WireGuard key of this server made ($MESH_WG_DIR/$MESH_IF.key, 0600, never printed)"
    elif [ "$DRY" != 1 ]; then
        chown root:root "$k"; chmod 0600 "$k"
    fi
    if command -v wg >/dev/null; then
        MESH_PUBKEY=$(wg pubkey < "$k")
    else
        # A dry run without wireguard-tools: a stand-in of the right form.
        MESH_PUBKEY=$(openssl dgst -sha256 -binary < "$k" | base64 | tr -d '\n')
    fi
}

mesh_psk() { printf '%s/psk-%s' "$MESH_WG_DIR" "$1"; }

# Whether an IPv4 is an address of the internet: not private (10/8,
# 172.16/12, 192.168/16), shared (100.64/10), loopback, link-local or 0/8.
mesh_public_ip4() { # mesh_public_ip4 <a.b.c.d>
    local b
    mesh_ip4_ok "$1" || return 1
    case "$1" in 0.*|10.*|127.*|169.254.*|192.168.*) return 1 ;; esac
    b=${1#*.}; b=$((10#${b%%.*}))
    case "$1" in 172.*) [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1 ;; 100.*) [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1 ;; esac
    return 0
}

# This server's endpoint, what the other servers reach its WireGuard at:
# RELAY_MESH_WG_ENDPOINT when the admin sets it (any address, a private one
# too: two servers of one provider's network), else the first public one
# of: its line in MESH_ORIGINS, CALL_PUBLIC_IP, its own addresses (hostname
# -I), the address of its relay's name (not Cloudflare's edge). A private
# address is never taken by itself (an address of a provider's private
# network in MESH_ORIGINS cannot be reached by a server elsewhere).
mesh_self_endpoint() {
    local ip c
    if [ -n "${RELAY_MESH_WG_ENDPOINT:-}" ]; then
        mesh_endpoint "$RELAY_MESH_WG_ENDPOINT" || die "RELAY_MESH_WG_ENDPOINT=$RELAY_MESH_WG_ENDPOINT: <IPv4>[:port] or [<IPv6>][:port]"
        if [[ "$EP_HOST" == *:* ]]; then printf '[%s]:%s' "$EP_HOST" "$EP_PORT"; else printf '%s:%s' "$EP_HOST" "$EP_PORT"; fi
        return 0
    fi
    for c in "$(origin_of "$SERVER" 2>/dev/null || true)" "${CALL_PUBLIC_IP:-}" $(hostname -I 2>/dev/null || true); do
        mesh_public_ip4 "$c" && { ip=$c; break; }
    done
    if [ -z "${ip:-}" ] && [ -n "${RELAY_HOST:-}" ]; then
        for c in $( { getent ahostsv4 "$(fqdn "$RELAY_HOST")" 2>/dev/null || true; } | awk '{print $1}' | sort -u); do
            mesh_public_ip4 "$c" && ! cloudflare_ip "$c" "$HERE/templates/cloudflare-ips.txt" && { ip=$c; break; }
        done
    fi
    if [ -z "${ip:-}" ]; then
        printf '\033[1;33m!!\033[0m %s\n' "mesh: no public address of this server found (MESH_ORIGINS, CALL_PUBLIC_IP, hostname -I, the DNS of its relay): set RELAY_MESH_WG_ENDPOINT in server.conf, the address the other servers reach it at" >&2
    fi
    printf '%s:%s' "${ip:-<public address>}" "$MESH_PORT"
}

# The line the other servers put in their RELAY_MESH_WG_PEERS.
mesh_line() {
    printf '%s,%s,%s,%s,%s%s\n' "$SERVER" "$(mesh_self_endpoint)" "$MESH_PUBKEY" "$MESH_IP" "$MESH_DC" "$([ "$MESH_IS_HUB" = 1 ] && echo ,hub)"
}

mesh_wg_render() {
    local conf=$MESH_WG_DIR/$MESH_IF.conf real text i psk
    real=$(target "$conf")
    if [ -f "$real" ] && ! grep -qxF "$MESH_MARK" "$real"; then
        die "mesh: $conf is there and is not the kit's: the mesh takes the interface $MESH_IF; move that file away (and its interface down), then run again"
    fi
    text="$MESH_MARK
# The WireGuard of the mesh of vrelay (spec/security.md 6): one [Peer] for each
# other server of RELAY_MESH_WG_PEERS, each with the key shared by the pair.
# 0600 root: it holds this server's private key.
[Interface]
Address = $MESH_IP/$MESH_PREFIX
ListenPort = $MESH_PORT
PrivateKey = $(cat "$(target "$MESH_WG_DIR/$MESH_IF.key")")
"
    for i in "${!PEER_NAME[@]}"; do
        psk=$(target "$(mesh_psk "${PEER_NAME[$i]}")")
        text+="
[Peer]
# ${PEER_NAME[$i]} (${PEER_DC[$i]}$([ "${PEER_HUB[$i]}" = hub ] && echo ", hub" || true))
PublicKey = ${PEER_KEY[$i]}
"
        if [ -s "$psk" ]; then
            text+="PresharedKey = $(cat "$psk")
"
        else
            text+="# no PresharedKey yet: it comes with veydan-server relay-join (or relay-peer add on this side)
"
        fi
        text+="AllowedIPs = ${PEER_IP[$i]}/32
Endpoint = ${PEER_EP[$i]}
PersistentKeepalive = 25
"
    done
    printf '%s' "$text" | put "$conf" 0600 root:root
}

mesh_wg_apply() {
    if [ "$DRY" = 1 ]; then
        run systemctl enable wg-quick@$MESH_IF
        run "wg syncconf $MESH_IF <(wg-quick strip $MESH_IF), or systemctl restart wg-quick@$MESH_IF when its address changed"
        return 0
    fi
    systemctl enable "wg-quick@$MESH_IF" >/dev/null 2>&1 || true
    if ip link show "$MESH_IF" >/dev/null 2>&1; then
        if ip -br addr show "$MESH_IF" | grep -qw "$MESH_IP/$MESH_PREFIX"; then
            wg syncconf "$MESH_IF" <(wg-quick strip "$MESH_IF") || die "mesh: wg syncconf $MESH_IF failed"
        else
            systemctl restart "wg-quick@$MESH_IF" || die "mesh: wg-quick@$MESH_IF did not start (journalctl -u wg-quick@$MESH_IF)"
        fi
    else
        systemctl start "wg-quick@$MESH_IF" || die "mesh: wg-quick@$MESH_IF did not start (journalctl -u wg-quick@$MESH_IF)"
    fi
}

# The firewall of the mesh (spec/security.md 3): WireGuard's port from the
# other servers' public addresses; Cassandra between nodes (7000) and its
# clients (9042) from every server of the mesh, NATS's clients (4222) and
# routes (6222) from the servers of this region, the leaf links (7422) on
# the hub from the servers of the other regions: those on wg0 alone. The
# rules carry the comment veydan-mesh; one no longer wanted is deleted.
mesh_firewall() {
    [ "${FIREWALL:-ufw}" = ufw ] || { warn "mesh: FIREWALL=none: open $MESH_PORT/udp to the other servers yourself, and 7000, 9042, 4222, 6222, 7422 on $MESH_IF only"; return 0; }
    local want=() i r line
    for i in "${!PEER_NAME[@]}"; do
        want+=("allow from ${PEER_HOST[$i]} to any port $MESH_PORT proto udp comment 'veydan-mesh ${PEER_NAME[$i]} wireguard'")
        want+=("allow in on $MESH_IF from ${PEER_IP[$i]} to any port 7000 proto tcp comment 'veydan-mesh ${PEER_NAME[$i]} cassandra'")
        want+=("allow in on $MESH_IF from ${PEER_IP[$i]} to any port 9042 proto tcp comment 'veydan-mesh ${PEER_NAME[$i]} cql'")
        if [ "${PEER_DC[$i]}" = "$MESH_DC" ]; then
            want+=("allow in on $MESH_IF from ${PEER_IP[$i]} to any port 4222 proto tcp comment 'veydan-mesh ${PEER_NAME[$i]} nats'")
            [ -z "$MESH_ROUTES" ] || want+=("allow in on $MESH_IF from ${PEER_IP[$i]} to any port 6222 proto tcp comment 'veydan-mesh ${PEER_NAME[$i]} nats routes'")
        elif [ "$MESH_IS_HUB" = 1 ]; then
            want+=("allow in on $MESH_IF from ${PEER_IP[$i]} to any port 7422 proto tcp comment 'veydan-mesh ${PEER_NAME[$i]} nats leaf'")
        fi
    done
    if [ "$DRY" = 1 ]; then
        for r in "${want[@]}"; do run ufw "$r"; done
        return 0
    fi
    command -v ufw >/dev/null || die "mesh: no ufw (FIREWALL=ufw)"
    # What is there and no longer wanted goes.
    while IFS= read -r line; do
        line=${line#ufw }
        [[ " ${want[*]} " == *"$line"* ]] && continue
        r=${line% comment *}
        # shellcheck disable=SC2086  # a rule of ufw, word by word
        eval "ufw delete $r" >/dev/null && say "mesh: firewall: no longer: $r"
    done < <(ufw show added 2>/dev/null | grep "comment 'veydan-mesh " || true)
    for r in "${want[@]}"; do
        # shellcheck disable=SC2086
        eval "ufw $r" >/dev/null
    done
}

# chrony, not systemd-timesyncd (SNTP only): a step only in the first three
# updates (spec/cluster.md 1.6). The audit reads its offset.
mesh_chrony() {
    apt_install chrony
    local f; f=$(target /etc/chrony/chrony.conf)
    if [ "$DRY" != 1 ] && [ -f "$f" ] && ! grep -qx 'makestep 0.1 3' "$f"; then
        if grep -q '^makestep ' "$f"; then sed -i 's/^makestep .*/makestep 0.1 3/' "$f"; else echo 'makestep 0.1 3' >> "$f"; fi
        run systemctl restart chrony
    fi
    run systemctl enable --now chrony
}

# --- NATS --------------------------------------------------------------------------

# A password of the mesh, made once (64 hex), never printed.
mesh_secret() { # mesh_secret <path> <owner:group>
    if [ ! -s "$(target "$1")" ]; then
        secret | put "$1" 0600 "$2"
        say "mesh: $1 made"
    elif [ "$DRY" != 1 ]; then
        chown "$2" "$1"; chmod 0600 "$1"
    fi
}

# NATS of this region (templates/relay-compose/mesh/nats.conf): the domain,
# the users serve, write and migrate with the subjects of their region
# (spec/security.md 4.2), the leaf links. Written with its passwords into
# the secrets of the containers: the folder and the file are root's, read
# by the group of NATS's user (0750, 0640), so that root writes in no
# folder of another user.
mesh_nats_conf() { # mesh_nats_conf <template> <owner:group of the secrets of NATS>
    local tpl=$1 owner=$2 cs=$MESH_CSEC ip users="" urls="" dc f prev
    pw() { cat "$(target "$cs/$1")"; }
    # A folder of its own, mounted whole (mesh.yaml).
    mkdirp "$cs/nats" 0750 "root:${owner#*:}"
    V_NATS_SERVER_NAME=$SERVER V_MESH_IP=$MESH_IP V_R=$MESH_DC V_RU=$(mesh_up "$MESH_DC")
    V_NATS_SERVE_PASSWORD=$(pw nats-serve-password) V_NATS_WRITE_PASSWORD=$(pw nats-write-password)
    V_NATS_MIGRATE_PASSWORD=$(pw nats-migrate-password) V_NATS_SYS_PASSWORD=$(pw nats-sys-password)
    if [ -n "$MESH_ROUTES" ]; then
        local routes=""
        for ip in $MESH_ROUTES; do routes+="    \"nats-route://route:$(pw nats-route-password)@$ip:6222\""$'\n'; done
        V_NATS_CLUSTER_BLOCK="# The cluster of the region: routes on the mesh (spec/cluster.md 2.7).
cluster {
  name: \"$MESH_DC\"
  listen: \"$MESH_IP:6222\"
  authorization { user: route, password: \"$(pw nats-route-password)\" }
  routes: [
${routes%$'\n'}
  ]
}"
        # A standalone server with streams, given routes, lost them in a
        # trial (spec/cluster.md 2.7): the region grows by backup and restore.
        prev=$(target "$cs/nats/nats.conf")
        if [ -f "$prev" ] && ! grep -q '^cluster {' "$prev" && [ -n "$(ls -A "$(target /opt/vrelay/data/nats)/jetstream" 2>/dev/null)" ]; then
            die "RELAY_BUS_ROUTES: the NATS of this server is standalone and holds streams; routes given to it would lose them (spec/cluster.md 2.7). Grow the region by backup and restore: README, \"Two regions\", \"A region of three\""
        fi
    else
        V_NATS_CLUSTER_BLOCK="# One server in this region: JetStream standalone, no cluster block (spec/cluster.md 2.7)."
    fi
    if [ "$MESH_IS_HUB" = 1 ]; then
        for dc in $MESH_OTHER_DCS; do
            f=nats-leaf-$dc-password
            mesh_secret "$cs/$f" "$owner"
            users+="      { user: \"leaf_$dc\", password: \"$(pw "$f")\", account: VRELAY }"$'\n'
        done
        if [ -n "$users" ]; then
            V_NATS_LEAF_BLOCK="# The hub of the leaf links (spec/cluster.md 2.1): the other regions connect here.
leafnodes {
  listen: \"$MESH_IP:7422\"
  authorization {
    users: [
${users%$'\n'}
    ]
  }
}"
        else
            V_NATS_LEAF_BLOCK="# The hub of the leaf links, no other region yet: nothing listens on 7422."
        fi
    else
        f=nats-leaf-$MESH_DC-password
        if [ -s "$(target "$cs/$f")" ]; then
            for ip in $MESH_HUB_IPS; do urls+="\"nats-leaf://leaf_$MESH_DC:$(pw "$f")@$ip:7422\", "; done
            V_NATS_LEAF_BLOCK="# The leaf link to the hub region $MESH_HUB_DC (spec/cluster.md 2.1), bound to the
# account VRELAY; the subjects that stay in their region are denied both ways.
leafnodes {
  remotes: [
    {
      urls: [ ${urls%, } ]
      account: VRELAY
      deny_imports: [ \"vrelay.*.write.>\", \"vrelay.*.ack.>\", \"vrelay.*.out.>\", \"vrelay.*.presence.>\", \"\$JS.API.>\" ]
      deny_exports: [ \"vrelay.*.write.>\", \"vrelay.*.ack.>\", \"vrelay.*.out.>\", \"vrelay.*.presence.>\", \"\$JS.API.>\" ]
    }
  ]
}"
        else
            V_NATS_LEAF_BLOCK="# The leaf link to the hub region $MESH_HUB_DC: its password comes with veydan-server relay-join."
        fi
    fi
    render "$tpl" "$cs/nats/nats.conf" 0640 "root:${owner#*:}"
    unset -f pw
    unset V_NATS_SERVE_PASSWORD V_NATS_WRITE_PASSWORD V_NATS_MIGRATE_PASSWORD V_NATS_SYS_PASSWORD V_NATS_CLUSTER_BLOCK V_NATS_LEAF_BLOCK
}

# A NATS that runs takes a changed config: a reload, or a restart when its
# leaf links changed, which NATS 2.15.3 does not reload ("config reload not
# supported for LeafNode: field Users", tried 2026-11-22): seconds; the
# streams are on its disk and vrelay tries again meanwhile.
mesh_nats_reload() { # mesh_nats_reload <config before> <config after>
    [ "$1" != "$2" ] || return 0
    if [ "$DRY" != 1 ] && [ -z "$(vrelay_compose ps -q --status running nats 2>/dev/null)" ]; then
        return 0
    fi
    if [ "$(sed -n '/^leafnodes {/,/^}/p' <<< "$1")" != "$(sed -n '/^leafnodes {/,/^}/p' <<< "$2")" ] \
        || [ "$(sed -n '/^cluster {/,/^}/p' <<< "$1")" != "$(sed -n '/^cluster {/,/^}/p' <<< "$2")" ]; then
        warn "mesh: the leaf links or the routes of NATS changed: NATS restarts (seconds; the relay of this region waits for it)"
        vrelay_compose restart nats >/dev/null
    else
        vrelay_compose kill -s SIGHUP nats >/dev/null && say "mesh: NATS read its config again"
    fi
}

# --- vrelay ------------------------------------------------------------------------

# The settings of the store and the bus in vrelay.env (between its kit marks).
mesh_vrelay_env() { # mesh_vrelay_env <dir of vrelay's secrets>
    local r=$MESH_DC ru; ru=$(mesh_up "$MESH_DC")
    local nodes="$MESH_IP:9042" servers="nats://$MESH_IP:4222" ip peers
    for ip in $MESH_ROUTES; do servers+=",nats://$ip:4222"; done
    peers=$(printf '%s\n' $MESH_OTHER_DCS | paste -sd, -)
    cat <<EOF
# Cassandra and NATS of this server, on its address in the mesh ($MESH_IF,
# $MESH_IP): the datacenter $r of the cluster and the JetStream domain $r,
# every name of the queue with the region (spec/cluster.md 2.2). The user of
# NATS is the mode's: vrelay-serve.env, vrelay-write.env beside this file.
VRELAY_STORE_NODES=$nodes
VRELAY_STORE_KEYSPACE=vrelay
VRELAY_STORE_LOCAL_DC=$r
VRELAY_STORE_REPLICATION=$MESH_REPLICATION
VRELAY_STORE_REPLICATION_FACTOR=$MESH_LOCAL_RF
VRELAY_STORE_WRITE_CONSISTENCY=local_quorum
VRELAY_STORE_READ_CONSISTENCY=local_quorum
VRELAY_STORE_USERNAME=vrelay
VRELAY_STORE_PASSWORD_FILE=$1/cassandra-password
VRELAY_BUS_SERVERS=$servers
VRELAY_BUS_STREAM_REPLICAS=$MESH_BUS_REPLICAS
# Four GiB of queue: minutes of a peak while no writer stores, not seconds
# (services/relay/spec/tuning.md 6); under max_file_store of its NATS.
VRELAY_BUS_STREAM_MAX_BYTES=4294967296
VRELAY_REGION_NAME=$r
VRELAY_REGION_PEERS=$peers
VRELAY_BUS_QUEUE_PREFIX=vrelay.$r.write
VRELAY_BUS_ACK_PREFIX=vrelay.$r.ack
VRELAY_BUS_STREAM=VRELAY_WRITE_$ru
VRELAY_BUS_LIVE_PREFIX=vrelay.live
VRELAY_PRESENCE_SUBJECT_PREFIX=vrelay.$r.presence
VRELAY_PRESENCE_STREAM=VRELAY_PRESENCE_$ru
VRELAY_REGION_OUT_PREFIX=vrelay.$r.out
VRELAY_REGION_OUT_STREAM=VRELAY_OUT_$ru
VRELAY_REGION_IN_STREAM=VRELAY_IN_$ru
EOF
}

# The user of NATS of a mode, as words of env: KEY=value ...
mesh_mode_env() { # mesh_mode_env <mode>
    local f=/opt/vrelay/etc/vrelay-$1.env
    [ -f "$(target "$f")" ] || return 0
    grep -E '^VRELAY_[A-Z_]+=' "$(target "$f")" | tr '\n' ' '
}

# --- the key a joining server takes ------------------------------------------------

# HMAC-SHA256 of the input with <key> (64 characters at most), in hex. Bash
# and sha256sum alone: the key is never an argument of a program, where
# every user of the machine reads it in /proc/*/cmdline.
mesh_hmac() { # mesh_hmac <key>   (the message on stdin)
    local k=$1 i c ipad="" opad="" inner b=()
    # The bytes of the key; a key longer than the block is its SHA-256.
    if [ "${#k}" -gt 64 ]; then
        k=$(printf '%s' "$k" | sha256sum | cut -c1-64)
        for ((i = 0; i < 64; i += 2)); do b+=($((16#${k:i:2}))); done
    else
        for ((i = 0; i < ${#k}; i++)); do b+=("$(LC_ALL=C printf '%d' "'${k:i:1}")"); done
    fi
    for ((i = 0; i < 64; i++)); do
        c=${b[i]:-0}
        ipad+=$(printf '\\x%02x' $((c ^ 0x36)))
        opad+=$(printf '\\x%02x' $((c ^ 0x5c)))
    done
    # shellcheck disable=SC2059  # the pads are escapes of printf, on purpose
    inner=$( { printf "$ipad"; cat; } | sha256sum | cut -c1-64)
    # shellcheck disable=SC2059
    { printf "$opad"; printf "$(printf '%s' "$inner" | sed 's/../\\x&/g')"; } | sha256sum | cut -c1-64
}

# The mark of a join key: the HMAC of its text with MESH_PEER_KEY, the key of
# the network that every server of it holds (server.conf) and no client.
mesh_join_mac() { # mesh_join_mac <base64 of the text>
    [ -n "${MESH_PEER_KEY:-}" ] || die "mesh: no MESH_PEER_KEY in server.conf: a join key is marked with it"
    printf 'veydan.relay-join.v2\n%s' "$1" | mesh_hmac "$MESH_PEER_KEY"
}

# veydan-relay-join-2.<base64 of NAME=value lines>.<mark>, for one peer: the
# key shared with it (WireGuard), the passwords of the roles vrelay and
# migrate of the store (one cluster; never its superuser: relay-admit on a
# server that has it does what needs one), the password of the leaf link of
# its region, and, for a server of this region, the users of NATS and the
# password of the routes; ISSUED, when it was made (relay-join refuses it
# RELAY_JOIN_KEY_HOURS later, 24 by default), and the mark (mesh_join_mac).
# Written by relay-peer add to a file of root alone, or to its output on
# --stdout; never into a command line.
mesh_join_key() { # mesh_join_key <peer name>
    local i dc lines cs=$MESH_CSEC f body
    i=$(mesh_peer_index "$1") || die "relay-peer: no peer $1"
    dc=${PEER_DC[$i]}
    [ -s "$(target "$cs/cassandra-migrate-password")" ] \
        || die "relay-peer: this server has no password of the role migrate of the store (it joined with a key of the first form): run veydan-server relay-peer add on the first server of the mesh"
    rd() { tr -d '\n' < "$(target "$1")"; }
    lines="V=2
FOR=$1
FROM=$SERVER
FROM_DC=$MESH_DC
ISSUED=${VEYDAN_NOW:-$(date +%s)}
PSK=$(rd "$(mesh_psk "$1")")
CASSANDRA_VRELAY=$(rd "$cs/cassandra-vrelay-password")
CASSANDRA_MIGRATE=$(rd "$cs/cassandra-migrate-password")"
    f=$cs/nats-leaf-$dc-password
    [ "$dc" != "$MESH_HUB_DC" ] && [ -s "$(target "$f")" ] && lines+="
LEAF=$(rd "$f")"
    if [ "$dc" = "$MESH_DC" ]; then
        # A server of this region: the users of its NATS, the password of
        # the routes the region's three will share (made now if missing),
        # and on the hub the leaf users of the other regions.
        mesh_secret "$cs/nats-route-password" vrelay-bus:vrelay-bus >&2
        lines+="
NATS_SERVE=$(rd "$cs/nats-serve-password")
NATS_WRITE=$(rd "$cs/nats-write-password")
NATS_MIGRATE=$(rd "$cs/nats-migrate-password")
NATS_SYS=$(rd "$cs/nats-sys-password")
NATS_ROUTE=$(rd "$cs/nats-route-password")"
        for f in $MESH_OTHER_DCS; do
            [ "$MESH_IS_HUB" = 1 ] && [ -s "$(target "$cs/nats-leaf-$f-password")" ] || continue
            lines+="
LEAF_$(mesh_up "$f")=$(rd "$cs/nats-leaf-$f-password")"
        done
    fi
    unset -f rd
    body=$(printf '%s\n' "$lines" | base64 -w0)
    printf 'veydan-relay-join-2.%s.%s\n' "$body" "$(mesh_join_mac "$body")"
}

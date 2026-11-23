#!/usr/bin/env bash
# The mesh of vrelay after the installer (lib/mesh.sh): run by veydan-server.
#
#   relay-mesh.sh peer                 this server's line, and its peers
#   relay-mesh.sh peer add [--replace] [--hub] [--stdout] <line>
#                                      a server joins the mesh: into
#                                      RELAY_MESH_WG_PEERS, WireGuard, the
#                                      firewall, NATS; its key to a file of
#                                      root (--stdout: to the output).
#                                      --replace: a peer of that name gets
#                                      the new line, a new shared key and a
#                                      new key; --hub: the line may move the
#                                      hub of the leaf links
#   relay-mesh.sh peer remove <name>   a server leaves (its node of Cassandra
#                                      is removed by hand: README)
#   relay-mesh.sh peer apply           WireGuard, the firewall and NATS anew from
#                                      server.conf (after an edit of it by hand)
#   relay-mesh.sh peer rotate-leaf <region>  on the hub: a new password of the
#                                      leaf link of a region
#   relay-mesh.sh join [--key-file <file>]...  this server joins the cluster,
#                                      step by step, a check after each; then
#                                      the kit. The keys from the files (0600,
#                                      root's), else on the input, one a line;
#                                      never an argument. On a server that has
#                                      joined: new keys of its peers taken
#   relay-mesh.sh admit <name>         on a server with the superuser of the
#                                      store: the keyspaces get a copy in the
#                                      region of the peer that joins
#   relay-mesh.sh nodetool <args>      nodetool of this node
#
# --dry-run (first): the files under $DRY_ROOT, nothing run (the tests).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/mesh.sh
. "$HERE/lib/mesh.sh"
# shellcheck source=versions.conf
. "$HERE/versions.conf"

if [ "${1:-}" = --dry-run ]; then DRY=1; DRY_ROOT=${DRY_ROOT:?--dry-run needs DRY_ROOT}; shift; fi
STATE=${VEYDAN_STATE:-/opt/veydan}
CONF=$STATE/server.conf
R=/opt/vrelay
RC=$VRELAY_COMPOSE
TPL=$HERE/templates/relay-compose

load() {
    [ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root"
    [ -r "$CONF" ] || die "no $CONF: run install.sh once"
    # shellcheck disable=SC1090
    . "$CONF"
    : "${COMPONENTS:=} ${RELAY_ENGINE:=strfry} ${SERVER:=} ${FIREWALL:=ufw} ${MESH_ORIGINS:=}"
    [[ " $COMPONENTS " == *" relay "* ]] && [ "$RELAY_ENGINE" = vrelay ] \
        || die "the mesh is of the vrelay engine: this server has no relay of RELAY_ENGINE=vrelay"
    mesh_load
    [ "$MESH" = 1 ] || die "this server is in no mesh: RELAY_MESH_WG of $CONF is off (README, \"Two regions\")"
}

# A setting of server.conf: its line rewritten, or added.
conf_set() { # conf_set <NAME> <value>
    local tmp; tmp=$(mktemp)
    NAME=$1 VAL="$1=$(printf '%q' "$2")" awk '
        BEGIN { n = ENVIRON["NAME"] "=" }
        index($0, n) == 1 && !d { print ENVIRON["VAL"]; d = 1; next }
        { print }
        END { if (!d) print ENVIRON["VAL"] }' "$CONF" > "$tmp"
    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

# WireGuard, the firewall and NATS anew from server.conf, and the seeds of
# Cassandra for its next start; nothing else of the kit.
apply() {
    mesh_wg_key
    mesh_wg_render
    mesh_wg_apply
    mesh_firewall
    if [ -f "$(target "$MESH_CSEC/nats/nats.conf")" ]; then
        local before after
        before=$(cat "$(target "$MESH_CSEC/nats/nats.conf")")
        mesh_nats_conf "$TPL/mesh/nats.conf" vrelay-bus:vrelay-bus
        after=$(cat "$(target "$MESH_CSEC/nats/nats.conf")")
        mesh_nats_reload "$before" "$after"
    fi
    local env; env=$(target "$RC/.env")
    if [ -f "$env" ] && ! grep -qx "CASSANDRA_SEEDS=$MESH_SEEDS" "$env"; then
        sed -i "s/^CASSANDRA_SEEDS=.*/CASSANDRA_SEEDS=$MESH_SEEDS/" "$env"
        say "mesh: the seeds of Cassandra are $MESH_SEEDS from its next start (veydan-server rerun)"
    fi
}

cmd_peer_show() {
    load
    mesh_wg_key
    echo "This server's line, for RELAY_MESH_WG_PEERS of the others (veydan-server relay-peer add '<line>' there):"
    echo "   $(mesh_line)"
    echo "State: $(mesh_state); region $MESH_DC; hub of the leaf links: $MESH_HUB_DC; seeds: $MESH_SEEDS"
    local i now ts hs; now=$(date +%s)
    for i in "${!PEER_NAME[@]}"; do
        hs="no handshake"
        if [ "$DRY" != 1 ] && ts=$(wg show "$MESH_IF" latest-handshakes 2>/dev/null | awk -v k="${PEER_KEY[$i]}" '$1 == k {print $2}') && [ -n "$ts" ] && [ "$ts" != 0 ]; then
            hs="handshake $((now - ts)) s ago"
        fi
        [ -s "$(target "$(mesh_psk "${PEER_NAME[$i]}")")" ] || hs+=", no shared key"
        printf '   %-12s %-6s %-15s %s  (%s)\n' "${PEER_NAME[$i]}" "${PEER_DC[$i]}" "${PEER_IP[$i]}" "${PEER_EP[$i]}" "$hs"
    done
}

# The key of a peer: made by relay-peer add, a file of root alone (0600 in a
# folder 0700), or the output on --stdout; never a command line.
KEYS_DIR=$R/etc/mesh-keys

cmd_peer_add() {
    local usage="veydan-server relay-peer add [--replace] [--hub] [--stdout] '<name,endpoint,public key,mesh address,region[,hub]>'"
    local line="" replace=0 hub=0 out=file name e new="" old="" hub_before file
    while [ $# -gt 0 ]; do
        case "$1" in
            --replace) replace=1 ;;
            --hub) hub=1 ;;
            --stdout) out=stdout ;;
            -*) die "$usage" ;;
            *) [ -z "$line" ] || die "relay-peer add: one line, in quotes ($usage)"; line=$1 ;;
        esac
        shift
    done
    [ -n "$line" ] || die "$usage"
    load
    [ "$(mesh_state)" != pending ] || die "relay-peer add: this server has not joined the mesh yet (veydan-server relay-join)"
    name=${line%%,*}
    for e in ${RELAY_MESH_WG_PEERS:-}; do
        if [ "${e%%,*}" = "$name" ]; then old=$e; else new+="$e "; fi
    done
    if [ -n "$old" ] && [ "$replace" != 1 ]; then
        die "relay-peer add: $name is a peer already ($old). A new line for it (a server put up again, a new key of it) with --replace: the pair gets a new shared key, and $name a new key to take (veydan-server relay-join there)"
    fi
    hub_before=$MESH_HUB_DC
    new+=$line
    RELAY_MESH_WG_PEERS=$new
    mesh_load
    if [ "$MESH_HUB_DC" != "$hub_before" ] && [ "$hub" != 1 ]; then
        die "relay-peer add: with this line the hub of the leaf links would be $MESH_HUB_DC, not $hub_before as now; every region's NATS links there. If that is meant: --hub (then veydan-server relay-peer apply on every server); else the line without ,hub"
    fi
    conf_set RELAY_MESH_WG_PEERS "$RELAY_MESH_WG_PEERS"
    local psk; psk=$(mesh_psk "$name")
    # Nothing but the key (on --stdout) goes to the output: the rest to stderr.
    {
        # A peer replaced gets a new key of the pair: the old one ends here.
        # (target: under the root of a dry run, so a dry run shows the new one.)
        if [ -n "$old" ]; then rm -f "$(target "$psk")"; fi
        if [ ! -s "$(target "$psk")" ]; then
            if command -v wg >/dev/null; then ( umask 077; wg genpsk ) | put "$psk" 0600 root:root
            else [ "$DRY" = 1 ] || die "no wg"; openssl rand -base64 32 | put "$psk" 0600 root:root; fi
            say "mesh: the key of the pair $SERVER–$name made ($psk, 0600)"
        fi
        apply
        say "mesh: $name is a peer of this server (RELAY_MESH_WG_PEERS of $CONF)"
    } >&2
    if [ "$out" = stdout ]; then
        printf '%s\n' \
            "The key for $name (on the output): it holds the passwords of the roles of the" \
            "store, of NATS for it, and the key of this pair; it is good for" \
            "RELAY_JOIN_KEY_HOURS (24 by default) on $name. Hand it on by a pipe or a file" \
            "of root, never in a command line, to $name alone; there:" \
            "   veydan-server relay-join < <the file>" \
            "Once $name has joined: veydan-server rerun here, so that vrelay takes its region." >&2
        mesh_join_key "$name"
        return 0
    fi
    mkdirp "$KEYS_DIR" 0700 root:root
    file=$KEYS_DIR/$name.key
    ( umask 077; mesh_join_key "$name" ) | put "$file" 0600 root:root
    printf '%s\n' \
        "The key for $name is in $file (0600 root). It holds the passwords of the roles" \
        "of the store, of NATS for it, and the key of this pair; it is good for" \
        "RELAY_JOIN_KEY_HOURS (24 by default) on $name. Copy it to $name by a safe way" \
        "(scp to root), and to nobody else; there:" \
        "   veydan-server relay-join --key-file <the file>" \
        "   (or: veydan-server relay-join < <the file>)" \
        "then remove it here and there. Once $name has joined: veydan-server rerun here," \
        "so that vrelay takes its region." >&2
}

cmd_peer_remove() {
    local name=${1:?veydan-server relay-peer remove <name>} e new="" i dc
    load
    i=$(mesh_peer_index "$name") || die "relay-peer remove: no peer $name"
    dc=${PEER_DC[$i]}
    for e in ${RELAY_MESH_WG_PEERS:-}; do [ "${e%%,*}" = "$name" ] || new+="$e "; done
    RELAY_MESH_WG_PEERS=${new% }
    mesh_load
    conf_set RELAY_MESH_WG_PEERS "$RELAY_MESH_WG_PEERS"
    # The key of the pair ends with it (a later add makes a new one), and so
    # does a key file for it still here.
    rm -f "$(target "$(mesh_psk "$name")")" "$(target "$KEYS_DIR/$name.key")"
    apply
    say "mesh: $name is no peer of this server any more; the key of the pair is gone"
    {
        echo "Its node of Cassandra stays in the cluster until removed: on it, veydan-server relay-nodetool decommission; if it is gone, here: veydan-server relay-nodetool removenode <its host id of nodetool status> (README, \"Two regions\")"
        echo "What $name knew, and what ends it (a server given away or lost):"
        if [ "$dc" != "$MESH_DC" ]; then
            if [ "$MESH_IS_HUB" = 1 ]; then
                echo "   the password of the leaf link of the region $dc: here, veydan-server relay-peer rotate-leaf $dc (then a new key for each other server of $dc)"
            else
                echo "   the password of the leaf link of the region $dc: on the hub ($MESH_HUB_DC), veydan-server relay-peer rotate-leaf $dc"
            fi
        else
            echo "   the users of NATS of the region $dc and the password of its routes: by hand, on every server of $dc (README, \"Two regions\")"
        fi
        echo "   the passwords of the roles vrelay and vrelay_migrate of the store (the cluster's; never its superuser): by hand (README, \"Two regions\")"
    } >&2
}

# On the hub: a new password of the leaf link of a region (after a server of
# it left, or the password was seen). The servers of that region need it: a
# new key for each (relay-peer add --replace), taken there by relay-join.
cmd_peer_rotate_leaf() {
    local dc=${1:?veydan-server relay-peer rotate-leaf <region>} f n
    load
    [ "$MESH_IS_HUB" = 1 ] || die "relay-peer rotate-leaf: this server is not of the hub region ($MESH_HUB_DC): run it there"
    [ "$dc" != "$MESH_DC" ] && [[ " $MESH_OTHER_DCS " == *" $dc "* ]] || die "relay-peer rotate-leaf: $dc is no other region of the mesh (${MESH_OTHER_DCS:-none})"
    f=$MESH_CSEC/nats-leaf-$dc-password
    rm -f "$(target "$f")"
    # apply makes the password again (mesh_nats_conf) and restarts NATS for it.
    apply
    say "mesh: a new password of the leaf link of $dc; the old one is refused from now on"
    {
        echo "The servers of $dc reach this region again once they have it; here, for each of them:"
        while read -r n _; do
            echo "   veydan-server relay-peer add --replace '<the line of $n>'   (its line: veydan-server relay-peer on $n)"
        done < <(mesh_region_servers "$dc")
        echo "and on each, the key that prints: veydan-server relay-join --key-file <the file>"
    } >&2
}

# ---- relay-join -------------------------------------------------------------------

step() { STEP=$1; say "relay-join: step $1 of 8, $2"; }
fail() { die "relay-join: step $STEP: $*. Then veydan-server relay-join again: the steps done are checked and skipped"; }

nodetool() { vrelay_compose exec -T cassandra nodetool "$@"; }

# What nodetool status says of this node, "UN" when it is up and normal.
node_state() { nodetool status 2>/dev/null | awk -v ip="$MESH_IP" '$2 == ip {print $1}'; }

# A file that holds a key: a plain file of this user (root), nobody else's
# to read; a link or a looser mode is refused.
key_file_ok() { # key_file_ok <file>
    local f=$1 s
    [ -f "$f" ] && [ ! -L "$f" ] || die "relay-join: $f is not a plain file (a link is not read)"
    s=$(stat -c '%u %a' -- "$f")
    [ "${s%% *}" = "$(id -u)" ] || die "relay-join: $f is not $(id -un)'s"
    [ $((8#${s#* } & 8#077)) = 0 ] || die "relay-join: $f is open to others (mode ${s#* }): chmod 600 $f"
}

# The keys: of the files of --key-file, else of the input (a pipe or a file),
# one a line, or pasted on a terminal (not shown). Never an argument: every
# user of the machine reads the command lines.
KEYS=()
read_keys() { # read_keys <state> [--key-file <file>]...
    local state=$1 f l; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --key-file)
                f=${2:-}; [ -n "$f" ] || die "relay-join: --key-file <file>"
                key_file_ok "$f"
                while IFS= read -r l || [ -n "$l" ]; do KEYS+=("$l"); done < "$f"
                shift 2 ;;
            veydan-relay-join-*) die "relay-join: the key is never an argument (every user of this machine reads the command lines): veydan-server relay-join --key-file <file>, or veydan-server relay-join < <file>" ;;
            *) die "veydan-server relay-join [--key-file <file>]...   (or the keys on the input, one a line)" ;;
        esac
    done
    [ "${#KEYS[@]}" = 0 ] || return 0
    if [ -t 0 ]; then
        [ "$state" = pending ] || return 0
        echo "Paste the key of each peer (veydan-server relay-peer add there), one a line; an empty line ends:" >&2
        while IFS= read -rs l && [ -n "$l" ]; do KEYS+=("$l"); done
    else
        while IFS= read -r l || [ -n "$l" ]; do KEYS+=("$l"); done
    fi
    return 0
}

take_keys() {
    local k body mac line n v cs=$MESH_CSEC from="" got_store="" now age hours=${RELAY_JOIN_KEY_HOURS:-24}
    [[ "$hours" =~ ^[0-9]{1,4}$ ]] && [ "$hours" -ge 1 ] || fail "RELAY_JOIN_KEY_HOURS=$hours: hours, 1 or more"
    now=${VEYDAN_NOW:-$(date +%s)}
    declare -A K
    for k in "$@"; do
        k=${k//[[:space:]]/}
        [ -n "$k" ] || continue
        case "$k" in
            veydan-relay-join-1.*) fail "a key of the first form (veydan-relay-join-1), which carried the superuser of the store and no time: on that peer, veydan-server relay-peer add --replace '$(mesh_line)' makes a new one" ;;
        esac
        [[ "$k" =~ ^veydan-relay-join-2\.([A-Za-z0-9+/=]+)\.([0-9a-f]{64})$ ]] || fail "\"${k:0:24}…\" is not a key of relay-peer add (veydan-relay-join-2.…), or it is cut short"
        body=${BASH_REMATCH[1]} mac=${BASH_REMATCH[2]}
        [ "$(mesh_join_mac "$body")" = "$mac" ] \
            || fail "a key does not carry the mark of this network (MESH_PEER_KEY): changed, cut short, or of another network"
        body=$(printf '%s' "$body" | base64 -d 2>/dev/null) || fail "a key does not read (cut short?)"
        K=()
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            [[ "$line" =~ ^([A-Z_]+)=([A-Za-z0-9+/=._-]*)$ ]] || fail "a key holds a line that is not NAME=value"
            K[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        done <<< "$body"
        [ "${K[V]:-}" = 2 ] || fail "a key of another form (V=${K[V]:-none})"
        [ "${K[FOR]:-}" = "$SERVER" ] || fail "a key is for ${K[FOR]:-nobody}, not for $SERVER"
        from=${K[FROM]:-}
        mesh_peer_index "$from" >/dev/null || fail "a key comes from $from, which is not in RELAY_MESH_WG_PEERS here"
        [[ "${K[ISSUED]:-}" =~ ^[0-9]{9,12}$ ]] || fail "the key of $from has no time"
        age=$((now - K[ISSUED]))
        [ "$age" -ge -300 ] || fail "the key of $from was made $(( -age / 60 )) minutes ahead of this clock: the clocks of the two servers (chrony)"
        [ "$age" -le $((hours * 3600)) ] \
            || fail "the key of $from was made $((age / 3600)) hours ago, more than RELAY_JOIN_KEY_HOURS ($hours): on $from, veydan-server relay-peer add --replace '$(mesh_line)' makes a new one"
        [ -n "${K[PSK]:-}" ] && [ -n "${K[CASSANDRA_VRELAY]:-}" ] && [ -n "${K[CASSANDRA_MIGRATE]:-}" ] || fail "the key of $from lacks a part"
        printf '%s\n' "${K[PSK]}" | put "$(mesh_psk "$from")" 0600 root:root
        if [ -n "$got_store" ] && [ "$got_store" != "${K[CASSANDRA_VRELAY]}" ]; then
            fail "the keys of two peers hold two passwords of the store: they are of two meshes"
        fi
        got_store=${K[CASSANDRA_VRELAY]}
        printf '%s\n' "${K[CASSANDRA_VRELAY]}" | put "$cs/cassandra-vrelay-password" 0600 vrelay-db:vrelay-db
        printf '%s\n' "${K[CASSANDRA_MIGRATE]}" | put "$cs/cassandra-migrate-password" 0600 vrelay-db:vrelay-db
        put "$MESH_SEC/cassandra-password" 0600 vrelay:vrelay < "$(target "$cs/cassandra-vrelay-password")"
        [ -z "${K[LEAF]:-}" ] || printf '%s\n' "${K[LEAF]}" | put "$cs/nats-leaf-$MESH_DC-password" 0600 vrelay-bus:vrelay-bus
        if [ "${K[FROM_DC]:-}" = "$MESH_DC" ]; then
            for n in serve write migrate sys route; do
                v=${K[NATS_${n^^}]:-}
                [ -n "$v" ] || continue
                printf '%s\n' "$v" | put "$cs/nats-$n-password" 0600 vrelay-bus:vrelay-bus
            done
            put "$MESH_SEC/nats-serve-password" 0600 vrelay:vrelay < "$(target "$cs/nats-serve-password")"
            put "$MESH_SEC/nats-write-password" 0600 vrelay:vrelay < "$(target "$cs/nats-write-password")"
            # On the hub region: the leaf users of the other regions.
            for n in "${!K[@]}"; do
                [[ "$n" =~ ^LEAF_([A-Z][A-Z0-9]*)$ ]] || continue
                printf '%s\n' "${K[$n]}" | put "$cs/nats-leaf-${BASH_REMATCH[1],,}-password" 0600 vrelay-bus:vrelay-bus
            done
        fi
        printf '%s %s\n' "$from" "$(date -u +%FT%TZ)" >> "$(target "$R/etc/mesh-keys-from")"
        say "relay-join: the key of $from taken"
    done
}

cmd_join() {
    load
    local state i missing="" src_dc="" src_ip="" ks repl dc ip n ok seeds_other="" same=0
    state=$(mesh_state)
    read_keys "$state" "$@"
    if [ "$state" = joined ]; then
        if [ "${#KEYS[@]}" = 0 ]; then say "relay-join: this server has joined the mesh ($(cat "$(target "$MESH_JOINED")")); nothing to do"; return 0; fi
        # New keys of peers that have joined already (relay-peer add
        # --replace, rotate-leaf there): the pair keys and the passwords
        # taken, WireGuard, the firewall and NATS anew.
        STEP=1
        take_keys "${KEYS[@]}"
        apply
        say "relay-join: the new keys taken; WireGuard and NATS have them"
        return 0
    fi
    [ "$state" = pending ] || die "relay-join: this server is the first of the mesh (RELAY_MESH_WG_PEERS is empty): it joins nobody; the others join it"
    [ -f "$(target "$RC/mesh.yaml")" ] && [ -f "$(target "$RC/.env")" ] \
        || die "relay-join: run the kit here once first (veydan-server rerun): it prepares this server and stops before Cassandra"
    for i in "${!PEER_DC[@]}"; do [ "${PEER_DC[$i]}" = "$MESH_DC" ] && same=1; done
    # The region the data streams from: the hub's, else the first other.
    if [ "$MESH_HUB_DC" != "$MESH_DC" ]; then src_dc=$MESH_HUB_DC; else src_dc=$(printf '%s\n' $MESH_OTHER_DCS | head -n1); fi
    [ -z "$src_dc" ] || src_ip=$(mesh_region_servers "$src_dc" | awk 'NR == 1 {print $2}')

    step 1 "the keys of the peers"
    [ "${#KEYS[@]}" = 0 ] || take_keys "${KEYS[@]}"
    for i in "${!PEER_NAME[@]}"; do [ -s "$(target "$(mesh_psk "${PEER_NAME[$i]}")")" ] || missing+="${PEER_NAME[$i]} "; done
    [ -z "$missing" ] || fail "no key yet from ${missing% }: on each, veydan-server relay-peer add '$(mesh_line)', and its key here (veydan-server relay-join --key-file <file>)"
    [ -s "$(target "$R/etc/mesh-keys-from")" ] || fail "the passwords of the store come with the key of a peer: veydan-server relay-join --key-file <file>"
    if [ "$MESH_IS_HUB" != 1 ]; then
        [ -s "$(target "$MESH_CSEC/nats-leaf-$MESH_DC-password")" ] || fail "no password of the leaf link of $MESH_DC: the key of a server of the hub region $MESH_HUB_DC brings it"
    fi
    if [ "$same" = 1 ]; then
        [ -n "$(grep -E "^($(mesh_region_servers "$MESH_DC" | awk -v s="$SERVER" '$1 != s {print $1}' | paste -sd'|' -)) " "$(target "$R/etc/mesh-keys-from")" || true)" ] \
            || fail "the users of NATS of the region $MESH_DC come with the key of a server of that region"
    fi

    step 2 "WireGuard to every peer"
    mesh_wg_key
    mesh_wg_render
    mesh_wg_apply
    mesh_firewall
    if [ "$DRY" != 1 ]; then
        for _ in $(seq 1 30); do
            ok=1
            for i in "${!PEER_NAME[@]}"; do
                n=$(wg show "$MESH_IF" latest-handshakes 2>/dev/null | awk -v k="${PEER_KEY[$i]}" '$1 == k {print $2}' || true)
                [ -n "$n" ] && [ "$n" != 0 ] && [ $(( $(date +%s) - n )) -le 180 ] || { ok=0; missing=${PEER_NAME[$i]}; }
            done
            [ "$ok" = 1 ] && break
            sleep 2
        done
        [ "$ok" = 1 ] || fail "no handshake with $missing in 60 s: is this server in RELAY_MESH_WG_PEERS there (veydan-server relay-peer there), with the public key $MESH_PUBKEY, and udp/$MESH_PORT open there to this server's public address?"
    fi

    step 3 "NATS of the region$([ "$MESH_IS_HUB" = 1 ] || echo ", the leaf link to $MESH_HUB_DC")"
    mesh_nats_conf "$TPL/mesh/nats.conf" vrelay-bus:vrelay-bus
    # Running already (a second try): it takes its config anew.
    if [ "$DRY" != 1 ] && [ -n "$(vrelay_compose ps -q --status running nats 2>/dev/null)" ]; then
        vrelay_compose restart nats >/dev/null || fail "NATS did not restart"
    fi
    vrelay_compose up -d --wait --wait-timeout 120 nats || fail "NATS did not come up: docker compose -f $RC/mesh.yaml logs nats (in $RC)"
    if [ "$DRY" != 1 ] && [ "$MESH_IS_HUB" != 1 ]; then
        ok=0
        for _ in $(seq 1 15); do
            n=$(curl -fsS http://127.0.0.1:8222/leafz 2>/dev/null | jq -r '.leafnodes // (.leafs | length) // 0' 2>/dev/null || echo 0)
            [ "${n:-0}" -ge 1 ] && { ok=1; break; }
            sleep 2
        done
        [ "$ok" = 1 ] || fail "the leaf link to $MESH_HUB_DC is not up in 30 s (docker compose -f $RC/mesh.yaml logs nats): on the hub, veydan-server relay-peer add of this server's line makes its user; tcp/7422 on $MESH_IF there"
    fi

    step 4 "the seeds of Cassandra reached over the mesh"
    for ip in ${MESH_SEEDS//,/ }; do
        [ "$ip" = "$MESH_IP" ] && continue
        seeds_other+="$ip,"
        if [ "$DRY" != 1 ]; then
            timeout 5 bash -c "exec 3<>/dev/tcp/$ip/7000" 2>/dev/null || fail "$ip:7000 (Cassandra between nodes) is not reached: is Cassandra up there, and tcp/7000 open on $MESH_IF for $MESH_IP (relay-peer add there)?"
        fi
    done
    seeds_other=${seeds_other%,}
    [ -n "$seeds_other" ] || fail "no seed of another server in $MESH_SEEDS (RELAY_STORE_SEEDS)"
    if [ -n "$src_ip" ] && [ "$DRY" != 1 ]; then
        timeout 5 bash -c "exec 3<>/dev/tcp/$src_ip/9042" 2>/dev/null || fail "$src_ip:9042 (CQL of $src_dc) is not reached over the mesh"
    fi

    step 5 "Cassandra joins the cluster$([ "$same" = 1 ] && echo " in its region $MESH_DC (it streams its ranges)" || echo " as the new datacenter $MESH_DC (auto_bootstrap false)")"
    if [ "$DRY" = 1 ] || [ "$(node_state)" != UN ]; then
        # The first start knows the seeds of the others alone: a node that
        # reached none would make a cluster of its own; this way it stops.
        if [ "$same" = 1 ]; then
            CASSANDRA_SEEDS=$seeds_other vrelay_compose up -d --wait --wait-timeout 21600 cassandra \
                || fail "Cassandra did not join (docker compose -f $RC/mesh.yaml logs cassandra); before another try: docker compose ... down cassandra, empty $R/data/cassandra"
        else
            CASSANDRA_SEEDS=$seeds_other CASSANDRA_AUTO_BOOTSTRAP=false vrelay_compose up -d --wait --wait-timeout 900 cassandra \
                || fail "Cassandra did not join (docker compose -f $RC/mesh.yaml logs cassandra); before another try: docker compose ... down cassandra, empty $R/data/cassandra"
        fi
    fi
    if [ "$DRY" != 1 ]; then
        repl=$(nodetool status 2>/dev/null || true)
        [ "$(node_state)" = UN ] || fail "this node is not UN in nodetool status: $(printf '%s' "$repl" | grep -F "$MESH_IP" || echo 'not listed')"
        for dc in $MESH_REGIONS; do
            grep -qx "Datacenter: $dc" <<< "$repl" || fail "nodetool status shows no datacenter $dc: this node is not in the cluster of the others (it came up alone?). Stop it (docker compose -f $RC/mesh.yaml rm -sf cassandra), empty $R/data/cassandra and its logs, check WireGuard and the seeds"
        done
        say "relay-join: $(printf '%s\n' "$repl" | grep -c '^UN') nodes up, datacenters: $(grep '^Datacenter:' <<< "$repl" | awk '{print $2}' | tr '\n' ' ')"
    fi

    if [ "$same" = 0 ]; then
        # This server has no superuser of the store: a server of the mesh
        # that has it (the first) adds the copies (relay-admit), and this
        # step checks them as vrelay's role.
        step 6 "the keyspaces have a copy in $MESH_DC (veydan-server relay-admit $SERVER on a server with the superuser of the store, $src_dc)"
        missing=""
        for ks in vrelay system_auth system_distributed system_traces; do
            if [ "$DRY" = 1 ]; then run "the copy of $ks in '$MESH_DC' (as vrelay, on $src_ip)"; continue; fi
            repl=$(printf "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" | vrelay_compose run --rm -T -e CQL_AS=vrelay cql "$src_ip" 2>&1) \
                || fail "the keyspaces of $src_ip could not be read: $(tail -n1 <<< "$repl")"
            grep -q NetworkTopologyStrategy <<< "$repl" || fail "the keyspace $ks on $src_ip is not on NetworkTopologyStrategy$([ "$ks" = vrelay ] && echo ", or not there yet: veydan-server rerun on a server of $src_dc first")"
            grep -q "'$MESH_DC': '" <<< "$repl" || missing+="$ks "
        done
        [ -z "$missing" ] || fail "the keyspaces ${missing% } have no copy in $MESH_DC yet: on the first server of the mesh (it has the superuser of the store), veydan-server relay-admit $SERVER"
        say "relay-join: every keyspace has a copy in $MESH_DC"

        step 7 "the data streams from $src_dc (nodetool rebuild)"
        if [ -f "$(target "$R/etc/mesh-rebuilt")" ]; then
            say "relay-join: rebuilt already ($(cat "$(target "$R/etc/mesh-rebuilt")"))"
        else
            if [ "$DRY" = 1 ]; then nodetool rebuild -- "$src_dc"
            else nodetool rebuild -- "$src_dc" || fail "nodetool rebuild -- $src_dc failed (above; nodetool netstats shows the streams)"; fi
            if [ "$DRY" != 1 ]; then
                # The roles are read in this datacenter (LOCAL_QUORUM): a login
                # here works only once system_auth has streamed in; and the
                # tables of vrelay are here, read at LOCAL_ONE.
                repl=$(printf 'CONSISTENCY LOCAL_ONE;\nSELECT table_name FROM system_schema.tables WHERE keyspace_name = '"'"'vrelay'"'"';\n' \
                    | vrelay_compose run --rm -T -e CQL_AS=vrelay cql "$MESH_IP" 2>&1) \
                    || fail "after the rebuild vrelay's role cannot log in on this node (system_auth not streamed in?): $(tail -n1 <<< "$repl")"
                grep -qw event <<< "$repl" || fail "after the rebuild this node has no table vrelay.event: $(tail -n2 <<< "$repl")"
                n=$(nodetool status vrelay 2>/dev/null | awk -v ip="$MESH_IP" '$2 == ip {print $3, $4}' || true)
                say "relay-join: this node has the roles and the tables of vrelay; its load ${n:-?}"
            fi
            printf 'rebuilt from %s %s\n' "$src_dc" "$(date -u +%FT%TZ)" | put "$R/etc/mesh-rebuilt" 0644 root:root
        fi
    else
        step 6 "the keyspaces: the region $MESH_DC has them already"
        step 7 "the ranges streamed in at the start (bootstrap); on the other nodes of $MESH_DC, the ranges they gave away"
        echo "   On every other server of $MESH_DC: veydan-server relay-nodetool cleanup vrelay (one after another)." >&2
        n=$(mesh_region_servers "$MESH_DC" | grep -c .)
        [ "$n" -lt 3 ] || echo "   $MESH_DC has $n servers: three copies there (README, \"A region of three\": ALTER KEYSPACE, repair, then the NATS of the region)." >&2
    fi

    step 8 "the kit again: the roles, the tables and streams of $MESH_DC, vrelay, nginx"
    printf 'joined %s: region %s, from %s\n' "$(date -u +%FT%TZ)" "$MESH_DC" "${src_dc:-$MESH_DC}" | put "$MESH_JOINED" 0644 root:root
    run rm -f "$(target "$R/etc/mesh-pending.txt")"
    say "relay-join: this server is a node of the mesh. Then on every other server: veydan-server rerun (vrelay takes the region $MESH_DC)"
    if [ "$DRY" = 1 ]; then run bash "$HERE/run.sh" --yes; return 0; fi
    exec bash "$HERE/run.sh" --yes
}

# ---- relay-admit -------------------------------------------------------------------

# On a server that has the superuser of the store (the first of the mesh):
# a server of a new region has joined the cluster (relay-join, step 5), and
# the keyspaces get a copy in its region, so that it can stream the data in
# (step 7). Run once its node is up; relay-join then goes on.
cmd_admit() {
    local name=${1:?veydan-server relay-admit <name of the server that joins>} i dc ip st ks repl pairs
    load
    [ "$(mesh_state)" != pending ] || die "relay-admit: this server has not joined the mesh itself"
    [ -s "$(target "$MESH_CSEC/cassandra-admin-password")" ] || die "relay-admit: this server has no superuser of the store; run it on the first server of the mesh"
    i=$(mesh_peer_index "$name") || die "relay-admit: no peer $name here (veydan-server relay-peer add first)"
    dc=${PEER_DC[$i]} ip=${PEER_IP[$i]}
    [ "$dc" != "$MESH_DC" ] || { say "relay-admit: $name is of this region $dc: its keyspaces are here already, nothing to do"; return 0; }
    if [ "$DRY" != 1 ]; then
        st=$(nodetool status 2>/dev/null | awk -v ip="$ip" '$2 == ip {print $1}')
        [ "$st" = UN ] || die "relay-admit: the node of $name ($ip) is not up in the cluster (nodetool status: ${st:-not listed}): veydan-server relay-join there first, up to its step 6"
    fi
    for ks in vrelay system_auth system_distributed system_traces; do
        if [ "$DRY" = 1 ]; then run "ALTER KEYSPACE $ks: + '$dc': 1 (here, $MESH_IP)"; continue; fi
        repl=$(printf "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" | vrelay_compose run --rm -T cql "$MESH_IP" 2>&1) \
            || die "relay-admit: the keyspaces could not be read: $(tail -n1 <<< "$repl")"
        grep -q NetworkTopologyStrategy <<< "$repl" || die "relay-admit: the keyspace $ks is not on NetworkTopologyStrategy$([ "$ks" = vrelay ] && echo ", or not there yet: veydan-server rerun here first")"
        grep -q "'$dc': '" <<< "$repl" && { say "relay-admit: $ks has a copy in $dc already"; continue; }
        pairs=$(grep -oE "'[a-z][a-z0-9]*': '[0-9]+'" <<< "$repl" | sed -E "s/: '([0-9]+)'/: \1/" | paste -sd, - | sed 's/,/, /g')
        printf "ALTER KEYSPACE %s WITH replication = {'class': 'NetworkTopologyStrategy', %s, '%s': 1};\n" "$ks" "$pairs" "$dc" \
            | vrelay_compose run --rm -T cql "$MESH_IP" >/dev/null || die "relay-admit: ALTER KEYSPACE $ks failed (above)"
        repl=$(printf "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = '%s';\n" "$ks" | vrelay_compose run --rm -T cql "$MESH_IP" 2>&1 || true)
        grep -q "'$dc': '1'" <<< "$repl" || die "relay-admit: $ks has no copy in $dc after the ALTER: $(grep -o '{.*}' <<< "$repl")"
        say "relay-admit: $ks: $(grep -o '{.*}' <<< "$repl")"
    done
    say "relay-admit: the keyspaces have a copy in $dc; on $name: veydan-server relay-join (it goes on from step 6)"
}

case "${1:-}" in
    peer)
        case "${2:-}" in
            ""|show) cmd_peer_show ;;
            add) shift 2; cmd_peer_add "$@" ;;
            remove) shift 2; cmd_peer_remove "$@" ;;
            rotate-leaf) shift 2; cmd_peer_rotate_leaf "$@" ;;
            apply) load; [ "$(mesh_state)" != pending ] || die "relay-peer apply: this server has not joined the mesh yet (veydan-server relay-join)"; apply ;;
            *) die "veydan-server relay-peer [show] | add [--replace] [--hub] [--stdout] '<line>' | remove <name> | rotate-leaf <region> | apply" ;;
        esac
        ;;
    join) shift; cmd_join "$@" ;;
    admit) shift; cmd_admit "$@" ;;
    nodetool)
        shift
        load
        [ -f "$(target "$RC/mesh.yaml")" ] || die "no $RC/mesh.yaml: run the kit once"
        vrelay_compose exec -T cassandra nodetool "$@"
        ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# vrelay, the relay engine RELAY_ENGINE=vrelay (services/relay): vrelay serve
# (the clients) and vrelay write (the queue to the store) as units of this
# machine, Cassandra and NATS beside them in docker, nginx in front on 443.
# Everything in /opt/vrelay:
#   bin/vrelay  bin/vrelay-docker-lock.sh  bin/vrelay-local-lock.sh
#   bin/store-health.sh (the health of Cassandra for the agent)
#   etc/vrelay.env  etc/vrelay-write.env  etc/*.service  etc/*.timer
#   etc/secrets/ (vrelay's: the keys of the network, its passwords, the
#     secret of the invites and the key of the statistics, 0600 vrelay)
#   access/ (team, channel: members.txt, invites.json, 0660 vrelay; the
#     folder root's, 0770 root:vrelay, and root never works there by a path)
#   stats/token (the token of the statistics, 0640 root:vrelay-stats: vrelay
#     and the agent read it)
#   policy/ (denied-keys.txt, denied-groups.txt, laid by the agent of vcloud)
#   compose/  compose.yaml and compose/ (the relay's, as they are),
#     compose.kit.yaml and kit/ (the kit's layer), .env (from server.conf),
#     secrets/ (the passwords of the containers, each 0600 its user's)
#   data/cassandra  data/cassandra-logs  data/nats   (the store and the bus)
# vrelay listens on 127.0.0.1:7781 (WebSockets, NIP-11, the access API),
# 127.0.0.1:7782 (the access API alone, asked by nginx for the media of a
# team or channel server) and 127.0.0.1:7783 (its statistics for the agent;
# vrelay write's on 127.0.0.1:7784); Cassandra on 127.0.0.1:9042, NATS on
# 127.0.0.1:4222 and its page on 127.0.0.1:8222; nothing of them elsewhere,
# and on this machine each port for its own users alone (vrelay-local-lock.sh).
# vrelay has the command line of the access files itself (vrelay access):
# a fresh server of this engine has nothing of vguard and nothing of strfry.
# A server switched from strfry keeps both, stopped, for the way back
# (components/relay-engine.sh); its access files are copied here once, and
# its denied lists are read where the agent lays them, /opt/vguard/data,
# until veydan-server relay-cleanup. Part of the relay; sourced by run.sh in
# place of strfry.sh and guard.sh.
#
# A server of the mesh (RELAY_MESH_WG of server.conf, lib/mesh.sh): the same,
# but Cassandra and NATS on the host's network, bound to its address on wg0
# (compose/mesh.yaml in place of the two files above), WireGuard to the other
# servers, chrony, the firewall of the mesh, NATS with a user a mode and the
# leaf link, and the weekly repair. The first server comes up by itself; the
# next ones stop before Cassandra until veydan-server relay-join.

R=/opt/vrelay
RC=$VRELAY_COMPOSE
SEC=$R/etc/secrets
CSEC=$RC/secrets
ACC=$R/access
POL=$R/policy
OLD_G=/opt/vguard
say "vrelay: the relay engine vrelay"
if [ "$MESH" = 1 ]; then
    # A store made for one server is not taken into a cluster in place.
    if [ ! -f "$(target "$RC/mesh.yaml")" ] && [ -n "$(ls -A "$(target "$R/data/cassandra")" 2>/dev/null)" ]; then
        die "vrelay: the store of this server was made for one server alone; it does not become a node of the mesh in place. Export it (vrelay export, README \"The vrelay engine\"), move $R/data away, run again, then vrelay import; or RELAY_MESH_WG=off"
    fi
    MESH_STATE=$(mesh_state)
    say "vrelay: a server of the mesh, region $MESH_DC$([ "$MESH_IS_HUB" = 1 ] && echo " (the hub of the leaf links)"), $MESH_IF $MESH_IP/$MESH_PREFIX, peers: ${PEER_NAME[*]:-none} ($MESH_STATE)"
elif [ -f "$(target "$RC/mesh.yaml")" ]; then
    die "vrelay: this server is a node of the mesh ($RC/mesh.yaml): RELAY_MESH_WG=off would leave its cluster without a word. Remove it from the mesh first (README, \"Two regions\"), or set RELAY_MESH_WG back"
fi

# --- memory ---------------------------------------------------------------------
#
# What each program may take, from the memory of the machine and the
# components of this server (vrelay_memory, lib/common.sh; the table of
# README, "The vrelay engine"): Cassandra's and NATS's containers, the units
# of vrelay write and serve, and an estimate of nginx, the system and the
# other components, which have no limit. Below 8 GB (as a provider counts
# it: 7 000 MB of MemTotal) the engine is refused.
VRELAY_MIN_MB=${VRELAY_MIN_MB:-7000}   # a test server may lower it in its environment; a server of users never
# VRELAY_MEM_MB: the memory the split is counted from, in place of MemTotal
# (the tests of the kit; a machine that holds something else besides).
mem_mb=${VRELAY_MEM_MB:-$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)}
[[ "$mem_mb" =~ ^[0-9]{3,7}$ ]] || die "VRELAY_MEM_MB: megabytes, not \"$mem_mb\""
if [ "$mem_mb" -lt "$VRELAY_MIN_MB" ]; then
    m="vrelay needs a machine of 8 GB of memory or more ($VRELAY_MIN_MB MB of MemTotal; this one has $mem_mb MB): Cassandra, NATS and the relay do not fit beside the rest. Keep RELAY_ENGINE=strfry here"
    if [ "$DRY" = 1 ]; then warn "$m"; else die "$m"; fi
fi
if [ -n "$RELAY_CASSANDRA_HEAP_MB" ]; then
    [ "$((10#$RELAY_CASSANDRA_HEAP_MB))" -ge 512 ] || die "RELAY_CASSANDRA_HEAP_MB: 512 or more"
    vrelay_memory "$mem_mb" "$((10#$RELAY_CASSANDRA_HEAP_MB))" "$COMPONENTS"
else
    vrelay_memory "$mem_mb" "" "$COMPONENTS"
fi
heap_mb=$MEM_HEAP direct_mb=$MEM_DIRECT cassandra_limit_mb=$MEM_CASSANDRA nats_limit_mb=$MEM_NATS
# The store, the bus and the writer must leave serve its least and the
# system its own.
if [ $((mem_mb - MEM_CASSANDRA - MEM_NATS - MEM_WRITE)) -lt 1536 ]; then
    m="vrelay: a heap of $heap_mb MB for Cassandra (container $cassandra_limit_mb MB), NATS ($nats_limit_mb MB) and vrelay write ($MEM_WRITE MB) leave less than 1.5 GB of the $mem_mb MB of this machine to vrelay serve and the system: a smaller RELAY_CASSANDRA_HEAP_MB, or a larger machine"
    if [ "$DRY" = 1 ]; then warn "$m"; else die "$m"; fi
fi
if [ "$MEM_SHORT" -gt 0 ]; then
    warn "vrelay: this machine has $mem_mb MB; Cassandra, NATS and vrelay leave the system, nginx and the other components of this server ($COMPONENTS) about $MEM_SHORT MB less than their estimate: a machine of 16 GB, or fewer components here"
fi
# The connections at once (RELAY_MAX_CONNECTIONS): empty, what serve's
# limit holds; a number of server.conf is taken as it is, and told when
# serve's memory holds fewer.
max_conn=${RELAY_MAX_CONNECTIONS:-$MEM_CONNECTIONS}
if [ -n "$RELAY_MAX_CONNECTIONS" ] && [ $((RELAY_MAX_CONNECTIONS * VRELAY_SERVE_KB_PER_CONN / 1024)) -gt "$MEM_SERVE" ]; then
    warn "vrelay: RELAY_MAX_CONNECTIONS=$RELAY_MAX_CONNECTIONS of server.conf: vrelay serve's limit of $MEM_SERVE MB holds about $MEM_CONNECTIONS (${VRELAY_SERVE_KB_PER_CONN} KB a connection); past them the kernel stops it. Empty, the kit counts the number from the memory"
fi
say "vrelay: of $mem_mb MB: Cassandra $cassandra_limit_mb MB (heap $heap_mb, direct $direct_mb), NATS $nats_limit_mb MB, vrelay write $MEM_WRITE MB, vrelay serve $MEM_SERVE MB ($max_conn connections at once)"

# --- docker, of Debian ----------------------------------------------------------
#
# docker.io (the engine) with docker-cli and docker-compose (compose v2, the
# plugin of the cli: `docker compose`), all from Debian 13's own archive; no
# repository is added. iptables: the second lock (vrelay-docker-lock.sh).
apt_install docker.io docker-cli docker-compose iptables nftables
# The mesh: WireGuard between the servers, chrony for the clocks (the
# deletions across regions are decided by them, spec/cluster.md 1.6).
[ "$MESH" = 1 ] && apt_install wireguard-tools
[ "$MESH" = 1 ] && mesh_chrony
# The kernel of the host of Cassandra and NATS (services/relay/spec/tuning.md 4):
# the sysctls now and at every boot, and what sysctl cannot set by a unit.
put /etc/sysctl.d/90-vrelay.conf 0644 root:root < "$HERE/templates/sysctl/90-vrelay.conf"
run sysctl -q -p /etc/sysctl.d/90-vrelay.conf
# The daemon publishes a port given without an address on 127.0.0.1, gives
# no container new privileges, and rotates the logs. A daemon.json of the
# admin's stays (a different one of the kit goes beside it as .new).
daemon_before=""
[ -f "$(target /etc/docker/daemon.json)" ] && daemon_before=$(cat "$(target /etc/docker/daemon.json)")
render "$HERE/templates/docker-daemon.json" /etc/docker/daemon.json 0644 root:root keep
run systemctl enable --now docker
if [ "$DRY" != 1 ] && [ "$daemon_before" != "$(cat /etc/docker/daemon.json)" ]; then
    run systemctl restart docker
fi
if [ "$DRY" != 1 ]; then
    docker compose version >/dev/null 2>&1 || die "vrelay: docker compose does not run (docker-compose of Debian installed?): docker compose version"
fi

# --- users ----------------------------------------------------------------------
#
# vrelay runs serve and write; vrelay-db is Cassandra in its container (and
# the job that sets its roles), vrelay-bus is NATS. None of them logs in.
ensure_user vrelay "$R"
ensure_user vrelay-db "$R/data/cassandra"
ensure_user vrelay-bus "$R/data/nats"
uid_of() { # uid_of <user> [-g]
    local n
    n=$(id "${2:--u}" "$1" 2>/dev/null) && { printf '%s' "$n"; return 0; }
    [ "$DRY" = 1 ] || die "vrelay: no user $1"
    printf '%s' 64999
}

# A server switched from strfry: vguard's folder is here, kept for the way
# back. The agent of vcloud lays the denied lists there while it is (the
# overlay's agent component names /opt/vguard/data where it exists), so
# vrelay reads them there, by the group vguard. A fresh server has none
# of it: the lists are vrelay's, in policy/. RELAY_CLEANUP=1:
# veydan-server relay-cleanup is about to remove vguard (relay-cleanup.sh),
# so vrelay leaves it now.
OLD_GUARD=0
if [ -d "$(target "$OLD_G/data")" ] && [ "${RELAY_CLEANUP:-0}" != 1 ]; then OLD_GUARD=1; fi
if [ "$OLD_GUARD" = 1 ] && ! id -nG vrelay 2>/dev/null | tr ' ' '\n' | grep -qx vguard; then
    run usermod -a -G vguard vrelay
fi
DENIED=$POL
[ "$OLD_GUARD" = 1 ] && DENIED=$OLD_G/data

# --- the binary -----------------------------------------------------------------
#
# From the kit (bin/vrelay of make build-deploy, checked by bin/vrelay.sha256);
# else what is installed stays (a build of one's own, or the release named);
# else the release of VRELAY_VERSION, signed as vrelay.
mkdirp "$R" 0755 root:root
mkdirp "$R/bin" 0755 root:root
if [ -f "$HERE/bin/vrelay" ]; then
    ( cd "$HERE/bin" && sha256sum -c --quiet vrelay.sha256 ) \
        || die "bin/vrelay does not match bin/vrelay.sha256: a damaged kit"
    # install, not cp: cp over a running binary fails with "text file busy".
    run install -m 0755 "$HERE/bin/vrelay" "$R/bin/vrelay"
    say "vrelay: $(cat "$HERE/bin/vrelay.RELEASE" 2>/dev/null || echo '?') from the kit"
elif needs_release "$R/bin/vrelay" "${VRELAY_VERSION:-}"; then
    [ -n "${VRELAY_VERSION:-}" ] || die "vrelay: no bin/vrelay in the kit, none in $R/bin, and VRELAY_VERSION of versions.conf names no release of Veydan-Relay yet: build it (make build-deploy, or make -C services/relay build-deploy DEPLOY_BIN=<kit>/bin), or keep RELAY_ENGINE=strfry"
    fetch_program vrelay Veydan-Relay "$VRELAY_VERSION" "$R/bin/vrelay"
fi
V_VRELAY=$R/bin/vrelay
put "$R/bin/vrelay-docker-lock.sh" 0755 root:root < "$HERE/templates/vrelay-docker-lock.sh"
put "$R/bin/vrelay-local-lock.sh" 0755 root:root < "$HERE/templates/vrelay-local-lock.sh"

# --- folders and secrets --------------------------------------------------------

mkdirp "$R/etc" 0750 root:vrelay
mkdirp "$SEC" 0750 root:vrelay
mkdirp "$RC" 0755 root:root
mkdirp "$RC/compose" 0755 root:root
mkdirp "$RC/kit" 0755 root:root
# Each container reads its own files here and no other's.
mkdirp "$CSEC" 0711 root:root
mkdirp "$R/data" 0755 root:root
mkdirp "$R/data/cassandra" 0700 vrelay-db:vrelay-db
mkdirp "$R/data/cassandra-logs" 0700 vrelay-db:vrelay-db
mkdirp "$R/data/nats" 0700 vrelay-bus:vrelay-bus
# The denied keys and the closed groups (spec/vguard.md "Denied keys",
# "Denied groups"; services/cloud/spec/cloud-api.md 14), laid by the agent
# of vcloud through its root helper, read by vrelay by its group. No file,
# nobody denied. A server switched from strfry: they are copied here once
# (the agent keeps laying them in /opt/vguard/data, read until
# veydan-server relay-cleanup, which copies them here again).
mkdirp "$POL" 0750 root:vrelay
# vguard's folder is its user's to write: what is there is read as vguard
# (a link planted there reaches nothing vguard could not read itself).
if [ -d "$(target "$OLD_G/data")" ]; then
    for f in denied-keys.txt denied-groups.txt; do
        if plain_file "$OLD_G/data/$f" && [ ! -e "$(target "$POL/$f")" ]; then
            read_as vguard "$OLD_G/data/$f" | put "$POL/$f" 0640 root:vrelay
            say "vrelay: $OLD_G/data/$f copied to $POL/$f"
        fi
    done
fi

# A password made once (64 hex) and kept; never printed. Its mode and owner
# are set again on every run.
secret_file() { # secret_file <path> <owner:group>
    if [ ! -s "$(target "$1")" ]; then
        secret | put "$1" 0600 "$2"
        say "vrelay: $1 made"
    elif [ "$DRY" != 1 ]; then
        chown "$2" "$1"
        chmod 0600 "$1"
    fi
}
# A copy of a password for another reader.
copy_secret() { # copy_secret <from> <to> <owner:group>
    if [ "$(cat "$(target "$2")" 2>/dev/null)" != "$(cat "$(target "$1")")" ]; then
        put "$2" 0600 "$3" < "$(target "$1")"
    elif [ "$DRY" != 1 ]; then
        chown "$3" "$2"
        chmod 0600 "$2"
    fi
}
# (Both folders are root's alone, 0711 and 0750: nobody else can put a link
# in them, so root sets the files by their paths.)
#
# The superuser of Cassandra: a server alone and the first of a mesh make
# it; a server that joins a mesh is never given it (relay-join: the key
# carries the role migrate instead), so none is made there. Its role of the
# tables (migrate: CREATE on the keyspaces, ALTER, SELECT and MODIFY on
# vrelay's) is the cluster's, made by the first server (kit/cassandra-init.sh).
if [ "$MESH" != 1 ] || [ "$MESH_STATE" = founder ] || [ -s "$(target "$CSEC/cassandra-admin-password")" ]; then
    secret_file "$CSEC/cassandra-admin-password" vrelay-db:vrelay-db
fi
secret_file "$CSEC/cassandra-vrelay-password" vrelay-db:vrelay-db
# The password of the role migrate: the cluster's, made by the first server
# alone (its mesh-joined says "founded"); the others take it from the key.
if [ "$MESH" = 1 ] && { [ "$MESH_STATE" = founder ] || grep -q '^founded ' "$(target "$MESH_JOINED")" 2>/dev/null \
        || [ -s "$(target "$CSEC/cassandra-migrate-password")" ]; }; then
    secret_file "$CSEC/cassandra-migrate-password" vrelay-db:vrelay-db
fi
# A user of NATS a mode (spec/security.md 4.2), on a server alone too; in
# the mesh those of the store are the cluster's, the same on every server
# (relay-join brings them).
for u in serve write migrate sys; do secret_file "$CSEC/nats-$u-password" vrelay-bus:vrelay-bus; done
[ "$MESH" = 1 ] && [ -n "$MESH_ROUTES" ] && secret_file "$CSEC/nats-route-password" vrelay-bus:vrelay-bus
copy_secret "$CSEC/nats-serve-password" "$SEC/nats-serve-password" vrelay:vrelay
copy_secret "$CSEC/nats-write-password" "$SEC/nats-write-password" vrelay:vrelay
copy_secret "$CSEC/cassandra-vrelay-password" "$SEC/cassandra-password" vrelay:vrelay
# The one user of NATS of an older kit (serve and write in one) is gone.
for f in "$CSEC/nats-vrelay-password" "$SEC/nats-password"; do
    [ ! -f "$(target "$f")" ] || run rm -f "$f"
done
# The keys of the network (server.conf): the app key is in every card, the
# peer key is a secret; both are files of vrelay alone.
printf '%s\n' "$MESH_APP_KEY" | put "$SEC/app-key" 0600 vrelay:vrelay
printf '%s\n' "$MESH_PEER_KEY" | put "$SEC/peer-key" 0600 vrelay:vrelay
# The key of the statistics (MESH_STATS_KEY, the same on every relay of the
# network, so that the sketches of the relays merge; services/relay/spec/
# stats.md 2). Never in a page, vagent or vcloud: a file of vrelay alone.
if [ -n "$MESH_STATS_KEY" ]; then
    printf '%s\n' "$MESH_STATS_KEY" | put "$SEC/stats-key" 0600 vrelay:vrelay
elif [ -f "$(target "$SEC/stats-key")" ]; then
    run rm -f "$SEC/stats-key"
fi
# The token of the statistics endpoint (VRELAY_STATS_TOKEN_FILE; stats.md):
# made once, 64 hex; read by vrelay (serve and write) and by the agent of
# the server, who sends it as "Authorization: Bearer <token>". Without it
# the endpoint answers nothing but 401. The group vrelay-stats is theirs.
STATS_DIR=$R/stats
if ! getent group vrelay-stats >/dev/null 2>&1; then run groupadd --system vrelay-stats; fi
for u in vrelay vagent; do
    [ "$u" = vrelay ] || id "$u" >/dev/null 2>&1 || continue
    id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx vrelay-stats || run usermod -a -G vrelay-stats "$u"
done
mkdirp "$STATS_DIR" 0750 root:vrelay-stats
if [ ! -s "$(target "$STATS_DIR/token")" ]; then
    openssl rand -hex 32 | put "$STATS_DIR/token" 0640 root:vrelay-stats
    say "vrelay: $STATS_DIR/token made (the token of the statistics, for the agent)"
elif [ "$DRY" != 1 ]; then
    chown root:vrelay-stats "$STATS_DIR/token"
    chmod 0640 "$STATS_DIR/token"
fi

# --- who uses the relay (ACCESS_MODE) -------------------------------------------
#
# Team and channel: the members (one key a line) and the invites are
# written by vrelay (its access API, and `vrelay access` of veydan-server
# members and invite: a new file renamed over the old one, which keeps its
# owner and mode); the secret that signs the invites is made here once and
# kept. A server switched from strfry takes vguard's once, as they are
# (the same formats: its invites stay good), and never gives them back:
# after a way back to strfry vguard has what it had at the switch.
#
# The folder is root's (0770 root:vrelay, in /opt/vrelay of root alone), the
# files in it vrelay's: root never writes, owns or reads a file there by its
# path. put writes them as vrelay; a mode is set as vrelay (who can change
# only its own files); an owner is set with chown -h (the link, never what
# it points to); a link there is told and left (the audit tells it too).
if access_on; then
    mkdirp "$ACC" 0770 root:vrelay
    for f in members.txt invites.json; do
        if [ ! -e "$(target "$ACC/$f")" ] && [ ! -L "$(target "$ACC/$f")" ] && plain_file "$OLD_G/data/$f"; then
            read_as vguard "$OLD_G/data/$f" | put "$ACC/$f" 0660 vrelay:vrelay
            say "vrelay: $OLD_G/data/$f copied to $ACC/$f (vguard's stays as it is)"
        fi
    done
    if [ ! -s "$(target "$SEC/access.key")" ] && plain_file "$OLD_G/etc/access.key" && [ -s "$(target "$OLD_G/etc/access.key")" ]; then
        # 0640 root:vguard: read as vguard, as the files of its data.
        read_as vguard "$OLD_G/etc/access.key" | put "$SEC/access.key" 0600 vrelay:vrelay
        say "vrelay: $OLD_G/etc/access.key copied to $SEC/access.key (the invites of vguard stay good)"
    elif [ ! -s "$(target "$SEC/access.key")" ]; then
        openssl rand -hex 32 | put "$SEC/access.key" 0600 vrelay:vrelay
        say "vrelay: $SEC/access.key made (the secret of the invites; keep it)"
    elif [ "$DRY" != 1 ]; then
        chown vrelay:vrelay "$SEC/access.key"
        chmod 0600 "$SEC/access.key"
    fi
    for f in members.txt invites.json; do
        p=$(target "$ACC/$f")
        [ ! -e "$p" ] && [ ! -L "$p" ] || continue
        case "$f" in
            members.txt) : | put "$ACC/$f" 0660 vrelay:vrelay ;;
            invites.json) echo '[]' | put "$ACC/$f" 0660 vrelay:vrelay ;;
        esac
    done
    own_files "$ACC" vrelay 0660 members.txt invites.json access.lock
fi

# --- Cassandra and NATS ---------------------------------------------------------
#
# The relay's compose files as they are, the kit's layer over them, and the
# settings from server.conf (templates/relay-compose).
T=$HERE/templates/relay-compose
if [ "$MESH" = 1 ]; then
    # The host's network, the files of services/relay/deploy/cluster as the
    # kit runs them (templates/relay-compose/mesh.yaml), the roles of the
    # kit's own init.
    mkdirp "$RC/mesh" 0755 root:root
    put "$RC/kit/cassandra-init.sh" 0644 root:root < "$T/kit/cassandra-init.sh"
    for f in cassandra-entrypoint.sh cassandra-overrides.yaml cassandra-system.sh cql.sh; do
        put "$RC/mesh/$f" 0644 root:root < "$T/mesh/$f"
    done
    put "$RC/mesh.yaml" 0644 root:root < "$T/mesh.yaml"
else
put "$RC/compose.yaml" 0644 root:root < "$T/compose.yaml"
for f in "$T"/compose/*; do put "$RC/compose/$(basename "$f")" 0644 root:root < "$f"; done
put "$RC/compose.kit.yaml" 0644 root:root < "$T/compose.kit.yaml"
for f in "$T"/kit/*; do put "$RC/kit/$(basename "$f")" 0644 root:root < "$f"; done
# The tuning of cassandra.yaml, one text with the mesh's (the node's own
# keys of it; kit/cassandra-entrypoint.sh leaves out those of several nodes).
put "$RC/kit/cassandra-overrides.yaml" 0644 root:root < "$T/mesh/cassandra-overrides.yaml"
fi
V_COMPOSE_SECRETS=$CSEC
V_CASSANDRA_TAG=$CASSANDRA_IMAGE_TAG
V_NATS_TAG=$NATS_IMAGE_TAG
V_CASSANDRA_UID=$(uid_of vrelay-db) V_CASSANDRA_GID=$(uid_of vrelay-db -g)
V_NATS_UID=$(uid_of vrelay-bus) V_NATS_GID=$(uid_of vrelay-bus -g)
V_CASSANDRA_DATA=$R/data/cassandra
V_CASSANDRA_LOGS=$R/data/cassandra-logs
V_NATS_DATA=$R/data/nats
V_CASSANDRA_CLUSTER=$NETWORK
V_RELAY_DC=$RELAY_DC
V_CASSANDRA_SEEDS=$RELAY_STORE_SEEDS
V_NATS_ROUTES=$RELAY_BUS_ROUTES
V_CASSANDRA_HEAP=${heap_mb}M
V_CASSANDRA_DIRECT=${direct_mb}M
V_CASSANDRA_MEM_LIMIT=${cassandra_limit_mb}m
V_NATS_MEM_LIMIT=${nats_limit_mb}m
V_NATS_GOMEMLIMIT=${MEM_GOMEMLIMIT}MiB
V_NATS_SERVER_NAME=$SERVER
if [ "$MESH" = 1 ]; then
    V_MESH_IP=$MESH_IP V_CASSANDRA_SEEDS=$MESH_SEEDS
    render "$T/mesh-env" "$RC/.env" 0600 root:root
    nats_before=$(cat "$(target "$CSEC/nats/nats.conf")" 2>/dev/null || true)
    mesh_nats_conf "$T/mesh/nats.conf" vrelay-bus:vrelay-bus
    nats_after=$(cat "$(target "$CSEC/nats/nats.conf")")
else
render "$T/env" "$RC/.env" 0600 root:root
fi

# Huge pages and the readahead of the disk of the store, before docker.
put "$R/etc/vrelay-host-tuning.service" 0644 root:root < "$HERE/templates/systemd/vrelay-host-tuning.service"
link_unit "$R/etc/vrelay-host-tuning.service"
run systemctl restart vrelay-host-tuning.service

# The second lock first (DOCKER-USER), then the containers.
render "$HERE/templates/systemd/vrelay-docker-lock.service" "$R/etc/vrelay-docker-lock.service" 0644 root:root
link_unit "$R/etc/vrelay-docker-lock.service"
run systemctl restart vrelay-docker-lock.service
# The local lock: JMX, the page of NATS, the statistics, CQL and NATS's
# clients for their own users, not for every user of the box
# (vrelay-local-lock.sh; the users are those of this moment, so run.sh puts
# it again at the end of the run, once every component has made its own).
put "$R/etc/vrelay-local-lock.service" 0644 root:root < "$HERE/templates/systemd/vrelay-local-lock.service"
link_unit "$R/etc/vrelay-local-lock.service"
run systemctl restart vrelay-local-lock.service

# The mesh: the WireGuard of this server, its firewall, docker after wg0
# (Cassandra and NATS bind its address).
if [ "$MESH" = 1 ]; then
    mesh_wg_key
    mesh_wg_render
    mesh_wg_apply
    mesh_firewall
    printf '[Unit]\n# The containers of vrelay bind the mesh address (lib/mesh.sh).\nWants=wg-quick@%s.service\nAfter=wg-quick@%s.service\n' "$MESH_IF" "$MESH_IF" \
        | put /etc/systemd/system/docker.service.d/veydan-mesh.conf 0644 root:root
    run systemctl daemon-reload
    MESH_LINE=$(mesh_line)
    say "vrelay: the line of this server for RELAY_MESH_WG_PEERS of the others: $MESH_LINE"
    CARD_EXTRA+="Mesh:                $MESH_IF $MESH_IP/$MESH_PREFIX, region $MESH_DC$([ "$MESH_IS_HUB" = 1 ] && echo " (hub)" || true), peers: ${PEER_NAME[*]:-none}"$'\n'
    CARD_EXTRA+="   the line of this server for the others (veydan-server relay-peer):"$'\n'"   $MESH_LINE"$'\n'
    if [ "$MESH_STATE" = pending ]; then
        tell_pending="vrelay: this server joins the mesh, and Cassandra and vrelay wait for it. Its line, for the other servers:

   $MESH_LINE

On $(printf '%s' "${PEER_NAME[0]}") (and on every other server of RELAY_MESH_WG_PEERS):
   veydan-server relay-peer add '$MESH_LINE'
It writes a key for this server to a file of root there (good for a day):
copy each to this server by a safe way, then here:
   veydan-server relay-join --key-file <the key of a peer> [--key-file <of each other peer>]
which joins the cluster step by step (README, \"Two regions\") and runs the kit again."
        printf '%s\n' "$tell_pending" | put "$R/etc/mesh-pending.txt" 0600 root:root
        die "$tell_pending"
    fi
fi

compose_files="-f $RC/compose.yaml -f $RC/compose.kit.yaml"
[ "$MESH" = 1 ] && compose_files="-f $RC/mesh.yaml"
say "vrelay: Cassandra and NATS (the first start of Cassandra takes a minute or two)"
vrelay_compose up -d --wait --wait-timeout 600 cassandra nats \
    || die "vrelay: Cassandra or NATS did not come up healthy: docker compose $compose_files logs cassandra nats (in $RC); nginx is left as it was"
# A NATS of the mesh that was up already takes a changed config.
[ "$MESH" = 1 ] && [ -n "$nats_before" ] && mesh_nats_reload "$nats_before" "$nats_after"
# A NATS of a server alone reads its config and passwords at its start
# (kit/nats-entrypoint.sh), and compose does not see a mounted file change:
# when they changed (the users of the modes of an older kit, say), it
# starts again with them (seconds).
if [ "$MESH" != 1 ]; then
    nats_stamp=$( { cat "$(target "$RC/kit/nats.conf")" "$(target "$RC/kit/nats-entrypoint.sh")" \
        "$(target "$CSEC")"/nats-*-password 2>/dev/null || true; } | sha256sum | cut -c1-64)
    if [ "$(cat "$(target "$RC/.nats-stamp")" 2>/dev/null)" != "$nats_stamp" ]; then
        vrelay_compose up -d --force-recreate --wait --wait-timeout 120 nats \
            || die "vrelay: NATS did not come up again with its users: docker compose $compose_files logs nats (in $RC); nginx is left as it was"
        printf '%s\n' "$nats_stamp" | put "$RC/.nats-stamp" 0600 root:root
    fi
fi
# The roles: the default superuser gone, ours and vrelay's in place.
vrelay_compose run --rm --no-deps cassandra-init \
    || die "vrelay: the roles of Cassandra are not in place (see above); nginx is left as it was"
if [ "$MESH" = 1 ] && [ "$MESH_STATE" = founder ]; then
    printf 'founded %s: the first server of the mesh, region %s\n' "$(date -u +%FT%TZ)" "$MESH_DC" | put "$MESH_JOINED" 0644 root:root
    say "vrelay: the first server of the mesh: the cluster ${NETWORK} and the region $MESH_DC begin here"
fi

# --- vrelay ---------------------------------------------------------------------

V_RELAY_NAME=${RELAY_NAME:-${NETWORK^} $(short "$RELAY_FQDN")}
V_NETWORK=${NETWORK^}
for v in "$V_RELAY_NAME" "$V_NETWORK"; do
    [[ "$v" != *[\"\\\$\`]* ]] || die "RELAY_NAME, NETWORK: no quote, backslash, \$ or backquote (they go into vrelay.env)"
done
# shellcheck disable=SC2153  # ADMIN_PUBKEY, ACCESS_MODE: of server.conf (run.sh)
V_ADMIN_PUBKEY=$ADMIN_PUBKEY V_ACCESS_MODE=$ACCESS_MODE
access_on || V_ACCESS_MODE=open
V_VRELAY_KEYS=$SEC V_VRELAY_SECRETS=$SEC
# shellcheck disable=SC2086  # one name per word
V_VRELAY_HOSTS=$(printf '%s,' "$RELAY_FQDN" $RELAY_ALIAS_FQDNS | sed 's/,$//')
V_RELAY_MAX_CONNECTIONS=$max_conn
# The WebSockets on several loopback addresses, one port: nginx's
# connections to one address and port have a source port each, and the
# ports are ip_local_port_range (32768-60999: 28 232), which nginx ran out
# of at 30 000 WebSockets ("connect() ... (99: Cannot assign requested
# address)"). A source port is unique for each address it goes to, so
# every address of 127.0.0.0/8 (all of them on lo, none to add) has as many
# again; nginx spreads the WebSockets over them (relay-vrelay.conf), and
# no setting of the kernel changes. An address for every 20 000
# connections, two at least; the first is the one of the probe.
n_listen=$(( (max_conn + 19999) / 20000 ))
[ "$n_listen" -ge 2 ] || n_listen=2
[ "$n_listen" -le 32 ] || n_listen=32
V_VRELAY_LISTEN="" V_VRELAY_UPSTREAM=""
for i in $(seq 1 "$n_listen"); do
    V_VRELAY_LISTEN+="${V_VRELAY_LISTEN:+,}127.0.0.$i:7781"
    V_VRELAY_UPSTREAM+="${V_VRELAY_UPSTREAM:+$'\n'}    server 127.0.0.$i:7781 max_fails=0;"
done
V_RELAY_IP_MAX_CONNECTIONS=$RELAY_IP_MAX_CONNECTIONS
V_RELAY_IP6_NET_MAX_CONNECTIONS=$RELAY_IP6_NET_MAX_CONNECTIONS
V_RELAY_IP_CONNECTS_PER_SEC=$RELAY_IP_CONNECTS_PER_SEC
V_RELAY_IP_CONNECT_BURST=$RELAY_IP_CONNECT_BURST
V_RETENTION_DAYS=$RELAY_RETENTION_DAYS
V_VRELAY_ACCESS="# open: anyone with the card, no members, no invites"
if access_on; then
    V_VRELAY_ACCESS=$(printf '%s\n' \
        "VRELAY_ACCESS_MEMBERS_FILE=$ACC/members.txt" \
        "VRELAY_ACCESS_INVITES_FILE=$ACC/invites.json" \
        "VRELAY_ACCESS_SECRET_FILE=$SEC/access.key" \
        "VRELAY_ACCESS_ADMINS=$ADMIN_PUBKEY" \
        "VRELAY_ACCESS_PUBLIC_URL=https://$RELAY_FQDN")
fi
V_VRELAY_POLICY="# The lists laid by the agent of vcloud, vrelay's own.
VRELAY_POLICY_DENIED_KEYS_FILE=$DENIED/denied-keys.txt
VRELAY_POLICY_DENIED_GROUPS_FILE=$DENIED/denied-groups.txt"
[ "$OLD_GUARD" = 1 ] && V_VRELAY_POLICY="# The lists laid by the agent of vcloud, where it lays them on a server switched
# from strfry (until veydan-server relay-cleanup: then $POL).
VRELAY_POLICY_DENIED_KEYS_FILE=$DENIED/denied-keys.txt
VRELAY_POLICY_DENIED_GROUPS_FILE=$DENIED/denied-groups.txt"
# The statistics endpoint (services/relay/spec/stats.md 1): serve's on 7783
# here, the writer's on 7784 (vrelay-write.env), loopback alone; the key of
# the network when server.conf has one. A vrelay that does not know the
# settings yet gets none of them: it would refuse the file (a dry run puts
# them in).
stats_known=1
if [ "$DRY" != 1 ] && env -i PATH="$PATH" VRELAY_ENV_FILE=/dev/null VRELAY_STATS_LISTEN=127.0.0.1:7783 "$V_VRELAY" config check --mode serve 2>&1 \
        | grep -q 'VRELAY_STATS_LISTEN.*no such setting'; then
    stats_known=0
    warn "vrelay: this release has no statistics endpoint yet (VRELAY_STATS_LISTEN): the agent shows dashes for its numbers until vrelay is updated"
fi
# The token: a vrelay that has the endpoint but not the token yet gets no
# setting of it (it would refuse the file) and answers as before.
token_known=$stats_known
if [ "$stats_known" = 1 ] && [ "$DRY" != 1 ] && env -i PATH="$PATH" VRELAY_ENV_FILE=/dev/null VRELAY_STATS_LISTEN=127.0.0.1:7783 VRELAY_STATS_TOKEN_FILE="$STATS_DIR/token" "$V_VRELAY" config check --mode serve 2>&1 \
        | grep -q 'VRELAY_STATS_TOKEN_FILE.*no such setting'; then
    token_known=0
    warn "vrelay: this release has no token of the statistics yet (VRELAY_STATS_TOKEN_FILE): its endpoint answers any process of this machine until vrelay is updated"
fi
V_VRELAY_STATS="# The statistics (VRELAY_STATS_*): not known to this vrelay yet."
WRITE_STATS=""
if [ "$stats_known" = 1 ]; then
    V_VRELAY_STATS="VRELAY_STATS_LISTEN=127.0.0.1:7783"
    WRITE_STATS="VRELAY_STATS_LISTEN=127.0.0.1:7784"
    if [ "$token_known" = 1 ]; then
        V_VRELAY_STATS+=$'\n'"VRELAY_STATS_TOKEN_FILE=$STATS_DIR/token"
        WRITE_STATS+=$'\n'"VRELAY_STATS_TOKEN_FILE=$STATS_DIR/token"
    fi
    if [ -n "$MESH_STATS_KEY" ]; then
        V_VRELAY_STATS+=$'\n'"VRELAY_STATS_KEY_FILE=$SEC/stats-key"
    else
        V_VRELAY_STATS+=$'\n'"# VRELAY_STATS_KEY_FILE: no MESH_STATS_KEY in server.conf; the counts without sketches"
        warn "vrelay: no MESH_STATS_KEY in server.conf: the relay counts the users online but gives no sketches, so vcloud has no users of a day, 7 and 30 days. Put one key, the same on every server of the network, into server.conf of each (openssl rand -hex 32; README, \"The vrelay engine\") and rerun"
    fi
fi
# The user of NATS of each mode (spec/security.md 4.2), on a server alone
# as in the mesh: a file of its own beside vrelay.env, read by its unit
# after it.
for mode in serve write; do
    {
        printf '# The user of NATS of vrelay %s (components/vrelay.sh); written on every run.\nVRELAY_BUS_USERNAME=%s\nVRELAY_BUS_PASSWORD_FILE=%s/nats-%s-password\n' \
            "$mode" "$mode" "$SEC" "$mode"
        if [ "$mode" = write ] && [ -n "$WRITE_STATS" ]; then printf '# The statistics of the writer, beside serve'"'"'s (stats.md 12).\n%s\n' "$WRITE_STATS"; fi
    } | put "$R/etc/vrelay-$mode.env" 0640 root:vrelay
done
if [ "$MESH" = 1 ]; then
    V_VRELAY_STORE_BUS=$(mesh_vrelay_env "$SEC")
else
V_VRELAY_STORE_BUS="# Cassandra and NATS of this server (/opt/vrelay/compose), each with a user
# of vrelay's own; the user of NATS is the mode's: vrelay-serve.env,
# vrelay-write.env beside this file.
VRELAY_STORE_NODES=127.0.0.1:9042
VRELAY_STORE_KEYSPACE=vrelay
VRELAY_STORE_REPLICATION_FACTOR=1
VRELAY_STORE_LOCAL_DC=$RELAY_DC
VRELAY_STORE_USERNAME=vrelay
VRELAY_STORE_PASSWORD_FILE=$SEC/cassandra-password
VRELAY_BUS_SERVERS=nats://127.0.0.1:4222
VRELAY_BUS_STREAM_REPLICAS=1"
fi
render_block "$HERE/templates/vrelay-env.conf" "$R/etc/vrelay.env" 0640 root:vrelay
# Every problem of the settings, told at once (spec/config.md).
for mode in serve write; do
    # shellcheck disable=SC2046  # the words of the mode's env file
    if [ "$DRY" = 1 ]; then
        run runuser -u vrelay -- env VRELAY_ENV_FILE="$R/etc/vrelay.env" $(mesh_mode_env "$mode") "$V_VRELAY" config check --mode "$mode"
    else
        runuser -u vrelay -- env VRELAY_ENV_FILE="$R/etc/vrelay.env" $(mesh_mode_env "$mode") "$V_VRELAY" config check --mode "$mode" \
            || die "vrelay: $R/etc/vrelay.env is refused for $mode (see above)"
    fi
done

# The tables of Cassandra and the streams of NATS, as our superuser of
# Cassandra (vrelay's role may not make a keyspace); then vrelay's rights on
# the keyspace. In the mesh, as the user migrate of NATS too.
# A server that joined the mesh has no superuser: its role migrate (the
# cluster's, made by the first server) makes the tables instead. NATS: the
# user migrate, on a server alone too.
store_user=veydan store_pass=$CSEC/cassandra-admin-password
if [ "$MESH" = 1 ] && [ ! -s "$(target "$store_pass")" ]; then
    store_user=vrelay_migrate store_pass=$CSEC/cassandra-migrate-password
fi
run env VRELAY_ENV_FILE="$R/etc/vrelay.env" VRELAY_STORE_USERNAME="$store_user" \
    VRELAY_STORE_PASSWORD_FILE="$store_pass" VRELAY_BUS_USERNAME=migrate \
    VRELAY_BUS_PASSWORD_FILE="$CSEC/nats-migrate-password" "$V_VRELAY" migrate \
    || die "vrelay migrate failed (see above); nginx is left as it was"
vrelay_compose run --rm --no-deps cassandra-init \
    || die "vrelay: the rights of vrelay on its keyspace are not in place (see above); nginx is left as it was"

# The first invite of a team server, at its first run: one person, 7 days,
# on the card (components/manifest.sh) with the link that carries it. Made
# on the file, before vrelay starts (it reads the invites at every join).
FIRST_INVITE=""
if [ "$ACCESS_MODE" = team ] && [ "$FIRST" = 1 ] && access_on; then
    invite=(runuser -u vrelay -- env VRELAY_ENV_FILE="$R/etc/vrelay.env" "$V_VRELAY" access invite --uses 1 --days 7 --label first)
    if [ "$DRY" = 1 ]; then
        run "${invite[@]}"
    elif FIRST_INVITE=$("${invite[@]}" | tail -n1 | tr -d '[:space:]') && [[ "$FIRST_INVITE" == vi1.* ]]; then
        CARD_EXTRA+="First invite:        $FIRST_INVITE (one person, 7 days; more: veydan-server invite)"$'\n'
    else
        FIRST_INVITE=""
        warn "vrelay made no first invite: veydan-server invite, once vrelay runs (journalctl -u vrelay)"
    fi
fi
if access_on; then
    CARD_EXTRA+="Access:              $ACCESS_MODE, owner $ADMIN_PUBKEY (veydan-server mode, members, invite)"$'\n'
    CARD_EXTRA+="   members: $ACC/members.txt   invites: $ACC/invites.json   secret: $SEC/access.key"$'\n'
fi

V_VRELAY_SERVE_MAX=${MEM_SERVE}M V_VRELAY_WRITE_MAX=${MEM_WRITE}M
V_VRELAY_UNIT_ENV="EnvironmentFile=$R/etc/vrelay.env"$'\n'"EnvironmentFile=$R/etc/vrelay-write.env"
render "$HERE/templates/systemd/vrelay-write.service" "$R/etc/vrelay-write.service" 0644 root:root
V_VRELAY_UNIT_ENV="EnvironmentFile=$R/etc/vrelay.env"$'\n'"EnvironmentFile=$R/etc/vrelay-serve.env"
# The group vguard only where vguard's folder holds the denied lists.
V_VRELAY_GROUPS="# No supplementary group: the files of vrelay are its own."
[ "$OLD_GUARD" = 1 ] && V_VRELAY_GROUPS="# The denied lists of a server switched from strfry are in /opt/vguard/data (relay-cleanup ends it).
SupplementaryGroups=vguard"
render "$HERE/templates/systemd/vrelay.service" "$R/etc/vrelay.service" 0644 root:root
link_unit "$R/etc/vrelay-write.service"
link_unit "$R/etc/vrelay.service"
run systemctl restart vrelay-write
run systemctl restart vrelay

# The weekly repair of this node (spec/cluster.md 1.3), on a day of its own.
if [ "$MESH" = 1 ]; then
    V_REPAIR_ON=$MESH_REPAIR_ON
    put "$R/etc/vrelay-repair.service" 0644 root:root < "$HERE/templates/systemd/vrelay-repair.service"
    render "$HERE/templates/systemd/vrelay-repair.timer" "$R/etc/vrelay-repair.timer" 0644 root:root
    link_only "$R/etc/vrelay-repair.service"
    link_unit "$R/etc/vrelay-repair.timer"
    run systemctl restart vrelay-repair.timer
fi

# The health of Cassandra for the agent (services/relay/spec/stats.md 13):
# once a minute, as root, nodetool inside the container (JMX on its
# loopback, no role of CQL), into /run/veydan/store-health.json (0644).
V_CASSANDRA_CLUSTER=$NETWORK
render "$HERE/templates/store-health.sh" "$R/bin/store-health.sh" 0755 root:root
put "$R/etc/veydan-store-health.service" 0644 root:root < "$HERE/templates/systemd/veydan-store-health.service"
put "$R/etc/veydan-store-health.timer" 0644 root:root < "$HERE/templates/systemd/veydan-store-health.timer"
link_only "$R/etc/veydan-store-health.service"
link_unit "$R/etc/veydan-store-health.timer"
run systemctl restart veydan-store-health.timer

# The denied lists of a fresh server are vrelay's (policy/): the agent of a
# kit that names only vguard's folder lays them nowhere here.
if [ "$DENIED" = "$POL" ] && has agent && [ -f "$HERE/components/agent.sh" ] && ! grep -q "$POL/denied-keys.txt" "$HERE/components/agent.sh"; then
    warn "vrelay: the agent of this kit (components/agent.sh) names the denied keys and groups in /opt/vguard/data only, which this server has not got: vcloud lays them nowhere here and the relay denies nobody, until the agent names $POL/denied-keys.txt and $POL/denied-groups.txt"
fi

# Health: a question to vrelay serve, answered from the store. Until it
# answers, nginx keeps sending the relay where it did.
if [ "$DRY" != 1 ]; then
    ok=""
    for _ in $(seq 1 20); do
        if runuser -u vrelay -- env VRELAY_ENV_FILE="$R/etc/vrelay.env" "$V_VRELAY" probe >/dev/null 2>&1; then ok=1; break; fi
        sleep 1
    done
    [ -n "$ok" ] || die "vrelay does not answer on 127.0.0.1:7781 (journalctl -u vrelay -u vrelay-write); nginx is left as it was, strfry is not stopped"
fi
say "vrelay: $("$V_VRELAY" --version 2>/dev/null || echo vrelay) answers on 127.0.0.1:7781"

# nginx sends the relay site here (templates/nginx/relay-vrelay.conf).
V_RELAY_WS=127.0.0.1:7781
V_ACCESS_HTTP=127.0.0.1:7782
CARD_EXTRA+="Relay engine:        vrelay (serve, write), $R/etc/vrelay.env; Cassandra and NATS in docker, $RC (data: $R/data)"$'\n'
CARD_EXTRA+="   statistics for the agent: 127.0.0.1:7783 (serve), 127.0.0.1:7784 (write), /run/veydan/store-health.json"$'\n'
if [ -d "$(target /opt/strfry)" ] || [ -d "$(target "$OLD_G")" ]; then
    CARD_EXTRA+="   the way back: veydan-server relay-engine strfry   history of strfry: veydan-server relay-import"$'\n'
    CARD_EXTRA+="   strfry and vguard for good: veydan-server relay-cleanup (no way back after it)"$'\n'
fi

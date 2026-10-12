# shellcheck shell=bash disable=SC2034  # V_* are read by the templates
# strfry relay of the pinned tag: ready from the kit (deploy/bin/strfry, made
# by `make build-deploy`), or built here when the kit brings none. Everything
# in /opt/strfry:
#   bin/strfry  bin/sync-peers.sh  etc/strfry.conf  etc/router.conf
#   etc/peers  etc/*.service  etc/*.timer  data/  src/ (only when built here)
# Listens on 127.0.0.1:7777; only nginx is in front of it. Talks to the
# other relays of the mesh itself: router (live, both ways) and a sync
# timer (negentropy, closes the gaps after a lost connection).
# Sourced by run.sh.

S=/opt/strfry
say "strfry: $STRFRY_TAG"

# Ready from the kit: the server compiles nothing and takes the libraries
# alone. The binary is of the pinned commit, or the kit is refused.
prebuilt=""
if [ -f "$HERE/bin/strfry" ]; then
    [ "$(cat "$HERE/bin/strfry.commit" 2>/dev/null)" = "$STRFRY_COMMIT" ] \
        || die "deploy/bin/strfry is not strfry $STRFRY_TAG ($STRFRY_COMMIT): run make build-deploy again"
    ( cd "$HERE/bin" && sha256sum -c --quiet strfry.sha256 ) \
        || die "deploy/bin/strfry does not match deploy/bin/strfry.sha256: run make build-deploy again"
    prebuilt=1
fi
if [ -n "$prebuilt" ]; then
    apt_install liblmdb0 libsecp256k1-2 libssl3t64 libzstd1 zlib1g
else
    apt_install g++ make pkg-config libtool libssl-dev zlib1g-dev liblmdb-dev \
        libflatbuffers-dev libsecp256k1-dev libzstd-dev
fi
ensure_user strfry "$S"
mkdirp "$S" 0755 root:root
mkdirp "$S/bin" 0755 root:root
mkdirp "$S/etc" 0750 root:strfry
mkdirp "$S/data" 0750 strfry:strfry

# Built again only when the pinned tag changes.
built=""
[ -f "$S/bin/.commit" ] && built=$(cat "$S/bin/.commit")
if [ -n "$prebuilt" ]; then
    # install, not cp: cp over a running binary fails with "text file busy".
    run install -m 0755 "$HERE/bin/strfry" "$S/bin/strfry"
    if [ "$DRY" != 1 ]; then
        echo "$STRFRY_COMMIT" > "$S/bin/.commit"
        missing=$(ldd "$S/bin/strfry" | awk '/not found/ {print $1}' | tr '\n' ' ')
        [ -z "$missing" ] || die "strfry of the kit lacks libraries here: ${missing}(the kit's binary is linked on Debian 13)"
    fi
    say "strfry: $STRFRY_TAG from the kit"
elif [ "$DRY" = 1 ]; then
    printf '   + build strfry %s in %s/src → %s/bin/strfry\n' "$STRFRY_TAG" "$S" "$S"
elif [ "$built" != "$STRFRY_COMMIT" ] || [ ! -x "$S/bin/strfry" ]; then
    say "strfry: building (5-10 minutes on a small server)"
    if [ ! -d "$S/src/.git" ]; then
        git clone --quiet "$STRFRY_REPO" "$S/src"
    fi
    git -C "$S/src" fetch --quiet --tags origin
    git -C "$S/src" checkout --quiet --force "refs/tags/$STRFRY_TAG"
    [ "$(git -C "$S/src" rev-parse HEAD)" = "$STRFRY_COMMIT" ] \
        || die "strfry tag $STRFRY_TAG is not commit $STRFRY_COMMIT: refusing a moved tag"
    git -C "$S/src" submodule update --quiet --init --recursive

    # One C++ compiler takes up to ~1.5 GB here, so the jobs follow the
    # memory, not the cores. Below 2.5 GB of RAM and swap together, a swap
    # file is added for the build and removed after it (a small VPS gets
    # its compiler killed otherwise: "Killed signal terminated program cc1plus").
    mem_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    swap_mb=$(awk '/^SwapFree:/ {print int($2/1024)}' /proc/meminfo)
    build_swap=""
    if [ $((mem_mb + swap_mb)) -lt 2560 ]; then
        build_swap=/var/tmp/strfry-build.swap
        say "strfry: ${mem_mb} MB free memory, adding 2 GB of swap for the build"
        swapoff "$build_swap" 2>/dev/null || true
        rm -f "$build_swap"
        # dd, not fallocate: swapon refuses preallocated files on some filesystems.
        dd if=/dev/zero of="$build_swap" bs=1M count=2048 status=none
        chmod 600 "$build_swap"
        mkswap -q "$build_swap" >/dev/null && swapon "$build_swap" \
            || { warn "strfry: could not add swap; the build may run out of memory"; rm -f "$build_swap"; build_swap=""; }
    fi
    jobs=$(( mem_mb / 1500 ))
    [ "$jobs" -ge 1 ] || jobs=1
    [ "$jobs" -le "$(nproc)" ] || jobs=$(nproc)
    say "strfry: building with $jobs job(s)"
    build_ok=1
    ( cd "$S/src" && make setup-golpe >/dev/null && make -j"$jobs" >/dev/null ) || build_ok=0
    if [ -n "$build_swap" ]; then
        swapoff "$build_swap" 2>/dev/null || true
        rm -f "$build_swap"
    fi
    [ "$build_ok" = 1 ] || die "strfry build failed: cd $S/src && make -j1  to see why (free memory: $(free -m | awk '/^Mem:/ {print $7}') MB)"
    # install, not cp: cp over a running binary fails with "text file busy".
    install -m 0755 "$S/src/strfry" "$S/bin/strfry"
    echo "$STRFRY_COMMIT" > "$S/bin/.commit"
else
    say "strfry: $STRFRY_TAG is already built"
fi

V_RELAY_FQDN=$RELAY_FQDN
# The network's word with a capital, as a name: "veydan" → "Veydan".
V_RELAY_NAME=${RELAY_NAME:-${NETWORK^} $(short "$RELAY_FQDN")}
V_NETWORK=${NETWORK^}
V_ADMIN_PUBKEY=$ADMIN_PUBKEY
render "$HERE/templates/strfry.conf" "$S/etc/strfry.conf" 0640 root:strfry keep "## strfry of the " "        name = "
render "$HERE/templates/systemd/strfry.service" "$S/etc/strfry.service" 0644 root:root

# The peers: one URL per line, with the peer key, readable by strfry only.
# Both the router and the sync timer read this file.
{
    for p in $PEERS; do echo "wss://$p/?key=$MESH_PEER_KEY"; done
} | put "$S/etc/peers" 0640 root:strfry

if [ -n "$PEERS" ]; then
    {
        echo "# Made by run.sh from MESH_RELAYS in server.conf. Edits here are"
        echo "# lost on the next run. strfry router re-reads this file by itself."
        echo "connectionTimeout = 20"
        echo "verbose = false"
        echo "streams {"
        echo "    mesh {"
        echo "        dir = \"both\""
        echo "        urls = ["
        for p in $PEERS; do echo "            \"wss://$p/?key=$MESH_PEER_KEY\""; done
        echo "        ]"
        echo "    }"
        echo "}"
    } | put "$S/etc/router.conf" 0640 root:strfry
    render "$HERE/templates/systemd/strfry-router.service" "$S/etc/strfry-router.service" 0644 root:root
    put "$S/bin/sync-peers.sh" 0755 root:root < "$HERE/templates/sync-peers.sh"
    render "$HERE/templates/systemd/strfry-sync.service" "$S/etc/strfry-sync.service" 0644 root:root
    render "$HERE/templates/systemd/strfry-sync.timer" "$S/etc/strfry-sync.timer" 0644 root:root
fi

link_unit "$S/etc/strfry.service"
run systemctl restart strfry
if [ -n "$PEERS" ]; then
    link_unit "$S/etc/strfry-router.service"
    run systemctl restart strfry-router
    link_only "$S/etc/strfry-sync.service"
    link_unit "$S/etc/strfry-sync.timer"
    run systemctl restart strfry-sync.timer
elif [ -f "$(target "$S/etc/strfry-router.service")" ]; then
    # This relay is alone in the mesh now.
    run systemctl disable --now strfry-router strfry-sync.timer
    run rm -f "$S/etc/strfry-router.service" "$S/etc/strfry-sync.service" "$S/etc/strfry-sync.timer" "$S/etc/router.conf"
fi

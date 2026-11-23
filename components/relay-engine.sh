# shellcheck shell=bash
# The engine of the relay not chosen (RELAY_ENGINE of server.conf) is set
# aside: stopped and disabled, never removed. Sourced by run.sh after
# nginx.sh, so that nginx already sends the relay to the engine that runs
# (strfry.sh and guard.sh, or vrelay.sh, put it up and checked that it
# answers).
#
#   vrelay chosen: strfry, its router, its timers and vguard stop, where they
#     are (a fresh server of vrelay has none of them). Their binaries,
#     configs, units (/opt/strfry/etc, /opt/vguard/etc) and the database
#     (/opt/strfry/data) stay; vguard's files of access were copied to vrelay
#     once (components/vrelay.sh). A rerun with RELAY_ENGINE=strfry links and
#     starts them again; veydan-server relay-cleanup removes them for good.
#   strfry chosen: vrelay serve and vrelay write stop, the health timer of
#     the store too, and the containers of Cassandra and NATS stop with their
#     data (/opt/vrelay/data). A rerun with RELAY_ENGINE=vrelay starts them
#     again.

# Whether systemd knows a unit (a dry run: whether the kit put it under /opt).
unit_known() { # unit_known <name> <file under /opt>
    if [ "$DRY" = 1 ]; then
        [ -f "$(target "$2")" ]
    else
        systemctl cat "$1" >/dev/null 2>&1
    fi
}

set_aside() { # set_aside <name> <file under /opt>...
    while [ $# -gt 1 ]; do
        if unit_known "$1" "$2"; then
            say "relay: $1 stopped and disabled (kept: $2)"
            run systemctl disable --now "$1"
        fi
        shift 2
    done
}

if [ "$RELAY_ENGINE" = vrelay ]; then
    set_aside \
        strfry-router.service /opt/strfry/etc/strfry-router.service \
        strfry-sync.timer /opt/strfry/etc/strfry-sync.timer \
        strfry-retention.timer /opt/strfry/etc/strfry-retention.timer \
        vguard.service /opt/vguard/etc/vguard.service \
        strfry.service /opt/strfry/etc/strfry.service
else
    set_aside \
        vrelay.service /opt/vrelay/etc/vrelay.service \
        vrelay-write.service /opt/vrelay/etc/vrelay-write.service \
        veydan-store-health.timer /opt/vrelay/etc/veydan-store-health.timer
    if [ -f "$(target /opt/vrelay/compose/mesh.yaml)" ]; then
        warn "relay: this server is a node of the mesh of vrelay: its Cassandra and NATS stop with the engine, and the other servers see it down (hints for 24 h, then a repair: services/relay/spec/cluster.md 1.3)"
        set_aside vrelay-repair.timer /opt/vrelay/etc/vrelay-repair.timer
    fi
    if { [ -f "$(target /opt/vrelay/compose/compose.kit.yaml)" ] || [ -f "$(target /opt/vrelay/compose/mesh.yaml)" ]; } \
        && { [ "$DRY" = 1 ] || command -v docker >/dev/null; }; then
        say "relay: the containers of Cassandra and NATS stopped (their data stays in /opt/vrelay/data)"
        vrelay_compose stop
    fi
fi
